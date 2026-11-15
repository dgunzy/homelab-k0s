---
title: OS install helper
description: An unattended Ubuntu Server install from a USB stick built on Windows, for a dual-boot host. Optional.
---

`helpers/os-install/` builds an Ubuntu Server autoinstall USB stick from Windows, for hosts
that dual-boot. It isn't part of the platform: any Ubuntu 24.04 Server install works. It's kept
because rebuilding the example host from nothing should take a stick and a few minutes, not an
afternoon of clicking.

## What it does

- `build-usb.ps1` verifies the pinned ISO checksum, refuses any disk that isn't USB, prompts for
  the Wi-Fi and login passwords (never stored in git), pulls **all** your SSH keys from
  `github.com/<user>.keys`, extracts the ISO to a FAT32 volume and writes the rendered
  `autoinstall.yaml`.
- `hosts/<host>/autoinstall.yaml` installs to one named disk model only (the install fails
  rather than picking another disk), creates its own EFI partition so the Windows ESP is never
  written, disables swap and password SSH, and grants the admin user passwordless sudo.
- Because `autoinstall` isn't on the kernel command line, the installer still asks before
  touching disks: a deliberate safety catch on a dual-boot machine.

```powershell
.\helpers\os-install\build-usb.ps1 -GitHubUser <user> -UsbDriveLetter F
```

Use a rear motherboard USB port (hubs can fail to enumerate the stick), choose the stick's UEFI
entry in the firmware boot menu, confirm the autoinstall prompt, then wipe the stick: it holds
the Wi-Fi password.

## Dual boot

`helpers/dual-boot/reboot-to-windows.sh` boots Windows once (UEFI `BootNext`) and leaves Linux
as the default, so unattended reboots and power cuts always come back as a host. With
`DUAL_BOOT=true` in the host config, `prepare-host.sh` installs it and shows a 10-second GRUB
menu with a Windows entry.

## Install retrospective

The first install only worked after manual repair. Each problem and the fix now in the template:

| What broke | Cause | Fix |
|---|---|---|
| `netplan apply`: "networkd backend does not support wifi with match:" | networkd matches Wi-Fi by interface name only | Key `wifis:` by interface name |
| Wi-Fi never came up in the installer, so the install ran offline | The live server ISO has no `wpa_supplicant` | `early-commands` installs it from the ISO's own package pool |
| The package step aborted the install (apt exit 100) | Offline, any package not on the ISO fails | Only ISO-pool packages in `packages:`; the rest best-effort, later |
| No Wi-Fi, SSH server or working apt sources after the offline install | The same abort | Late-commands install them from the pool and write real apt sources |
| `sudo` asked for a password | The sudoers late-command never ran after the abort | Sudoers first, safety nets after |
| "Login incorrect" with the right password | Windows PowerShell piped the password with CRLF; `openssl passwd -stdin` stripped only the LF | Exact bytes to openssl's stdin, and a self-check with the same salt |

### First boot checks

```sh
ip -br a                                         # uplink has an address
dpkg -l openssh-server wpasupplicant | grep ^ii
sudo apt-get update                              # apt sources work
sudo -n true && echo "passwordless sudo OK"
```

### No network after install

Install `wpasupplicant` from the stick (partition 1):

```sh
sudo mount /dev/sdX1 /mnt
sudo dpkg -i /mnt/pool/main/p/pcsc-lite/libpcsclite1_*.deb /mnt/pool/main/w/wpa/wpasupplicant_*.deb
sudo netplan apply
```
