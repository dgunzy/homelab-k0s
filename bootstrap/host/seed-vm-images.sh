#!/usr/bin/env bash
# Put the pinned Ubuntu cloud image into banlieue's image cache, as the raw
# file a `BackingFile` VMImage names (infrastructure/vm-catalog/).
#
# banlieue's Cloud Hypervisor provider only boots raw images (image_type=raw;
# auto-detection disables sector-0 writes on v53), and a BackingFile is a file
# the operator places in a storage class's images/ directory: the provider
# never downloads it. This script is that placement, made reproducible.
#
#   sudo ./bootstrap/host/seed-vm-images.sh
#
# Idempotent: an image already in the cache is left as it is. Files are named
# after the image's release, so a new pin is a new file and a new VMImage,
# never a change under a running guest.
set -euo pipefail

# --- Pins ---------------------------------------------------------------------
# Same image and pin as gpu-smoke-vm.sh and bootstrap/cluster/mgmt.env.
IMAGE_URL="https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_SHA256="04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
# What the VMImage's `ref` names.
RAW_NAME="ubuntu-24.04-server-cloudimg-amd64-20261017.raw"

CACHE="/var/lib/homelab/images"
IMAGES="/var/lib/banlieue/ch/images"    # storage class "default" (prepare-host.sh)

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ -d "$IMAGES" ]] || die "$IMAGES missing; run prepare-host.sh"

dest="$IMAGES/$RAW_NAME"
if [[ -f "$dest" ]]; then
  log "$RAW_NAME already in the cache"
  exit 0
fi

src="$CACHE/$(basename "$IMAGE_URL")"
install -d -m 0755 "$CACHE"
if [[ ! -f "$src" ]]; then
  log "Downloading $(basename "$IMAGE_URL")"
  curl -fL --progress-bar -o "$src.part" "$IMAGE_URL"
  mv "$src.part" "$src"
fi
echo "$IMAGE_SHA256  $src" | sha256sum -c --quiet - || die "checksum mismatch: $src"

# Convert next to the destination, then rename, so the provider never sees a
# half-written image. Sparse: the 3.5 GiB raw image holds ~2 GiB of data.
log "Converting to raw: $dest"
tmp="$dest.part"
qemu-img convert -f qcow2 -O raw "$src" "$tmp"
chown banlieue:banlieue "$tmp"
chmod 0640 "$tmp"
mv "$tmp" "$dest"
log "Done: $(du -h --apparent-size "$dest" | cut -f1) apparent, $(du -h "$dest" | cut -f1) on disk"
