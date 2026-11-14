# homelab-k0s

A single-node k0s cluster for learning GPU workloads on Kubernetes: GPU Operator,
DCGM telemetry, inference serving, batch scheduling. It runs on a dual-boot desktop
with an RTX 2070. Everything is declarative and pinned, so the node can be rebuilt
from this repo and a USB stick.

## Layout

```
bootstrap/
  install/                  OS install (run from Windows)
    build-usb.ps1           builds the autoinstall USB stick
    hosts/k0s-gpu-01/       autoinstall template (no secrets)
  host/
    prepare-host.sh         pinned NVIDIA driver, nouveau blacklist (run on the node)
docs/                       what I learned and why it's set up this way
```

Later: `clusters/homelab/` (Flux Operator), `infrastructure/` (GPU Operator,
monitoring, Kueue), `apps/` (inference, agents). See [CLAUDE.md](CLAUDE.md) for the roadmap.

## Hardware: k0s-gpu-01

| | |
|---|---|
| Board | ASUS TUF B360M-PLUS GAMING S (UEFI; boot menu **F8**, setup **Del**) |
| CPU / RAM | i7-8700 (6c/12t), 16 GB |
| GPU | NVIDIA RTX 2070 (Turing, 8 GB, CC 7.5) |
| Network | Wi-Fi, Intel AC 9461; I219-V Ethernet configured but unplugged |

| Disk | Use |
|---|---|
| WD Blue SSD 1 TB | **Windows**. Never touched by Linux. |
| WD Blue HDD 1 TB | Unused (Windows `E:`, empty). |
| **ADATA SU650 240 GB** | **Linux**: own ESP + LVM root. The installer matches `*SU650*` only. |

## 1. Build the USB (Windows)

1. Download `ubuntu-24.04.5-live-server-amd64.iso` from https://releases.ubuntu.com/24.04.5/
   into `~\Downloads\ubuntu-iso\`. Its SHA256 is pinned in the script.
2. Make sure your GitHub account has an SSH public key.
3. Insert a FAT32 USB stick (it gets erased) and run:
   ```powershell
   cd ~\homelab-k0s
   .\bootstrap\install\build-usb.ps1 -GitHubUser <github-user> -UsbDriveLetter F
   ```

## 2. Install

1. Reboot, press **F8**, and choose the **UEFI:** entry for the USB stick.
2. Choose **Try or Install Ubuntu Server**. At **"Continue with autoinstall?"**, answer yes.
3. It installs to the ADATA disk only and then reboots. Remove the stick and wipe it,
   since it holds the Wi-Fi PSK.

Ubuntu adds an `ubuntu` UEFI boot entry and puts it first, so power-on boots Linux.

## 3. Host prep (on the node)

```bash
ssh ops@k0s-gpu-01.local                # mDNS via avahi; or use the IP shown on the console
git clone https://github.com/<github-user>/homelab-k0s && cd homelab-k0s
sudo ./bootstrap/host/prepare-host.sh   # pinned NVIDIA R580 server-open + reboot-to-windows helper
sudo reboot
nvidia-smi
```

## Switching between Linux and Windows

Linux is the default, so a power cut or a plain reboot always comes back as a cluster node.

| To | How |
|---|---|
| Windows | `ssh ops@k0s-gpu-01.local sudo reboot-to-windows` sets UEFI `BootNext` (a one-shot override) and reboots |
| Linux | Restart Windows normally |

There's no BIOS menu and no change to the saved boot order. F8 at power-on still works as a fallback.

Optional: add Windows to the GRUB menu (this only reads the Windows ESP):
```bash
echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee /etc/default/grub.d/90-os-prober.cfg
sudo update-grub
```

## Pinned versions

| Component | Version |
|---|---|
| Ubuntu Server | 24.04.5 LTS (SHA256 pinned in `build-usb.ps1`) |
| NVIDIA driver | R580 `server-open` (LTSB), apt-held |
| k0s | *next step* |
