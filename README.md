# homelab-k0s

A GPU Kubernetes lab on a dual-boot desktop with an RTX 2070. The desktop is a
KVM hypervisor: k0s nodes run as Cloud Hypervisor VMs (via
[banlieue](https://github.com/firestoned/banlieue)), and the GPU is passed
through whole to a worker VM. On top of that: GPU Operator, DCGM telemetry,
Cluster API node lifecycle, inference serving, batch scheduling. Everything
is declarative and pinned, so the host can be rebuilt from this repo and a
USB stick. The design and its reasons are in
[docs/02](docs/02-virtualized-gpu-cluster.md).

## Layout

```
bootstrap/
  install/                  OS install (run from Windows)
    build-usb.ps1           builds the autoinstall USB stick
    hosts/k0s-gpu-01/       autoinstall template (no secrets)
  host/                     the hypervisor host (run on k0s-gpu-01)
    prepare-host.sh         VFIO, br-lab network, banlieue CH host, k0sctl, tailscale, GRUB
    gpu-smoke-vm.sh         throwaway VM that proves GPU passthrough end to end
    reboot-to-windows.sh    one-shot boot into Windows
  node/                     inside VMs
    prepare-gpu-node.sh     pinned NVIDIA driver for the GPU worker VM
  cluster/                  the management cluster (run on the host)
    mgmt.env                node, image and k0s settings for banlieue's bootstrap script
    bootstrap-mgmt.sh       node -> flux -> provider
clusters/homelab/           Flux entry point: FluxInstance, add-on Kustomizations
infrastructure/             vendored release manifests: cert-manager, cluster-api, k0smotron, banlieue, hosts
hack/vendor.sh              add-on version pins; re-vendors infrastructure/ and schemas/
schemas/                    JSON schemas for banlieue CRDs (not in the flux-schema catalog yet)
.github/workflows/          validate (flux-schema, shellcheck), publish (signed OCI artifact)
docs/                       what I learned and why it's set up this way
```

Later: `apps/` (inference, sandboxes), GPU Operator and monitoring under
`infrastructure/`. See [CLAUDE.md](CLAUDE.md) for the roadmap and
[docs/03](docs/03-gitops.md) for the GitOps design.

## Hardware: k0s-gpu-01

| | |
|---|---|
| Board | ASUS TUF B360M-PLUS GAMING S, BIOS 3202 (UEFI; boot menu **F8**, setup **Del**) |
| CPU / RAM | i7-8700 (6c/12t), 16 GB (2× 8 GB DDR4-2666; two slots free) |
| GPU | NVIDIA RTX 2070 (TU106, Turing, 8 GB, CC 7.5), IOMMU group 1 on its own |
| Network | Wi-Fi, Intel AC 9461 (`wlo1`); I219-V Ethernet configured but unplugged |

| Disk | Use |
|---|---|
| WD Blue SSD 1 TB | **Windows**. Never touched by Linux. |
| WD Blue HDD 1 TB | Unused (Windows `E:`, empty). |
| **ADATA SU650 240 GB** | **Linux**: own ESP + LVM root. The installer matches `*SU650*` only. |

## 1. Build the USB (Windows)

1. Download `ubuntu-24.04.5-live-server-amd64.iso` from https://releases.ubuntu.com/24.04.5/
   into `~\Downloads\ubuntu-iso\`. Its SHA256 is pinned in the script.
2. Add **every** device's SSH public key to your GitHub account; the stick gets all of them.
3. Use a FAT32 USB volume (it gets erased). On a stick with two partitions, give
   the drive letter of the FAT32 one. Run:
   ```powershell
   cd ~\homelab-k0s
   .\bootstrap\install\build-usb.ps1 -GitHubUser <github-user> -UsbDriveLetter F
   ```
   It verifies the password hash it writes and prints a command to double-check it on Linux.

## 2. Install

1. Plug the stick into a **rear motherboard USB port** (the desk hub fails to enumerate it).
2. Reboot, press **F8**, and choose the **UEFI:** entry for the USB stick.
3. Choose **Try or Install Ubuntu Server**. At **"Continue with autoinstall?"**, answer yes.
4. It installs to the ADATA disk only and then reboots. Remove the stick and wipe it,
   since it holds the Wi-Fi PSK.
5. At the console, run the first-boot checks in
   [docs/01](docs/01-host-install.md#first-boot-checks-run-at-the-console-or-over-ssh).
   If there's no network, follow the recovery steps there.

Ubuntu adds an `ubuntu` UEFI boot entry and puts it first, so power-on boots Linux.

## 3. BIOS (once)

**Del** at power-on → Advanced Mode (F7):

- Advanced → CPU Configuration → **Intel Virtualization Technology: Enabled** (VT-x, for KVM)
- Advanced → System Agent (SA) Configuration → **VT-d: Enabled** (IOMMU, for GPU passthrough)
- Optional: System Agent → Graphics Configuration → **iGPU Multi-Monitor: Enabled**, so
  the motherboard's HDMI can show a Linux console once the 2070 belongs to a VM.

## 4. Host prep (on the node)

```bash
ssh ops@k0s-gpu-01.local
git clone https://github.com/<github-user>/homelab-k0s && cd homelab-k0s
sudo ./bootstrap/host/prepare-host.sh   # VFIO, br-lab, banlieue CH host, k0sctl, tailscale, GRUB
sudo reboot
sudo ./bootstrap/host/prepare-host.sh   # again: verifies all four GPU functions are on vfio-pci
sudo tailscale up --advertise-routes=10.42.0.0/24 --accept-dns=false   # once; approve the route in the admin console
```

After this the host is headless (the 2070 belongs to VFIO) and runs no NVIDIA driver.

## 5. Prove GPU passthrough

```bash
sudo ./bootstrap/host/gpu-smoke-vm.sh up       # Ubuntu VM with the 2070, at 10.42.0.10
sudo ./bootstrap/host/gpu-smoke-vm.sh verify   # installs R580 in the guest, runs nvidia-smi
sudo ./bootstrap/host/gpu-smoke-vm.sh destroy  # when done
```

From the MacBook (over Tailscale, or through the host):
`ssh -J ops@k0s-gpu-01.local ubuntu@10.42.0.10`.

## 6. Management cluster

One-time, before the `flux` step: push to `main` so CI publishes
`ghcr.io/dgunzy/homelab-k0s-manifests`, then make that package **public**
(GitHub → Packages → Package settings → Change visibility).

```bash
./bootstrap/cluster/bootstrap-mgmt.sh node       # mgmt-01 (10.42.0.11): CH VM + k0s
./bootstrap/cluster/bootstrap-mgmt.sh flux       # Flux Operator + FluxInstance; Flux takes over from here
./bootstrap/cluster/bootstrap-mgmt.sh provider   # this host's banlieue provider joins the cluster
./bootstrap/cluster/bootstrap-mgmt.sh status
```

From the MacBook (over Tailscale):
`scp ops@k0s-gpu-01.local:.kube/homelab-mgmt.kubeconfig ~/.kube/` then
`KUBECONFIG=~/.kube/homelab-mgmt.kubeconfig kubectl get nodes`.

Validate manifests before pushing: `flux schema validate --config .fluxschema.yml clusters/homelab`
(`flux plugin install schema` once).

## Switching between Linux and Windows

Only one OS runs at a time. Linux is the default, so a power cut or an unattended
reboot always comes back as the cluster host (VMs start at boot).

| Where you are | To get Windows | To get Linux |
|---|---|---|
| At the machine | Pick **Windows Boot Manager** in the GRUB menu (shown for 10s at every boot) | Restart; Ubuntu is the default |
| Another device (e.g. MacBook), Linux running | `ssh ops@k0s-gpu-01.local sudo reboot-to-windows` (one-shot UEFI `BootNext`) | n/a |

F8 at power-on still works as a fallback. To SSH from a new device, add its
public key to GitHub and run `ssh-import-id gh:<github-user>` on the node.
macOS resolves `.local` names out of the box (Bonjour).

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Ubuntu Server | 24.04.5 LTS (SHA256 pinned) | `build-usb.ps1` |
| banlieue (incl. Cloud Hypervisor v53.0 + firmware it pins) | v0.5.7 (SHA256 pinned) | `prepare-host.sh` |
| k0sctl | v0.31.3 (SHA256 pinned) | `prepare-host.sh` |
| Tailscale | 1.104.7, apt-held | `prepare-host.sh` |
| Ubuntu cloud image (VMs) | noble `release-20261017` (SHA256 pinned) | `gpu-smoke-vm.sh` |
| NVIDIA driver (in the GPU VM) | R580 `server-open` (LTSB), apt-held | `prepare-gpu-node.sh` |
| kubectl (host) | v1.35.10 (SHA256 pinned) | `prepare-host.sh` |
| k0s | v1.35.10+k0s.0 | `bootstrap/cluster/mgmt.env` |
| banlieue bootstrap script | v0.5.7 (SHA256 pinned) | `bootstrap-mgmt.sh` |
| cert-manager | v1.21.3 | `hack/vendor.sh` |
| Cluster API | v1.14.4 | `hack/vendor.sh` |
| k0smotron | v2.3.1 | `hack/vendor.sh` |
| banlieue (in cluster) | v0.5.7 (SHA256 pinned) | `hack/vendor.sh` |
| Flux, Flux Operator | **latest** 2.x / latest, by choice (test cluster) | `flux-instance.yaml`, `flux-operator.yaml` |
