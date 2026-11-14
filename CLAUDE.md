# Homelab GPU cluster

Bootstrap repo for a GPU Kubernetes lab on my desktop (dual-boot Linux) with an NVIDIA GPU.
The desktop is a **KVM hypervisor host**; k0s nodes are Cloud Hypervisor VMs on it, and the GPU
is passed through to a worker VM. Purpose: learn GPU workloads on Kubernetes, GPU node lifecycle
(Cluster API, node images, health/remediation), inference serving, and agents, using the same
building blocks production GPU clouds use (VFIO passthrough, GPU Operator, DCGM, CAPI, batch
schedulers). This is a learning lab, not production, but treat it like a real platform:
declarative, reproducible, versioned. Design and reasons: `docs/02-virtualized-gpu-cluster.md`.

## Hardware and host

- Desktop "k0s-gpu-01": i7-8700 (6c/12t), 16 GB RAM (2× 8 GB in the DIMM2 slots; DIMM1 slots
  free, upgrade undecided), RTX 2070 (Turing TU106, 8 GB VRAM, compute capability 7.5).
  Dual-boots with Windows.
- Linux distro: Ubuntu Server 24.04.5 LTS, installed via autoinstall (`bootstrap/install/`).
- Disks: Linux owns **only** the ADATA SU650 240 GB SSD (own ESP + LVM). The WD 1 TB SSD is
  Windows; the WD 1 TB HDD is unused (candidate for Linux bulk storage later; ask first).
- Network: **Wi-Fi only** (Intel AC 9461, `wlo1`), on a mesh router behind the ISP router
  (double NAT, no static routes). Ethernet to the desk isn't possible. The I219-V port is
  configured but unplugged.
- Firmware: UEFI, Secure Boot off, BitLocker off, **VT-x and VT-d on**.
- The 2070 is the only display device (iGPU hidden), so the host is headless once VFIO owns it.
- A Dell PowerEdge R610 (no GPU, old CPUs) may join later as a second CPU-only hypervisor host.
  Don't assume it exists yet.

## Hard rules

- **Never touch the Windows install.** Do not modify, format, or resize partitions, the EFI system
  partition, or boot entries without asking me first and showing the exact command.
- Anything destructive (disks, `k0s reset`, deleting VMs/PVs/namespaces) needs explicit confirmation.
- Scripts must be idempotent and safe to re-run. Use `set -euo pipefail` in bash.
- Pin versions (OS image, cloud images, NVIDIA driver branch, k0s, banlieue, Helm charts, images,
  Flux) with checksums where a download is involved. No `latest`.
- No secrets in git. Plan is SOPS + age once Flux is in place.
- Don't execute scripts from downloaded third-party repos to explore them; read them.

## Repo layout (target: keep to this as it grows)

```
bootstrap/        everything before Flux
  install/        OS install: autoinstall templates + USB builder (run from Windows)
  host/           hypervisor host prep + GPU smoke VM (run on the host)
  node/           in-VM prep (GPU worker driver)
  cluster/        management cluster bootstrap (banlieue bootstrap script, pinned) (added later)
clusters/homelab/ Flux entry point (added later)
infrastructure/   cluster add-ons: banlieue, cluster-api, k0smotron, gpu-operator, monitoring, kueue
apps/             workloads: inference servers, agent sandboxes
docs/             notes on what I learned and why things are set up this way
```

## Virtualization (banlieue + Cloud Hypervisor)

- banlieue v0.5.7 is installed on the host by `prepare-host.sh` (`banlieue host cloud-hypervisor
  install`): Cloud Hypervisor VMM + CLOUDHV.fd firmware under `/opt/banlieue`, guest template
  units, and the host provider (disabled until it gets a cluster credential).
- The **management cluster's node** is not a banlieue object: it's built by banlieue's
  `scripts/bootstrap-k0s-cluster.sh` as plain systemd units (ADR-0099), because banlieue needs
  the cluster to exist first. Use `CH_TPM=false` (vTPM fix not released upstream).
- Everything after that is declarative: banlieue `VirtualMachine`/`VirtualMachinePool`, and
  Cluster API with banlieue as infrastructure provider and k0smotron as hosted control plane.
- banlieue is `v1alpha1` and moves fast. Pin it and read its ADRs (`docs/adr/`) before relying
  on behaviour. Known gaps: no PCI/GPU passthrough in the API, global VM sizing in the bootstrap
  script (docs/02, "Gaps").

## Network

- `br-lab` (systemd-networkd, files in `/etc/systemd/network/`): host `10.42.0.1/24`, DHCP
  `.100–.199`, NAT out of `wlo1`, DNS from the host's resolved on `10.42.0.1`.
- k0s nodes get fixed MACs and static addresses below `.100`. The smoke VM is `10.42.0.10`.
- The host is a Tailscale subnet router for `10.42.0.0/24` (the router can't hold static routes).
- A Wi-Fi interface can't be bridged; don't try to put VMs on the home LAN.

## k0s specifics (easy to get wrong)

- k0s runs **inside the VMs**, never on the host.
- k0s ships its **own containerd**: socket `/run/k0s/containerd.sock`, and it imports drop-in
  config from `/etc/k0s/containerd.d/*.toml`. Tools that assume `/etc/containerd/config.toml`
  or `/run/containerd/containerd.sock` will silently do the wrong thing.
- Data lives under `/var/lib/k0s`. Verify paths against the current k0s docs before relying on them.

## GPU setup

- **Whole-GPU passthrough with VFIO.** All four functions of the 2070 (`10de:1f02`, `10de:10f9`,
  `10de:1ada`, `10de:1adb`; IOMMU group 1, alone with the x16 root port) are bound to `vfio-pci`
  at boot by `prepare-host.sh`. Only `01:00.0` goes to the GPU VM.
- **No NVIDIA driver on the host.** The driver (R580 LTSB, `server-open`, apt-held) is installed
  inside the GPU VM by `bootstrap/node/prepare-gpu-node.sh`.
- VFIO pins all of a GPU VM's RAM: no overcommit, and the VMM needs `LimitMEMLOCK=infinity`
  and access to `/dev/vfio/*`.
- Verify passthrough with `bootstrap/host/gpu-smoke-vm.sh` (`nvidia-smi` in a throwaway VM)
  before building nodes on it.
- In the GPU VM, GPU Operator runs with `driver.enabled=false` at first. Point its container
  toolkit at k0s's containerd:
  - `CONTAINERD_CONFIG=/etc/k0s/containerd.d/nvidia.toml`
  - `CONTAINERD_SOCKET=/run/k0s/containerd.sock`
  - `RUNTIME_CLASS=nvidia`, and workloads set `runtimeClassName: nvidia` where needed
- No vGPU, MIG or SR-IOV on this card. Share the GPU inside Kubernetes with GPU Operator
  **time-slicing** (then MPS, DRA).
- Verify the GPU end to end with a CUDA sample pod requesting `nvidia.com/gpu: 1`.

## Inference constraints (RTX 2070)

- 8 GB VRAM: stick to small models (roughly 7–8B quantized: GGUF/AWQ/GPTQ, or smaller in fp16).
- Turing has no bf16, so use fp16 or quantized weights. Some newer kernels (e.g. FlashAttention 2) won't run.
- Start with Ollama or llama.cpp; try vLLM with small models once the basics work.
- Wi-Fi is ~70 Mbps: multi-GB CUDA images and model weights are slow to pull. Cache, don't re-pull.

## Roadmap (rough order; details and exit checks in docs/02)

1. ~~Hypervisor host + GPU passthrough proven with the smoke VM~~ (done 2026-11-14)
2. Management cluster (one CH VM) + Flux via **Flux Operator** (`FluxInstance`, not
   `flux bootstrap`); banlieue, Cluster API, k0smotron as add-ons under `infrastructure/`
3. GPU worker via Cluster API (needs GPU passthrough in banlieue: contribute upstream);
   GPU Operator, CUDA test pod passing
4. Node image pipeline: driver baked in, signed, SBOM, CVE gate, rolling image upgrades
5. DCGM exporter + Prometheus/Grafana; health and remediation (NVSentinel vs. my own controller
   in Rust or Go), MachineHealthCheck, fault injection
6. Scheduling: time-slicing vs MPS, Kueue, KAI Scheduler, DRA; Slurm on Kubernetes (Slinky)
7. Inference servers and agent sandboxes (banlieue `VirtualMachinePool`) under `apps/`
8. bindy for lab DNS once there are LoadBalancer Services / Gateway routes to name

## How I like to work

- I'm a platform engineer (Kubernetes, Flux, Flux Operator contributor). Skip basics; explain
  GPU/inference/virtualization-specific concepts when they come up. That's the part I'm learning.
- Prefer Rust or Go for any custom tooling; bash is fine for bootstrap glue.
- Keep changes small and explain *why*, so `docs/` can capture what I learned.
