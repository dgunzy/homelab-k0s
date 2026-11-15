#!/usr/bin/env bash
# Prepare a bare-metal Linux host as a hypervisor for the platform: Cloud
# Hypervisor VMs managed by banlieue, optionally with a GPU passed through.
# Nothing on the host runs Kubernetes; the k0s nodes are VMs on it.
#
#   - VFIO (if the host config names a GPU): IOMMU on, every function of the
#     GPU's IOMMU group bound to vfio-pci at boot; no vendor driver on the host
#   - a routed VM bridge with DHCP, DNS and NAT (works behind Wi-Fi too)
#   - banlieue's Cloud Hypervisor host install (VMM, firmware, guest units)
#   - k0sctl, kubectl, optional Tailscale subnet router, host packages
#   - optional dual-boot helpers (helpers/dual-boot)
#
# Per-host settings live in bootstrap/host/hosts/<short-hostname>.env.
#   sudo ./bootstrap/host/prepare-host.sh
#   sudo HOST_CONFIG=bootstrap/host/hosts/other.env ./bootstrap/host/prepare-host.sh
# Idempotent: safe to re-run; it only changes what isn't already in place.
set -euo pipefail

# --- Pins (the same on every host) --------------------------------------------
BANLIEUE_VERSION="0.5.8"
# From the release's checksums.sha256 (signed with the release).
BANLIEUE_SHA256="9349f65cf9cbbd86edf8ddaaa45c0e7a4d470ff597236e25fc0572265b23c814"
K0SCTL_VERSION="0.31.3"
K0SCTL_SHA256="c055473be106deead180594f2610b8cca5fec97e69a710c92c1f26088bbd2255"
TAILSCALE_VERSION="1.104.7"
# Same minor as the cluster's k0s (bootstrap/cluster/mgmt.env).
KUBECTL_VERSION="1.37.2"
KUBECTL_SHA256="c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4"

CH_STORAGE="/var/lib/banlieue/ch"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then echo "run as root (sudo)" >&2; exit 1; fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$script_dir/../.." && pwd)"
REBOOT_NEEDED=0

# --- Host config ----------------------------------------------------------------
HOST_CONFIG="${HOST_CONFIG:-$script_dir/hosts/$(hostname -s).env}"
[[ -f "$HOST_CONFIG" ]] || die "no host config at $HOST_CONFIG (copy one in bootstrap/host/hosts/)"
# shellcheck source=hosts/k0s-gpu-01.env
source "$HOST_CONFIG"
for v in PROVIDER_NAME LAB_BRIDGE LAB_ADDR LAB_CIDR GUEST_MEMORY_MAX; do
  [[ -n "${!v:-}" ]] || die "$HOST_CONFIG must set $v"
done
GPU_PCI_IDS="${GPU_PCI_IDS:-}"
IOMMU="${IOMMU:-intel}"
DUAL_BOOT="${DUAL_BOOT:-false}"
TAILSCALE_SUBNET_ROUTER="${TAILSCALE_SUBNET_ROUTER:-false}"
gpu_passthrough() { [[ -n "$GPU_PCI_IDS" ]]; }
if gpu_passthrough; then
  [[ -n "${GPU_PCI_SLOT:-}" ]] || die "$HOST_CONFIG sets GPU_PCI_IDS but not GPU_PCI_SLOT"
  [[ "$IOMMU" == intel || "$IOMMU" == amd ]] || die "IOMMU must be intel or amd, not '$IOMMU'"
fi
log "Host config: $HOST_CONFIG (provider $PROVIDER_NAME, GPU passthrough: $(gpu_passthrough && echo yes || echo no))"

# --- Preflight: firmware virtualization ---------------------------------------
# VT-x / AMD-V gives the CPU's KVM support (/dev/kvm). VT-d / AMD-Vi is the
# IOMMU, which remaps DMA from a device so it can only reach its own VM's
# memory; needed only for passthrough. Both are firmware (BIOS) settings.
[[ -e /dev/kvm ]] || die "/dev/kvm missing: enable CPU virtualization (VT-x / AMD-V) in the firmware"
if gpu_passthrough; then
  compgen -G '/sys/class/iommu/*' >/dev/null || die "no IOMMU: enable VT-d / AMD-Vi in the firmware"
fi
if grep -qw hypervisor /proc/cpuinfo; then die "this is a VM; the host must be bare metal"; fi

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
  log "WARNING: Secure Boot is enabled; unsigned modules will not load"
fi

# --- Host packages ------------------------------------------------------------
# avahi/ssh-import-id/wpasupplicant: may be missing after an offline install.
# swtpm, polkitd, libnss-systemd, dbus: banlieue's Cloud Hypervisor host needs them
# (it installs no OS packages itself). genisoimage, qemu-utils: the k0s node
# bootstrap builds cloud-init seed ISOs and qcow2 disks.
pkgs=(avahi-daemon ssh-import-id wpasupplicant
      systemd libnss-systemd dbus polkitd swtpm swtpm-tools ca-certificates
      genisoimage qemu-utils pciutils)
missing=()
for p in "${pkgs[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if (( ${#missing[@]} )); then
  log "Installing: ${missing[*]}"
  apt-get update
  apt-get install -y --no-install-recommends "${missing[@]}"
fi

# --- sshd: Ubuntu's default config ------------------------------------------
# After the first (offline) install, /etc/ssh/sshd_config held only the
# installer's "PasswordAuthentication no": openssh-server arrived later by
# hand, and dpkg keeps an existing conffile. Without the packaged default
# there is no Include (drop-ins ignored), no sftp Subsystem (scp fails with
# "subsystem request failed") and no UsePAM. Restore it and keep the
# keys-only policy as a drop-in.
if ! grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config; then
  log "Restoring Ubuntu's default sshd_config (keys only via sshd_config.d)"
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-homelab
  install -m 0644 /usr/share/openssh/sshd_config /etc/ssh/sshd_config
  SSHD_CHANGED=1
fi
SSHD_DROPIN=/etc/ssh/sshd_config.d/50-homelab.conf
want_sshd=$'# homelab-k0s: keys only (also set by the autoinstall)\nPasswordAuthentication no\nKbdInteractiveAuthentication no'
if [[ "$(cat "$SSHD_DROPIN" 2>/dev/null)" != "$want_sshd" ]]; then
  printf '%s\n' "$want_sshd" > "$SSHD_DROPIN"
  SSHD_CHANGED=1
fi
if [[ "${SSHD_CHANGED:-0}" == 1 ]]; then
  sshd -t                    # never reload a config that doesn't parse
  systemctl reload ssh       # existing sessions survive a reload
fi

# --- GPU passthrough (VFIO) ---------------------------------------------------
if gpu_passthrough; then
# No NVIDIA driver on the host:
# the driver lives in the GPU VM (bootstrap/node/prepare-gpu-node.sh). A host
# driver would race vfio-pci for the card. Don't purge automatically.
if dpkg -l 'nvidia-*' 'linux-modules-nvidia-*' 2>/dev/null | grep -q '^ii'; then
  log "WARNING: NVIDIA packages are installed on the host. Remove them:"
  log "  sudo apt-mark unhold 'nvidia-*'; sudo apt-get purge 'nvidia-*' 'linux-modules-nvidia-*'"
fi

# nouveau would grab the card first if allowed to load.
NOUVEAU_CONF=/etc/modprobe.d/blacklist-nouveau.conf
want=$'blacklist nouveau\noptions nouveau modeset=0'
if [[ "$(cat "$NOUVEAU_CONF" 2>/dev/null)" != "$want" ]]; then
  log "Blacklisting nouveau"
  printf '%s\n' "$want" > "$NOUVEAU_CONF"
  INITRAMFS_NEEDED=1
fi

# Bind the GPU to vfio-pci at boot.
# vfio-pci claims every function by vendor:device ID. The softdeps make
# sure it loads before the drivers that would otherwise claim them
# (snd_hda_intel, xhci_pci and i2c_nvidia_gpu also drive the Intel chipset's
# own devices, so they can't be blacklisted, only ordered). The softdeps name
# NVIDIA's drivers; for another vendor's GPU add its driver here.
# disable_vga=1: opt the card out of legacy VGA arbitration; the host has no
# use for it.
VFIO_CONF=/etc/modprobe.d/vfio.conf
want=$(cat <<EOF
options vfio-pci ids=$GPU_PCI_IDS disable_vga=1
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
softdep xhci_pci pre: vfio-pci
softdep i2c_nvidia_gpu pre: vfio-pci
EOF
)
if [[ "$(cat "$VFIO_CONF" 2>/dev/null)" != "$want" ]]; then
  log "Binding GPU ($GPU_PCI_IDS) to vfio-pci"
  printf '%s\n' "$want" > "$VFIO_CONF"
  INITRAMFS_NEEDED=1
fi
# In the initramfs, so vfio-pci wins even against drivers loaded that early.
for m in vfio vfio_iommu_type1 vfio_pci; do
  if ! grep -qx "$m" /etc/initramfs-tools/modules; then
    echo "$m" >> /etc/initramfs-tools/modules
    INITRAMFS_NEEDED=1
  fi
done
if [[ "${INITRAMFS_NEEDED:-0}" == 1 ]]; then
  update-initramfs -u
  REBOOT_NEEDED=1
fi

# Kernel: <vendor>_iommu=on turns on DMA remapping (Ubuntu's kernel already
# does for Intel, but say so explicitly). iommu=pt keeps host-owned devices
# on an identity mapping, so only passed-through devices pay translation cost.
GRUB_VFIO=/etc/default/grub.d/91-homelab-vfio.cfg
want_grub='GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} '"${IOMMU}"'_iommu=on iommu=pt"'
if [[ "$(cat "$GRUB_VFIO" 2>/dev/null)" != "$want_grub" ]]; then
  log "Adding ${IOMMU}_iommu=on iommu=pt to the kernel command line"
  printf '%s\n' "$want_grub" > "$GRUB_VFIO"
  GRUB_NEEDED=1
fi
fi  # gpu_passthrough

# --- Dual-boot (optional, DUAL_BOOT=true) ------------------------------------
if [[ "$DUAL_BOOT" == true ]]; then
# Show the GRUB menu for 10s with a Windows entry; Ubuntu boots if untouched,
# so unattended reboots/power cuts still come back as a cluster host.
# os-prober only *reads* the Windows ESP to build the menu entry.
# RECORDFAIL: after an unclean shutdown Ubuntu otherwise waits at the menu
# (no timeout on some setups), which would strand a headless host.
# The menu still shows on a passed-through GPU: vfio-pci takes it later in boot.
if ! dpkg-query -W -f='${Status}' os-prober 2>/dev/null | grep -q 'install ok installed'; then
  log "Installing os-prober"
  apt-get install -y os-prober
fi
GRUB_DROPIN=/etc/default/grub.d/90-homelab-dualboot.cfg
want_grub=$'GRUB_TIMEOUT_STYLE=menu\nGRUB_TIMEOUT=10\nGRUB_RECORDFAIL_TIMEOUT=10\nGRUB_DISABLE_OS_PROBER=false'
if [[ "$(cat "$GRUB_DROPIN" 2>/dev/null)" != "$want_grub" ]]; then
  log "Configuring GRUB menu (10s, with Windows)"
  printf '%s\n' "$want_grub" > "$GRUB_DROPIN"
  GRUB_NEEDED=1
fi
grep -q "Windows Boot Manager" /boot/grub/grub.cfg \
  || log "WARNING: os-prober did not add a Windows entry to GRUB (the firmware boot menu still works)"
# `sudo reboot-to-windows` boots Windows once; the next reboot returns to Linux.
install -m 0755 "$repo/helpers/dual-boot/reboot-to-windows.sh" /usr/local/bin/reboot-to-windows
fi  # DUAL_BOOT
if [[ "${GRUB_NEEDED:-0}" == 1 ]]; then
  update-grub
  REBOOT_NEEDED=1
fi

# --- VM network: a routed bridge ---------------------------------------------
# VMs get their own subnet behind the host instead of sharing the LAN: it
# works with any uplink (a Wi-Fi client can't join a Linux bridge, the access
# point drops frames from MACs that never associated), and every host gets a
# non-overlapping subnet, so hosts scale out by routing, not by stretching
# one L2 segment. The host holds LAB_ADDR, hands out DHCP, and NATs VM
# traffic out of its uplink. systemd-networkd does all three. These files live in
# /etc/systemd/network beside netplan's generated ones in /run; netplan
# doesn't manage this bridge, and reloading doesn't touch wlo1.
# ConfigureWithoutCarrier: an empty bridge has no carrier until a VM's tap
# joins it, and the address must exist before that (VMs ping it at boot).
NETDEV=/etc/systemd/network/50-$LAB_BRIDGE.netdev
NETWORK=/etc/systemd/network/50-$LAB_BRIDGE.network
want_netdev=$(cat <<EOF
[NetDev]
Name=$LAB_BRIDGE
Kind=bridge
EOF
)
# DNS for VMs: the host's resolved, via an extra stub listener on the bridge
# address, so VMs follow whatever DNS the uplink hands the host.
want_network=$(cat <<EOF
[Match]
Name=$LAB_BRIDGE

[Link]
RequiredForOnline=no

[Network]
Address=$LAB_ADDR
ConfigureWithoutCarrier=yes
IPMasquerade=ipv4
DHCPServer=yes

[DHCPServer]
PoolOffset=100
PoolSize=100
EmitDNS=yes
DNS=_server_address
EOF
)
net_changed=0
if [[ "$(cat "$NETDEV" 2>/dev/null)" != "$want_netdev" ]]; then
  printf '%s\n' "$want_netdev" > "$NETDEV"; net_changed=1
fi
if [[ "$(cat "$NETWORK" 2>/dev/null)" != "$want_network" ]]; then
  printf '%s\n' "$want_network" > "$NETWORK"; net_changed=1
fi
if (( net_changed )); then
  log "Configuring $LAB_BRIDGE ($LAB_ADDR, DHCP .100-.199, NAT out)"
  networkctl reload
fi
for _ in {1..20}; do [[ -e /sys/class/net/$LAB_BRIDGE ]] && break; sleep 0.5; done
[[ -e /sys/class/net/$LAB_BRIDGE ]] || die "$LAB_BRIDGE did not appear; check: networkctl status $LAB_BRIDGE"
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/50-$LAB_BRIDGE.conf
want_resolved=$'[Resolve]\nDNSStubListenerExtra='"${LAB_ADDR%/*}"
if [[ "$(cat "$RESOLVED_DROPIN" 2>/dev/null)" != "$want_resolved" ]]; then
  log "Serving DNS to VMs on ${LAB_ADDR%/*}"
  install -d /etc/systemd/resolved.conf.d
  printf '%s\n' "$want_resolved" > "$RESOLVED_DROPIN"
  systemctl restart systemd-resolved
fi

# --- Tailscale (optional, TAILSCALE_SUBNET_ROUTER=true) -----------------------
# Reaching the VM subnet from other machines needs a route to it. Where the
# LAN router can't hold one (here: a mesh behind the ISP router), the host
# advertises LAB_CIDR as a Tailscale subnet route instead. It also connects
# the subnets of several hosts to each other.
if [[ "$TAILSCALE_SUBNET_ROUTER" == true ]]; then
if [[ "$(dpkg-query -W -f='${Version}' tailscale 2>/dev/null)" != "$TAILSCALE_VERSION" ]]; then
  log "Installing tailscale $TAILSCALE_VERSION"
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-mark unhold tailscale >/dev/null 2>&1 || true
  apt-get install -y --allow-downgrades "tailscale=$TAILSCALE_VERSION"
fi
apt-mark hold tailscale >/dev/null
fi  # TAILSCALE_SUBNET_ROUTER

# --- k0sctl -------------------------------------------------------------------
# The node bootstrap runs on this host and installs k0s into the VMs with it.
if [[ "$(k0sctl version 2>/dev/null | awk '/^version:/{print $2}')" != "v$K0SCTL_VERSION" ]]; then
  log "Installing k0sctl $K0SCTL_VERSION"
  tmp=$(mktemp -d)
  curl -fsSLo "$tmp/k0sctl" \
    "https://github.com/k0sproject/k0sctl/releases/download/v$K0SCTL_VERSION/k0sctl-linux-amd64"
  echo "$K0SCTL_SHA256  $tmp/k0sctl" | sha256sum -c --quiet -
  install -m 0755 "$tmp/k0sctl" /usr/local/bin/k0sctl
  rm -rf "$tmp"
fi

# --- kubectl ------------------------------------------------------------------
# The node bootstrap checks for it, and the cluster bootstrap applies the
# Flux Operator and the FluxInstance with it.
if [[ "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" != "v$KUBECTL_VERSION" ]]; then
  log "Installing kubectl $KUBECTL_VERSION"
  tmp=$(mktemp -d)
  curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/amd64/kubectl"
  echo "$KUBECTL_SHA256  $tmp/kubectl" | sha256sum -c --quiet -
  install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
fi

# --- AppArmor: let swtpm keep vTPM state where banlieue puts it ---------------
# Ubuntu confines swtpm to libvirt's paths (/var/lib/libvirt/swtpm, ...).
# banlieue keeps vTPM state and its EK CA scratch under /var/lib/banlieue and
# sockets under /run/banlieue, so without this `install` fails at its EK CA
# stage ("apparmor=DENIED operation=mknod profile=swtpm"). The profile
# includes local/usr.bin.swtpm for exactly this; the packaged file stays
# untouched. (banlieue is tested on Debian 13, which doesn't hit this.)
SWTPM_LOCAL=/etc/apparmor.d/local/usr.bin.swtpm
want_aa=$'# banlieue Cloud Hypervisor host (homelab-k0s prepare-host.sh)\n/var/lib/banlieue/** rwk,\n/run/banlieue/** rwk,'
if [[ -f /etc/apparmor.d/usr.bin.swtpm && "$(cat "$SWTPM_LOCAL" 2>/dev/null)" != "$want_aa" ]]; then
  log "Allowing swtpm to use /var/lib/banlieue and /run/banlieue (AppArmor)"
  printf '%s\n' "$want_aa" > "$SWTPM_LOCAL"
  apparmor_parser -r /etc/apparmor.d/usr.bin.swtpm
fi

# --- banlieue: Cloud Hypervisor host ------------------------------------------
# One binary: `banlieue host cloud-hypervisor install` sets up the VMM, its
# firmware, the guest uid range, polkit rule and template units, and later
# runs as this host's provider. Its install is itself idempotent; it leaves
# the provider unit disabled until the host gets a cluster credential.
if [[ "$(banlieue --version 2>/dev/null)" != *"$BANLIEUE_VERSION"* ]]; then
  log "Installing banlieue $BANLIEUE_VERSION"
  tmp=$(mktemp -d)
  curl -fsSLo "$tmp/banlieue.tar.gz" \
    "https://github.com/firestoned/banlieue/releases/download/v$BANLIEUE_VERSION/banlieue-linux-amd64.tar.gz"
  echo "$BANLIEUE_SHA256  $tmp/banlieue.tar.gz" | sha256sum -c --quiet -
  tar -xzf "$tmp/banlieue.tar.gz" -C "$tmp" banlieue
  install -m 0755 "$tmp/banlieue" /usr/local/bin/banlieue
  rm -rf "$tmp"
fi
log "banlieue host cloud-hypervisor install"
banlieue host cloud-hypervisor install \
  --provider-name "$PROVIDER_NAME" \
  --network-class "default=$LAB_BRIDGE" \
  --storage-class "default=$CH_STORAGE" \
  --guest-memory-max "$GUEST_MEMORY_MAX"

# --- Summary ------------------------------------------------------------------
# Also true on a re-run before the reboot that the first run asked for.
if gpu_passthrough; then grep -qw 'iommu=pt' /proc/cmdline || REBOOT_NEEDED=1; fi
if (( REBOOT_NEEDED )); then
  log "Done. Reboot, then re-run this script to verify (it changes nothing the second time)."
  exit 0
fi

if gpu_passthrough; then
  log "GPU functions (all must say vfio-pci):"
  bad=0
  for d in /sys/bus/pci/devices/"$GPU_PCI_SLOT".*; do
    f="$(basename "$d")"
    drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null || true)
    printf '    %s  %s  iommu_group=%s\n' "$f" "${drv:-none}" \
      "$(basename "$(readlink "$d/iommu_group")")"
    [[ "$drv" == vfio-pci ]] || bad=1
  done
  (( bad )) && log "WARNING: not every GPU function is on vfio-pci; see the GPU passthrough guide (troubleshooting)"
fi
log "$LAB_BRIDGE: $(ip -br addr show "$LAB_BRIDGE" | awk '{print $3}')"
if [[ "$TAILSCALE_SUBNET_ROUTER" != true ]]; then
  :
elif ! tailscale status >/dev/null 2>&1; then
  log "Tailscale is not logged in. Once, interactively:"
  log "  sudo tailscale up --advertise-routes=$LAB_CIDR --accept-dns=false"
  log "  then approve the route in the Tailscale admin console"
elif [[ "$(tailscale debug prefs 2>/dev/null | jq -r .CorpDNS)" == true ]]; then
  # MagicDNS would make tailscale0 the host's (and so the VMs') default DNS
  # route; it made name resolution flaky. A subnet router doesn't need
  # tailnet names: keep the uplink's DNS.
  log "Tailscale: not taking over host DNS (--accept-dns=false)"
  tailscale set --accept-dns=false
fi
if gpu_passthrough; then log "Next: sudo ./bootstrap/host/gpu-smoke-vm.sh up"; fi
