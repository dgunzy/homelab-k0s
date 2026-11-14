#!/usr/bin/env bash
# Boot into Windows ONCE. The next reboot after that comes back to Linux.
#
# Uses the UEFI BootNext variable: a one-shot override that the firmware
# clears after using it. The saved boot order (Ubuntu first) is not changed,
# and nothing on the Windows disk is touched.
#
# Usage (works over SSH; ops has passwordless sudo):
#   ssh ops@k0s-gpu-01.local sudo reboot-to-windows
#   sudo reboot-to-windows --dry-run    # show what it would do
set -euo pipefail

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi

# efibootmgr lines look like: "Boot0000* Windows Boot Manager<TAB>HD(...)"
entry=$(efibootmgr | awk '/Windows Boot Manager/ { sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1; exit }')
if [[ -z "$entry" ]]; then
  echo "No 'Windows Boot Manager' UEFI entry found. efibootmgr output:" >&2
  efibootmgr >&2
  exit 1
fi

echo "Windows Boot Manager is Boot${entry}"
if (( dry_run )); then
  echo "dry run: would run 'efibootmgr --bootnext ${entry}' and reboot"
  exit 0
fi

efibootmgr --bootnext "$entry" >/dev/null
echo "BootNext=${entry} set. Rebooting into Windows..."
systemctl reboot
