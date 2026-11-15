#!/usr/bin/env bash
# Throwaway Cloud Hypervisor VM with the host's GPU passed through: proves VFIO
# end to end (host binding -> VMM -> guest driver -> nvidia-smi) before any
# k0s node depends on it. Deliberately NOT banlieue and NOT a k0s node: one
# plain VMM process, so a failure here is about passthrough and nothing else.
#
#   sudo ./bootstrap/host/gpu-smoke-vm.sh up       # create + boot (idempotent)
#   sudo ./bootstrap/host/gpu-smoke-vm.sh verify   # install the driver in the guest, run nvidia-smi
#   sudo ./bootstrap/host/gpu-smoke-vm.sh ssh      # shell in the guest
#   sudo ./bootstrap/host/gpu-smoke-vm.sh status   # unit state + serial console tail
#   sudo ./bootstrap/host/gpu-smoke-vm.sh down     # stop it, keep the disk
#   sudo ./bootstrap/host/gpu-smoke-vm.sh destroy  # stop it and delete its disk
#
# From another device: ssh ubuntu@<bridge-prefix>.10 (via the subnet route) or ssh -J <host> ubuntu@...
set -euo pipefail

# --- Pins ---------------------------------------------------------------------
# Ubuntu 24.04 cloud image, dated release; SHA256 from that release's SHA256SUMS.
IMAGE_URL="https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_SHA256="04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"

# GPU slot and VM network come from the host config (prepare-host.sh's).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_CONFIG="${HOST_CONFIG:-$script_dir/hosts/$(hostname -s).env}"
[[ -f "$HOST_CONFIG" ]] || { echo "no host config at $HOST_CONFIG" >&2; exit 1; }
# shellcheck source=hosts/k0s-gpu-01.env
source "$HOST_CONFIG"
[[ -n "${GPU_PCI_SLOT:-}" ]] || { echo "$HOST_CONFIG names no GPU (GPU_PCI_SLOT)" >&2; exit 1; }

NAME="gpu-smoke"
GPU="$GPU_PCI_SLOT.0"         # the VGA function; the others stay parked on vfio-pci
MAC="52:54:00:42:00:0a"
GATEWAY="${LAB_ADDR%/*}"
IP="${GATEWAY%.*}.10"         # static, below the bridge's DHCP pool (.100-.199)
BRIDGE="$LAB_BRIDGE"
TAP="tap-$NAME"
CPUS=4
MEM_MB=6144                   # all of it is pinned by VFIO
DISK_GB=30

CH="${CH:-/usr/local/bin/cloud-hypervisor}"
CH_REMOTE="${CH_REMOTE:-/usr/local/bin/ch-remote}"
DIR="/var/lib/homelab/$NAME"
CACHE="/var/lib/homelab/images"
SOCK="/run/$NAME.sock"
UNIT="$NAME"

# stderr, so functions called as $(...) return only their value.
log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
ssh_opts=(-i "$DIR/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5)

firmware() {
  # Installed by `banlieue host cloud-hypervisor install` (prepare-host.sh).
  local fw=(/opt/banlieue/firmware/*/CLOUDHV.fd)
  [[ -n "${CH_FIRMWARE:-}" ]] && { echo "$CH_FIRMWARE"; return; }
  [[ -e "${fw[0]}" ]] || die "no CLOUDHV.fd under /opt/banlieue/firmware; run prepare-host.sh"
  (( ${#fw[@]} == 1 )) || die "several firmwares installed; pick one with CH_FIRMWARE=..."
  echo "${fw[0]}"
}

preflight() {
  [[ -x "$CH" ]] || die "$CH missing; run prepare-host.sh"
  [[ -e /sys/class/net/$BRIDGE ]] || die "$BRIDGE missing; run prepare-host.sh"
  local drv
  drv=$(basename "$(readlink "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null)" 2>/dev/null || true)
  [[ "$drv" == vfio-pci ]] || die "$GPU is on '${drv:-no driver}', not vfio-pci; run prepare-host.sh and reboot"
  # Every device in the IOMMU group must be on vfio-pci (or a bridge) or the
  # VMM can't open the group.
  local grp; grp=$(readlink -f "/sys/bus/pci/devices/$GPU/iommu_group")
  for d in "$grp"/devices/*; do
    local cls drv2
    cls=$(cat "$d/class")
    drv2=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null || true)
    [[ "$cls" == 0x0604* || "$drv2" == vfio-pci ]] \
      || die "$(basename "$d") in the GPU's IOMMU group is on '${drv2:-none}', not vfio-pci"
  done
}

fetch_image() {
  local img
  img="$CACHE/$(basename "$IMAGE_URL")"
  install -d -m 0755 "$CACHE"
  if [[ ! -f "$img" ]]; then
    log "Downloading $(basename "$IMAGE_URL") (~600 MB, cached for next time)"
    curl -fL --progress-bar -o "$img.part" "$IMAGE_URL"
    mv "$img.part" "$img"
  fi
  # Verified on every use, not only after download: a cached file is where a
  # tampered image would hide.
  echo "$IMAGE_SHA256  $img" | sha256sum -c --quiet - || die "checksum mismatch: $img"
  echo "$img"
}

make_seed() {
  [[ -f "$DIR/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C "root@$(hostname)-$NAME" -f "$DIR/id_ed25519"
  local keys
  keys=$( { cat "$DIR/id_ed25519.pub"; cat /home/ops/.ssh/authorized_keys 2>/dev/null; } \
          | grep -E '^(ssh|ecdsa)-' | sed 's/.*/  - "&"/')
  local seed; seed=$(mktemp -d)
  cat > "$seed/user-data" <<EOF
#cloud-config
hostname: $NAME
ssh_authorized_keys:
$keys
package_update: false
EOF
  cat > "$seed/meta-data" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF
  cat > "$seed/network-config" <<EOF
version: 2
ethernets:
  lab:
    match:
      macaddress: "$MAC"
    addresses: [$IP/24]
    routes:
      - to: default
        via: $GATEWAY
    nameservers:
      addresses: [$GATEWAY]
EOF
  genisoimage -quiet -output "$DIR/seed.iso" -volid cidata -joliet -rock \
    "$seed/user-data" "$seed/meta-data" "$seed/network-config"
  rm -rf "$seed"
}

wait_ssh() {
  log "Waiting for SSH on $IP"
  for _ in {1..60}; do
    ssh "${ssh_opts[@]}" "ubuntu@$IP" true 2>/dev/null && return 0
    sleep 5
  done
  die "no SSH after 5 minutes; see: sudo $0 status"
}

up() {
  preflight
  if systemctl is-active --quiet "$UNIT"; then log "$NAME is already running"; return; fi
  install -d -m 0700 "$DIR"
  local img; img=$(fetch_image)
  if [[ ! -f "$DIR/disk.qcow2" ]]; then
    log "Creating ${DISK_GB}G disk from the cloud image"
    cp "$img" "$DIR/disk.qcow2"
    qemu-img resize -q "$DIR/disk.qcow2" "${DISK_GB}G"
  fi
  make_seed
  if [[ ! -e /sys/class/net/$TAP ]]; then
    ip tuntap add dev "$TAP" mode tap
    ip link set "$TAP" master "$BRIDGE"
  fi
  ip link set "$TAP" up
  rm -f "$SOCK"
  log "Booting $NAME: ${CPUS} vCPU, ${MEM_MB} MiB (pinned), GPU $GPU"
  # Root and unsandboxed on purpose: this only proves passthrough. The real
  # node unit runs as an unprivileged user and needs DeviceAllow for
  # /dev/vfio/* and LimitMEMLOCK=infinity.
  systemd-run --quiet --unit="$UNIT" --collect \
    "$CH" \
      --api-socket "path=$SOCK" \
      --firmware "$(firmware)" \
      --cpus "boot=$CPUS" \
      --memory "size=${MEM_MB}M" \
      --disk "path=$DIR/disk.qcow2,image_type=qcow2" "path=$DIR/seed.iso,readonly=on,image_type=raw" \
      --net "tap=$TAP,mac=$MAC" \
      --device "path=/sys/bus/pci/devices/$GPU/" \
      --rng src=/dev/urandom \
      --serial "file=$DIR/serial.log" \
      --console off
  sleep 2
  systemctl is-active --quiet "$UNIT" || { status; die "VMM exited; see the log above"; }
  wait_ssh
  ssh "${ssh_opts[@]}" "ubuntu@$IP" 'grep -qx 0x10de /sys/bus/pci/devices/*/vendor' \
    || die "guest sees no NVIDIA device"
  log "Guest sees the GPU on its PCI bus"
  log "Up. Next: sudo $0 verify"
}

verify() {
  wait_ssh
  if ssh "${ssh_opts[@]}" "ubuntu@$IP" nvidia-smi 2>/dev/null; then return; fi
  log "Installing the pinned NVIDIA driver in the guest"
  scp "${ssh_opts[@]}" "$script_dir/../node/prepare-gpu-node.sh" "ubuntu@$IP:/tmp/"
  ssh "${ssh_opts[@]}" "ubuntu@$IP" 'sudo bash /tmp/prepare-gpu-node.sh'
  log "Rebooting the guest"
  ssh "${ssh_opts[@]}" "ubuntu@$IP" 'sudo systemctl reboot' || true
  sleep 15
  wait_ssh
  ssh "${ssh_opts[@]}" "ubuntu@$IP" nvidia-smi
}

status() {
  systemctl status "$UNIT" --no-pager -n 20 || true
  [[ -f "$DIR/serial.log" ]] && { echo "--- serial (last 30 lines)"; tail -n 30 "$DIR/serial.log"; }
}

down() {
  if systemctl is-active --quiet "$UNIT"; then
    log "Powering off $NAME"
    "$CH_REMOTE" --api-socket "$SOCK" power-button 2>/dev/null || true
    for _ in {1..30}; do systemctl is-active --quiet "$UNIT" || break; sleep 2; done
    systemctl stop "$UNIT" 2>/dev/null || true
  fi
  [[ -e /sys/class/net/$TAP ]] && ip link del "$TAP"
  rm -f "$SOCK"
  log "$NAME is down"
}

case "${1:-}" in
  up) up ;;
  verify) verify ;;
  ssh) shift; exec ssh "${ssh_opts[@]}" "ubuntu@$IP" "$@" ;;
  status) status ;;
  down) down ;;
  destroy) down; rm -rf "$DIR"; log "deleted $DIR (the image cache is kept)" ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
