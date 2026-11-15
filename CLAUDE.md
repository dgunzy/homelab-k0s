# GPU Platform Blueprint (repo: homelab-k0s)

A **reference architecture** for GPU inference and sandboxed AI agents on Kubernetes, built the
way GPU platforms are: bare-metal **hypervisor hosts** (Cloud Hypervisor via banlieue, GPUs passed
through with VFIO), a small **management cluster** (Flux Operator, Cluster API, k0smotron,
banlieue), **hosted control planes** and node pools of VMs for one or more **workload clusters**
(inference and agents together or split), and **gitless GitOps** from a signed OCI artifact.
Treat it like a real platform: declarative, reproducible, versioned, scalable beyond one host.

The repo is the architecture; my desktop is just the **example deployment** (one host). Keep
host-specific details in `bootstrap/host/hosts/<host>.env`, `helpers/` and the docs'
"Example deployment" section, not in the architecture pages or generic scripts.

Docs site: `docs/` (Astro Starlight under Bun, published to GitHub Pages by
`.github/workflows/docs.yaml`). The docs are the design record: update them with changes.

## Example deployment: the one host today

- Desktop "k0s-gpu-01" (config: `bootstrap/host/hosts/k0s-gpu-01.env`): i7-8700 (6c/12t), 16 GB RAM (2× 8 GB in the DIMM2 slots; DIMM1 slots
  free, upgrade undecided), RTX 2070 (Turing TU106, 8 GB VRAM, compute capability 7.5).
  Dual-boots with Windows.
- Linux distro: Ubuntu Server 24.04.5 LTS, installed via autoinstall (`helpers/os-install/`).
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
- Pin versions (OS image, cloud images, NVIDIA driver branch, k0s, banlieue, add-on manifests,
  images) with checksums where a download is involved. No `latest`. **One deliberate exception:**
  Flux itself (`FluxInstance` `distribution.version: "2.x"`) and the Flux Operator follow the
  latest release from their signed distribution artifact. It's a test cluster; I chose this.
- **No Helm / HelmReleases.** Add-ons are their projects' raw release manifests, vendored by
  `hack/vendor.sh` at pinned versions, applied by Flux Kustomizations. No CAPI Operator or
  clusterctl either: Flux `postBuild` substitution resolves clusterctl `${VAR:=default}` placeholders.
- No secrets in git. Plan is SOPS + age once Flux is in place.
- Don't execute scripts from downloaded third-party repos to explore them; read them.

## Repo layout (target: keep to this as it grows)

```
bootstrap/        everything before Flux
  host/           hypervisor host prep, per-host configs (hosts/<host>.env), GPU smoke VM, VM image seeding
  node/           in-VM prep (GPU worker driver)
  cluster/        management cluster: mgmt.env + bootstrap-mgmt.sh (wraps banlieue's pinned script)
clusters/homelab/ Flux entry point: FluxInstance, flux-operator self-update, add-on Kustomizations
infrastructure/   vendored add-on manifests, one dir each: cert-manager, cluster-api, k0smotron,
                  banlieue, hosts (banlieue Providers); later gpu-operator, monitoring, kueue
apps/             workloads (today: the smoke VM)
workload-clusters/<name>/  Cluster API definition of a workload cluster (Cluster, K0smotronControlPlane,
                  one MachineDeployment + templates per pool); Flux: clusters/homelab/workload-clusters.yaml
hack/vendor.sh    pins + re-vendoring of infrastructure/ and schemas/
schemas/          JSON schemas for CRDs missing from the flux-schema catalog (banlieue)
.github/workflows validate (flux-schema + shellcheck), publish (signed OCI artifact), docs (Pages)
docs/             the docs site (Astro Starlight + React Flow diagrams, Bun); content in docs/src/content/docs/
helpers/          optional, example-host specific: os-install (USB autoinstall from Windows), dual-boot
notes/            gitignored personal notes: upstream (banlieue) issue drafts, specs, tracking
```

## GitOps (docs: architecture/gitops)

- Gitless: CI pushes the repo as an OCI artifact `ghcr.io/dgunzy/homelab-k0s-manifests`
  (`:<short-sha>` and `:latest`), signed with cosign keyless; the FluxInstance verifies the
  signature (identity: `publish.yaml` on `main`) and syncs `clusters/homelab`.
- Validate locally before pushing: `flux schema validate --config .fluxschema.yml <dir>` for
  `clusters/homelab` and each `infrastructure/*` dir. CI runs the same via the flux-schema action.
- To bump an add-on: change its pin in `hack/vendor.sh`, run it, review the diff. banlieue's
  version also lives in `prepare-host.sh` and `bootstrap-mgmt.sh`; keep the three in step.
- Never enable `postBuild` substitution on banlieue's Kustomization (literal `${FQDN}` templates).
- banlieue VMs on the Cloud Hypervisor host must be in `banlieue-system` (VMs only schedule onto
  Providers in their own namespace; External Providers live there). Images are raw `BackingFile`s
  placed by `bootstrap/host/seed-vm-images.sh`; catalog in `infrastructure/vm-catalog/`.
- Use `providers.banlieue.io`, not `provider`, with kubectl (Cluster API has a `Provider` kind too).
- CAPI machines (`CloudHypervisorMachineTemplate`) name the host's own class names
  (`storageClass: default`, `networkClass: default`), not the Provider's abstract
  `standard`/`lab` that VMClasses use. banlieue (v0.5.8+, ADR-0129) copies each Machine's
  bootstrap Secret into the machine's userData; the template carries none.

## Virtualization (banlieue + Cloud Hypervisor)

- banlieue v0.5.8 is installed on the host by `prepare-host.sh` (`banlieue host cloud-hypervisor
  install`): Cloud Hypervisor VMM + CLOUDHV.fd firmware under `/opt/banlieue`, guest template
  units, and the host provider (disabled until it gets a cluster credential).
- The **management cluster's node** is not a banlieue object: it's built by banlieue's
  `scripts/bootstrap-k0s-cluster.sh` as plain systemd units (ADR-0099), because banlieue needs
  the cluster to exist first. Use `CH_TPM=false` (vTPM fix not released upstream).
- Everything after that is declarative: banlieue `VirtualMachine`/`VirtualMachinePool`, and
  Cluster API with banlieue as infrastructure provider and k0smotron as hosted control plane.
- banlieue is `v1alpha1` and moves fast. Pin it and read its ADRs (`docs/adr/`) before relying
  on behaviour. Upstream gaps and issues (GPU passthrough #190, CAPI bootstrap data #191, ...)
  are tracked in the gitignored `notes/banlieue-upstream.md`, not in the docs: they're not part
  of the architecture story.

## Network

- `br-lab` (systemd-networkd, files in `/etc/systemd/network/`): host `10.42.0.1/24`, DHCP
  `.100–.199`, NAT out of `wlo1`, DNS from the host's resolved on `10.42.0.1`.
- k0s nodes get fixed MACs and static addresses below `.100`. The smoke VM is `10.42.0.10`.
- The host is a Tailscale subnet router for `10.42.0.0/24` (the router can't hold static routes),
  with `--accept-dns=false`: MagicDNS as the host's DNS made resolution flaky for host and VMs.
- The management node `mgmt-01` is `10.42.0.11` (static DHCP lease by MAC, set by bootstrap-mgmt.sh).
- A Wi-Fi interface can't be bridged; don't try to put VMs on the home LAN.

## k0s specifics (easy to get wrong)

- Kubernetes: **latest minor everywhere** (1.37, `K0S_VERSION` in `bootstrap/cluster/mgmt.env`, kubectl
  pin in `prepare-host.sh`). Running clusters upgrade one minor at a time:
  `bootstrap-mgmt.sh upgrade` walks `K0S_UPGRADE_PATH`. Check add-on support matrices first
  (cert-manager v1.21 officially stops at 1.36). mgmt has run 1.37.2 since 2026-11-15, so
  banlieue's MutatingAdmissionPolicies are vendored unfiltered.
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

## Roadmap (rough order; status and exit checks in docs: reference/roadmap)

1. ~~Hypervisor host + GPU passthrough proven with the smoke VM~~ (done 2026-11-14)
2. ~~Management cluster (one CH VM) + Flux via **Flux Operator**; banlieue, Cluster API,
   k0smotron as add-ons; a test VirtualMachine through banlieue~~ (done 2026-11-14)
3. ~~Upgrade mgmt to Kubernetes 1.37, drop the MAP filter~~ (done 2026-11-15). Then
   workload cluster `ai-01` (`workload-clusters/ai-01/`, written; its Flux Kustomization is
   `suspend: true` until I flip it in git): k0smotron-hosted control plane (k0s 1.37), node pools
   `cpu` (written) and `gpu` (needs banlieue GPU passthrough, #190); GPU Operator, CUDA test
   pod passing. Substrate's feature gates go on the control plane in phase 7.
   One combined cluster on this host; the architecture supports many (e.g. inference split
   from agent clusters). mgmt stays tiny.
4. Node image pipeline: driver baked in, signed, SBOM, CVE gate, rolling image upgrades
5. DCGM exporter + Prometheus/Grafana; health and remediation (NVSentinel vs. my own controller
   in Rust or Go), MachineHealthCheck, fault injection
6. Scheduling: time-slicing vs MPS, Kueue, KAI Scheduler, DRA; Slurm on Kubernetes (Slinky)
7. Workloads: inference server on GPU pools; Agent Substrate (CNCF, gVisor mode; no KVM in our
   VMs, no GPUs for actors yet) on CPU pools; agents reach inference through Substrate's egress
   gateway (same cluster, or across clusters)
8. bindy for lab DNS once there are LoadBalancer Services / Gateway routes to name

## How I like to work

- I'm a platform engineer (Kubernetes, Flux, Flux Operator contributor). Skip basics; explain
  GPU/inference/virtualization-specific concepts when they come up. That's the part I'm learning.
- Prefer Rust or Go for any custom tooling; bash is fine for bootstrap glue.
- Keep changes small and explain *why*, so the docs site can capture it.
- Docs diagrams: interactive React Flow components (`docs/src/components/flow/`); each diagram is
  a data file in `diagrams/` (layers, nodes with real project logos from `src/assets/logos/`,
  edges). Check new diagrams in a browser (light and dark) before calling them done.
