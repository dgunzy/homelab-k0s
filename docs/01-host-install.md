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

**The NVIDIA driver is installed after the OS, pinned.** The autoinstall
`drivers: install: true` option installs whatever `ubuntu-drivers` recommends on
the day, which isn't reproducible. `bootstrap/host/prepare-host.sh` pins it
instead:

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

The GPU Operator will run with `driver.enabled=false` and reuse this host
driver. Its containerized driver is the better fit for immutable fleets, but on
a dual-boot desktop with normal kernel updates the host driver is simpler.

**Linux is the default boot; Windows is one-shot.** The node should come back
as a cluster member after any reboot or power loss without anyone touching it.
`reboot-to-windows` sets the UEFI `BootNext` variable. The firmware uses it for
exactly one boot and then clears it. The persistent `BootOrder` is never
rewritten, so the next restart from Windows lands back in Linux.

**mDNS (avahi) for discovery.** The node advertises `k0s-gpu-01.local`, so
SSH works without router DNS or knowing the DHCP lease. When the second node
joins, k0sctl will still use stable IPs, via DHCP reservations. mDNS is for
humans, not for cluster plumbing.

## Things to revisit

- Wi-Fi → Ethernet. Image and model pulls are slow at ~70 Mbps.
- Root disk is 240 GB. CUDA images run 5–20 GB each, so watch
  `/var/lib/k0s/containerd`. The 1 TB HDD is a candidate for model storage.
- Secure Boot: turning it on would require MOK enrollment for any DKMS-built module.
