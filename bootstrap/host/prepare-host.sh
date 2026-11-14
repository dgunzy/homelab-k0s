#!/usr/bin/env bash
# Host prep for k0s-gpu-01 as a KVM hypervisor (docs/02-virtualized-gpu-cluster.md).
#
# The host runs no k0s and no NVIDIA driver. The k0s nodes are Cloud
# Hypervisor VMs on this host, and the RTX 2070 is handed to one of them
# with VFIO. This script prepares that:
#   - VFIO: IOMMU on, all four GPU functions bound to vfio-pci at boot
#   - br-lab: a routed bridge (10.42.0.0/24) with DHCP and NAT, because a
#     Wi-Fi uplink can't be bridged
#   - banlieue's Cloud Hypervisor host install (VMM, firmware, guest units)
#   - k0sctl, tailscale (subnet router for br-lab), host packages
#   - dual-boot GRUB menu and reboot-to-windows (unchanged)
#
# Run on the node after the autoinstall:  sudo ./bootstrap/host/prepare-host.sh
# Idempotent: safe to re-run; it only changes what isn't already in place.
set -euo pipefail

# --- Pins ---------------------------------------------------------------------
# GPU functions on 01:00 (lspci -nn -s 01:00): VGA, HDMI audio, USB-C xHCI,
# USB-C UCSI. All four sit in IOMMU group 1 with the CPU's x16 root port. A
# group is the smallest unit the IOMMU can isolate, so every endpoint in it
# must leave its host driver before any of them can go to a VM.
GPU_PCI_IDS="10de:1f02,10de:10f9,10de:1ada,10de:1adb"
GPU_PCI_SLOT="0000:01:00"

BANLIEUE_VERSION="0.5.7"
# From the release's checksums.sha256 (signed with the release).
BANLIEUE_SHA256="996f5c3a46c5fab38de53c97de9c0ea432292f74376b3a29ebd96014d8b9774a"
K0SCTL_VERSION="0.31.3"
K0SCTL_SHA256="c055473be106deead180594f2610b8cca5fec97e69a710c92c1f26088bbd2255"
TAILSCALE_VERSION="1.104.7"

# The VM network. The host is the router: 10.42.0.1 on br-lab.
LAB_BRIDGE="br-lab"
LAB_ADDR="10.42.0.1/24"
LAB_CIDR="10.42.0.0/24"

# banlieue's Cloud Hypervisor host. One Provider per host (banlieue ADR-0060).
PROVIDER_NAME="k0s-gpu-01"
CH_STORAGE="/var/lib/banlieue/ch"
# Ceiling for banlieue-managed guests (sandboxes), NOT the k0s node VMs,
# which run in banlieue-nodes.slice. Small until the RAM upgrade.
GUEST_MEMORY_MAX="2G"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then echo "run as root (sudo)" >&2; exit 1; fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBOOT_NEEDED=0

# --- Preflight: firmware virtualization ---------------------------------------
# VT-x gives the CPU's KVM support (/dev/kvm). VT-d is the IOMMU, which
# remaps DMA from a device so it can only reach its own VM's memory. Both are
# BIOS settings (Advanced > CPU Configuration, Advanced > System Agent).
[[ -e /dev/kvm ]] || die "/dev/kvm missing: enable Intel Virtualization Technology (VT-x) in the BIOS"
compgen -G '/sys/class/iommu/dmar*' >/dev/null || die "no DMAR unit: enable VT-d in the BIOS"
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

# --- No NVIDIA driver on the host ---------------------------------------------
# The driver lives in the GPU VM (bootstrap/node/prepare-gpu-node.sh). A host
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

# --- VFIO: bind the GPU to vfio-pci at boot -----------------------------------
# vfio-pci claims the four functions by vendor:device ID. The softdeps make
# sure it loads before the drivers that would otherwise claim them
# (snd_hda_intel, xhci_pci and i2c_nvidia_gpu also drive the Intel chipset's
# own devices, so they can't be blacklisted, only ordered).
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

# Kernel: intel_iommu=on turns on DMA remapping (Ubuntu's kernel already
# does, but say so explicitly). iommu=pt keeps host-owned devices on an
# identity mapping, so only passed-through devices pay translation cost.
GRUB_VFIO=/etc/default/grub.d/91-homelab-vfio.cfg
want_grub='GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} intel_iommu=on iommu=pt"'
if [[ "$(cat "$GRUB_VFIO" 2>/dev/null)" != "$want_grub" ]]; then
  log "Adding intel_iommu=on iommu=pt to the kernel command line"
  printf '%s\n' "$want_grub" > "$GRUB_VFIO"
  GRUB_NEEDED=1
fi

# --- Dual-boot: GRUB menu -----------------------------------------------------
# Show the GRUB menu for 10s with a Windows entry; Ubuntu boots if untouched,
# so unattended reboots/power cuts still come back as a cluster host.
# os-prober only *reads* the Windows ESP to build the menu entry.
# RECORDFAIL: after an unclean shutdown Ubuntu otherwise waits at the menu
# (no timeout on some setups), which would strand a headless host.
# The menu still shows on the 2070: vfio-pci only takes it later in boot.
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
if [[ "${GRUB_NEEDED:-0}" == 1 ]]; then
  update-grub
  REBOOT_NEEDED=1
fi
grep -q "Windows Boot Manager" /boot/grub/grub.cfg \
  || log "WARNING: os-prober did not add a Windows entry to GRUB (F8 still works)"

# `sudo reboot-to-windows` boots Windows once; the next reboot returns to Linux.
install -m 0755 "$script_dir/reboot-to-windows.sh" /usr/local/bin/reboot-to-windows

# --- br-lab: routed VM network ------------------------------------------------
# A Wi-Fi client can't join a Linux bridge (the access point drops frames
# from MACs that never associated), so VMs can't sit on the home LAN. Instead
# the host routes: br-lab has 10.42.0.1/24, hands out DHCP, and NATs VM
# traffic out of wlo1. systemd-networkd does all three. These files live in
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
# DNS for VMs: the host's resolved, via an extra stub listener on 10.42.0.1,
# so VMs follow whatever DNS the Wi-Fi network hands the host.
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

# --- Tailscale: reach br-lab from other devices -------------------------------
# The home router (a mesh behind the ISP router) can't hold a static route to
# 10.42.0.0/24, so this host advertises it as a Tailscale subnet route.
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
grep -qw 'iommu=pt' /proc/cmdline || REBOOT_NEEDED=1
if (( REBOOT_NEEDED )); then
  log "Done. Reboot, then re-run this script to verify (it changes nothing the second time)."
  exit 0
fi

log "GPU functions (all must say vfio-pci):"
bad=0
for f in "$GPU_PCI_SLOT".{0,1,2,3}; do
  drv=$(basename "$(readlink "/sys/bus/pci/devices/$f/driver" 2>/dev/null)" 2>/dev/null || true)
  printf '    %s  %s  iommu_group=%s\n' "$f" "${drv:-none}" \
    "$(basename "$(readlink "/sys/bus/pci/devices/$f/iommu_group")")"
  [[ "$drv" == vfio-pci ]] || bad=1
done
(( bad )) && log "WARNING: not every GPU function is on vfio-pci; see docs/02 (troubleshooting)"
log "$LAB_BRIDGE: $(ip -br addr show "$LAB_BRIDGE" | awk '{print $3}')"
if ! tailscale status >/dev/null 2>&1; then
  log "Tailscale is not logged in. Once, interactively:"
  log "  sudo tailscale up --advertise-routes=$LAB_CIDR"
  log "  then approve the route in the Tailscale admin console"
fi
log "Next: sudo ./bootstrap/host/gpu-smoke-vm.sh up"
