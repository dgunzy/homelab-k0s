#!/usr/bin/env bash
# Host prep for a GPU node: pinned NVIDIA driver + nouveau blacklist.
# Run on the node after the autoinstall:  sudo ./bootstrap/host/prepare-host.sh
# Idempotent: safe to re-run; it only changes what isn't already in place.
set -euo pipefail

# --- Pins ---------------------------------------------------------------------
# R580 is NVIDIA's long-term support branch (LTSB). The "-server" packages are
# Ubuntu's datacenter builds of that branch. "-open" means the open GPU kernel
# modules, which NVIDIA recommends for Turing (RTX 20xx) and newer.
NVIDIA_BRANCH="580"
NVIDIA_FLAVOR="server-open"

log() { printf '==> %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then echo "run as root (sudo)" >&2; exit 1; fi

# --- Secure Boot --------------------------------------------------------------
# With Secure Boot on, the kernel only loads signed modules. Ubuntu's prebuilt
# linux-modules-nvidia-* are signed by Canonical, but DKMS builds would need MOK
# enrollment. This host runs with Secure Boot off; warn if that changes.
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
  log "WARNING: Secure Boot is enabled; only signed NVIDIA modules will load"
fi

# --- Blacklist nouveau --------------------------------------------------------
# The in-kernel open-source driver grabs the GPU first if it's allowed to load.
NOUVEAU_CONF=/etc/modprobe.d/blacklist-nouveau.conf
want=$'blacklist nouveau\noptions nouveau modeset=0'
if [[ "$(cat "$NOUVEAU_CONF" 2>/dev/null)" != "$want" ]]; then
  log "Blacklisting nouveau"
  printf '%s\n' "$want" > "$NOUVEAU_CONF"
  update-initramfs -u
  REBOOT_NEEDED=1
fi

# --- NVIDIA driver (pinned branch) --------------------------------------------
# --gpgpu installs the headless compute stack (no X/desktop bits) and prefers
# Canonical's prebuilt, signed kernel modules over DKMS.
pkg="nvidia-headless-${NVIDIA_BRANCH}-${NVIDIA_FLAVOR}"
if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
  log "Installing NVIDIA ${NVIDIA_BRANCH}-${NVIDIA_FLAVOR}"
  apt-get update
  apt-get install -y ubuntu-drivers-common
  ubuntu-drivers install --gpgpu "nvidia:${NVIDIA_BRANCH}-${NVIDIA_FLAVOR}"
  apt-get install -y "nvidia-utils-${NVIDIA_BRANCH}-server"
  REBOOT_NEEDED=1
else
  log "NVIDIA ${NVIDIA_BRANCH}-${NVIDIA_FLAVOR} already installed"
fi

# Keep apt from silently jumping to a different driver branch.
apt-mark hold "$pkg" >/dev/null

# --- Dual-boot helper ---------------------------------------------------------
# `sudo reboot-to-windows` boots Windows once; the next reboot returns to Linux.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 0755 "$script_dir/reboot-to-windows.sh" /usr/local/bin/reboot-to-windows

if [[ "${REBOOT_NEEDED:-0}" == 1 ]]; then
  log "Done. Reboot, then verify with: nvidia-smi"
else
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
fi
