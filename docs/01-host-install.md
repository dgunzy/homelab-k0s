# 01: Host install (dual boot, reproducible)

## Goal

Rebuild the GPU node from nothing but this repo and a USB stick, without
touching the Windows install on the same machine.

## Decisions and why

**A dedicated disk with its own ESP.** Linux gets the whole ADATA SU650. The
autoinstall layout creates a new EFI system partition on that disk, so the
Windows ESP on the WD SSD is never written to. Wiping or reinstalling Linux
can't break Windows. The autoinstall `match: model: "*SU650*"` means that if
the disk isn't present, the install fails instead of picking another disk.

The installer does make one firmware-level change: it adds an `ubuntu` UEFI boot
entry (NVRAM) and puts it first in the boot order. The `Windows Boot Manager`
entry is left in place. Windows is reached via the F8 boot menu, or via
os-prober in GRUB.

**Autoinstall rather than clicking through the installer.** The OS install is a
file in git (`bootstrap/install/hosts/<host>/autoinstall.yaml`). Ubuntu 24.04's
installer picks up `/autoinstall.yaml` from the root of the install media. Since
`autoinstall` isn't on the kernel command line, it still asks for confirmation
before touching disks. That's a deliberate safety catch on a dual-boot machine.

**Secrets are filled in at USB build time.** The template has placeholders for
the Wi-Fi PSK, the password hash and SSH keys. `build-usb.ps1` prompts for the
secrets and writes the rendered file only to the stick. SSH keys come from
`github.com/<user>.keys`. Password SSH login is disabled.

**Swap off.** By default the kubelet refuses to run with swap on, so it's
removed at install time rather than patched afterwards.

**The NVIDIA driver is installed after the OS, pinned, and (since
[docs/02](02-virtualized-gpu-cluster.md)) inside the GPU VM, not on this
host.** The autoinstall `drivers: install: true` option installs whatever
`ubuntu-drivers` recommends on the day, which isn't reproducible.
`bootstrap/node/prepare-gpu-node.sh` pins it instead:

- **R580**: an NVIDIA long-term support branch (LTSB). Production GPU fleets run
  LTSB branches so the driver/CUDA/kernel combination stays stable for years.
  New-feature branches move faster and get dropped sooner.
- **`-server`**: Ubuntu's packaging of the datacenter driver builds.
- **`-open`**: NVIDIA's open-source GPU *kernel modules* (the user-space CUDA
  libraries are still proprietary). They're supported on Turing and newer and
  are NVIDIA's recommended default there. Pre-Turing GPUs need the closed modules.
- **`--gpgpu` / headless**: compute-only stack, with no X server or display bits.
- Canonical's prebuilt `linux-modules-nvidia-*` are signed and track kernel
  updates, which avoids rebuilding modules with DKMS on every kernel upgrade.
- `nouveau` (the in-tree reverse-engineered driver) is blacklisted so it can't
  claim the GPU first.

The GPU Operator will run with `driver.enabled=false` and reuse this
preinstalled driver. Its containerized driver is the better fit for immutable
fleets; with the GPU node now a disposable VM, that's worth trying later
(docs/02, phase 3).

**Linux is the default boot; Windows is chosen per boot.** The node should come
back as a cluster member after any reboot or power loss without anyone touching
it. Two ways to pick Windows:

- **At the machine:** GRUB shows a menu for 10s, with a Windows entry generated
  by os-prober (it only reads the Windows ESP). `GRUB_RECORDFAIL_TIMEOUT` is
  also set. Without it, Ubuntu can wait at the menu indefinitely after an
  unclean shutdown, which would strand a headless node.
- **Remotely:** `reboot-to-windows` sets the UEFI `BootNext` variable. The
  firmware uses it for exactly one boot and then clears it. The persistent
  `BootOrder` is never rewritten.

**mDNS (avahi) for discovery.** The node advertises `k0s-gpu-01.local`, so
SSH works without router DNS or knowing the DHCP lease. When the second node
joins, k0sctl will still use stable IPs, via DHCP reservations. mDNS is for
humans, not for cluster plumbing.

**Wi-Fi is keyed by interface name (`wlo1`), not MAC.** Netplan's networkd
backend rejects `match:` on `wifis` (`netplan apply` fails with "networkd
backend does not support wifi with match:, only by interface name"). Ethernet
can still match by MAC. `wlo1` is a predictable name (onboard device index),
so it's stable for this board.

## Install retrospective (first install, and what the template now does)

The first install worked only after manual repair. Each problem, and the fix
now in the repo:

| # | What broke | Root cause | Fix |
|---|---|---|---|
| 1 | `netplan apply`: "networkd backend does not support wifi with match:" | networkd matches Wi-Fi by interface name only | `wifis:` keyed by `wlo1`. `ethernets:` can still match by MAC. |
| 2 | Wi-Fi never came up in the installer (`netplan-wpa-wlo1.service` 203/EXEC), so the install ran **offline** | The live **server** ISO has no `wpa_supplicant` | `early-commands` installs `libpcsclite1` + `wpasupplicant` from `/cdrom/pool` into the live system, before the network step. **Untested; confirm on the next install.** |
| 2a | `packages:` aborted the install (apt exit 100) | Offline, any package not in the ISO pool fails; `avahi-daemon` isn't in it | `packages:` lists pool packages only. avahi/ssh-import-id go in a best-effort late-command and in `prepare-host.sh`. |
| 2b–d | No `wpasupplicant`, no `openssh-server`, no `ssh-import-id` on the installed system | Same offline abort | `wpasupplicant` in `packages:`; late-commands `dpkg -i` it and openssh from the pool if they're missing, then enable `ssh` |
| 2e | apt sources pointed only at `file:/cdrom`, so `apt update` failed | Offline install | A late-command writes `/etc/apt/sources.list.d/ubuntu.sources` (archive + security) |
| — | `scp` failed: "subsystem request failed on channel 0" | `sshd_config` was only the installer's `PasswordAuthentication no`. openssh was installed by hand later and dpkg kept the existing file, so there was no `Include`, no sftp `Subsystem`, no `UsePAM` | `prepare-host.sh` restores `/usr/share/openssh/sshd_config` and keeps keys-only in `sshd_config.d/50-homelab.conf` (`sshd -t` before reload) |
| — | `sudo` asked for a password | The install aborted at 2a, so the `90-ops` sudoers late-command never ran | Sudoers late-commands now run first. (Fixed by hand on the current install.) |
| 3 | "Login incorrect" with the right password | `build-usb.ps1` piped the password into `openssl passwd -stdin`. Windows PowerShell 5.1 appends CRLF; openssl strips only the LF, so the hash was of `password\r` | Fed to openssl's stdin as exact UTF-8 bytes + LF, then re-hashed with the same salt as a self-check. The script prints an `openssl passwd -6 -salt …` line for checking on Linux. |
| 4 | Only one SSH key worked (and sshd was missing anyway) | GitHub had one key at build time | `build-usb.ps1` already takes **all** keys from `github.com/<user>.keys`: add every device's key before building |
| 5 | The stick didn't show in the boot menu; kernel spam about USB enumeration | The desk hub (port 1-7.1.4.1) | Use a **rear motherboard** USB port. The stick has two partitions now (32 GB FAT32 + data); the installer is on partition 1, which is the drive letter `build-usb.ps1` targets. |

### First-boot checks (run at the console or over SSH)

```bash
ip -br a                                   # wlo1 has an address?
dpkg -l openssh-server wpasupplicant avahi-daemon | grep ^ii
sudo apt-get update                        # sources sane?
sudo -n true && echo "passwordless sudo OK"
```

### Recovery: no network after install

Wi-Fi needs `wpasupplicant`. If it's missing, install it from the stick
(partition 1, mounted at e.g. `/mnt`):

```bash
sudo mount /dev/sdX1 /mnt                  # the USB stick; check with lsblk
sudo dpkg -i /mnt/pool/main/p/pcsc-lite/libpcsclite1_*.deb /mnt/pool/main/w/wpa/wpasupplicant_*.deb
sudo netplan apply
```

The same pool has `openssh-server` and `openssh-sftp-server`
(`/mnt/pool/main/o/openssh/`). USB enumeration spam on the console can be
silenced with `sudo dmesg -n 1`.

## Things to revisit

- Wi-Fi → Ethernet. Image and model pulls are slow at ~70 Mbps. Ethernet
  isn't possible at the desk for now; docs/02 routes VM traffic instead.
- Root disk is 240 GB. CUDA images run 5–20 GB each, and VM disks now live
  here too (`/var/lib/banlieue`, `/var/lib/homelab`). The 1 TB HDD is a
  candidate for model and VM storage (ask first: it's formatted for Windows).
- Secure Boot: turning it on would require MOK enrollment for any DKMS-built module.
- Timezone is `America/New_York` in the template; change it if that's wrong
  for where the machine lives.
