# Homelab GPU cluster

Bootstrap repo for a single-node k0s cluster on my desktop (dual-boot Linux) with an NVIDIA GPU.
Purpose: learn GPU workloads on Kubernetes, inference serving, and agents, using the same building
blocks production GPU fleets use (GPU Operator, DCGM, batch schedulers). This is a learning lab, not
production, but treat it like a real platform: declarative, reproducible, versioned.

## Hardware and host

- Desktop with RTX 2070 (Turing, 8 GB VRAM, compute capability 7.5). Dual-boots with Windows.
- Linux distro: Ubuntu Server 24.04.5 LTS, installed via autoinstall (`bootstrap/install/`).
- Disks: Linux owns **only** the ADATA SU650 240 GB SSD (own ESP + LVM). The WD 1 TB SSD is
  Windows; the WD 1 TB HDD is unused (candidate for Linux bulk storage later; ask first).
- Network: Wi-Fi (Intel AC 9461) for now; the I219-V Ethernet port is configured but unplugged.
- Firmware: UEFI, Secure Boot off, BitLocker off.
- A Dell PowerEdge R610 (no GPU, old CPUs) may join later as a CPU-only worker. Don't assume it exists yet.

## Hard rules

- **Never touch the Windows install.** Do not modify, format, or resize partitions, the EFI system
  partition, or boot entries without asking me first and showing the exact command.
- Anything destructive (disks, `k0s reset`, deleting PVs/namespaces) needs explicit confirmation.
- Scripts must be idempotent and safe to re-run. Use `set -euo pipefail` in bash.
- Pin versions (OS image, NVIDIA driver branch, k0s, Helm charts, images, Flux). No `latest`.
- No secrets in git. Plan is SOPS + age once Flux is in place.

## Repo layout (target: keep to this as it grows)

```
bootstrap/        host prep (drivers, kernel params, packages) + k0s install/config
  install/        OS install: autoinstall templates + USB builder (run from Windows)
  host/           post-install host prep (run on the node)
clusters/homelab/ Flux entry point (added later)
infrastructure/   cluster add-ons: gpu-operator, monitoring, storage, kueue
apps/             workloads: inference servers, agent experiments
docs/             notes on what I learned and why things are set up this way
```

## k0s specifics (easy to get wrong)

- Single node runs controller + worker: install with `k0s install controller --enable-worker`
  (or `--single`). Use `k0s kubectl` or export the admin kubeconfig.
- k0s ships its **own containerd**: socket `/run/k0s/containerd.sock`, and it imports drop-in
  config from `/etc/k0s/containerd.d/*.toml`. Tools that assume `/etc/containerd/config.toml`
  or `/run/containerd/containerd.sock` will silently do the wrong thing.
- Data lives under `/var/lib/k0s`. Verify paths against the current k0s docs before relying on them.

## GPU setup

- **Host-installed NVIDIA driver**, pinned in `bootstrap/host/prepare-host.sh`
  (R580 LTSB, `server-open` flavor, apt-held). GPU Operator runs with `driver.enabled=false`.
- Point the operator's container toolkit at k0s's containerd:
  - `CONTAINERD_CONFIG=/etc/k0s/containerd.d/nvidia.toml`
  - `CONTAINERD_SOCKET=/run/k0s/containerd.sock`
  - `RUNTIME_CLASS=nvidia`, and workloads set `runtimeClassName: nvidia` where needed
- Watch for: Secure Boot blocking the driver module (MOK signing), nouveau needing to be blacklisted
  (handled in `prepare-host.sh`).
- Verify GPU end to end with a CUDA sample pod requesting `nvidia.com/gpu: 1` before building on it.
- No MIG on this card. Use GPU Operator **time-slicing** to share the GPU between pods.

## Inference constraints (RTX 2070)

- 8 GB VRAM: stick to small models (roughly 7–8B quantized: GGUF/AWQ/GPTQ, or smaller in fp16).
- Turing has no bf16, so use fp16 or quantized weights. Some newer kernels (e.g. FlashAttention 2) won't run.
- Start with Ollama or llama.cpp; try vLLM with small models once the basics work.
- Wi-Fi is ~70 Mbps: multi-GB CUDA images and model weights are slow to pull. Cache, don't re-pull.

## Roadmap (rough order)

1. Host prep + k0s single node, reproducible from `bootstrap/`
2. GPU Operator, CUDA test pod passing
3. Flux via **Flux Operator** (`FluxInstance`), not `flux bootstrap`; move add-ons under `infrastructure/`
4. DCGM exporter + Prometheus/Grafana for GPU telemetry
5. Inference server(s) and agent experiments under `apps/`
6. Kueue for batch/GPU job scheduling; maybe a small Slurm setup to compare
7. A small GPU-node health controller (Rust or Go): watch DCGM health, cordon/drain on errors

## How I like to work

- I'm a platform engineer (Kubernetes, Flux, Flux Operator contributor). Skip basics; explain
  GPU/inference-specific concepts when they come up. That's the part I'm learning.
- Prefer Rust or Go for any custom tooling; bash is fine for bootstrap glue.
- Keep changes small and explain *why*, so `docs/` can capture what I learned.
