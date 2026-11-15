# GPU Platform Blueprint

A working reference architecture for running **GPU inference and sandboxed AI agents on
Kubernetes**, built the way GPU platforms are built: bare-metal hypervisor hosts, GPUs passed
through to node VMs, a small management cluster running Cluster API, hosted control planes,
and gitless GitOps from a signed OCI artifact.

**Docs:** https://dgunzy.github.io/homelab-k0s/ (source in [`docs/`](docs/))

```
Git repo ── CI: validate (flux-schema) → publish → cosign sign ──▶ signed OCI artifact
                                                                        │ pull + verify
Management cluster: Flux Operator · Cluster API · k0smotron · banlieue ◀┘
   │ machines                         │ hosted control planes (pods)
   ▼                                  ▼
Hypervisor hosts (Cloud Hypervisor, VFIO GPUs, one subnet each) ──▶ Workload clusters
                                                                     gpu pools: inference
                                                                     cpu pools: Agent Substrate (gVisor)
```

## Principles

- **Nodes are created through an API.** Workers are Cluster API machines backed by VMs:
  replace, roll and scale node pools by changing objects, never by hand.
- **Small management plane, hosted control planes, many clusters.** Control planes are pods;
  inference and agents can share a cluster or have their own.
- **A GPU belongs to one VM; sharing happens in Kubernetes** (time-slicing, MPS, DRA).
- **Agents hold no credentials and never touch the GPU.** gVisor sandboxes, egress gateway,
  inference as a service.
- **Everything is pinned, signed and validated.** Vendored release manifests, no Helm.
- **One host today, many tomorrow.** Each host is a failure domain with its own subnet.

## Layout

```
bootstrap/          host prep, GPU smoke test, management cluster bootstrap (run once, idempotent)
clusters/homelab/   what Flux syncs: FluxInstance and the add-on Kustomizations
infrastructure/     vendored release manifests (cert-manager, Cluster API, k0smotron, banlieue), hosts, VM catalog
apps/               workloads
hack/vendor.sh      add-on version pins
docs/               the docs site (Astro Starlight, Bun)
helpers/            optional: unattended OS install USB and dual-boot helpers for the example host
```

## Quick start

1. [Prepare a host](https://dgunzy.github.io/homelab-k0s/guides/prepare-a-host/):
   `sudo ./bootstrap/host/prepare-host.sh` with a host config in `bootstrap/host/hosts/`.
2. [Prove GPU passthrough](https://dgunzy.github.io/homelab-k0s/guides/gpu-passthrough/):
   `sudo ./bootstrap/host/gpu-smoke-vm.sh up && sudo ./bootstrap/host/gpu-smoke-vm.sh verify`.
3. [Bootstrap the management cluster](https://dgunzy.github.io/homelab-k0s/guides/management-cluster/):
   `./bootstrap/cluster/bootstrap-mgmt.sh node`, then `flux`, then `provider`.

Status by phase: [roadmap](https://dgunzy.github.io/homelab-k0s/reference/roadmap/).

## Docs locally

```sh
cd docs && bun install && bun run dev
```
