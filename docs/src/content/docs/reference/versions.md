---
title: Versions
description: Every pinned version, and where the pin lives.
---

Everything is pinned, with checksums wherever a download is involved. The one deliberate
exception is Flux, which follows its latest 2.x release.

## Hosts

| Component | Version | Pinned in |
|---|---|---|
| Ubuntu Server | 24.04 LTS | host install |
| banlieue (host binary; pins Cloud Hypervisor v53.0 and its firmware) | v0.5.8 | `bootstrap/host/prepare-host.sh` |
| k0sctl | v0.31.3 | `bootstrap/host/prepare-host.sh` |
| kubectl | v1.37.2 | `bootstrap/host/prepare-host.sh` |
| Tailscale | 1.104.7 | `bootstrap/host/prepare-host.sh` |
| VM cloud image | Ubuntu 24.04, release 20261017 | `gpu-smoke-vm.sh`, `seed-vm-images.sh`, `mgmt.env` |
| GPU driver (in GPU node VMs) | NVIDIA R580 `server-open` (LTSB) | `bootstrap/node/prepare-gpu-node.sh` |

## Management cluster

| Component | Version | Pinned in |
|---|---|---|
| k0s (Kubernetes) | v1.37.2+k0s.1 (latest); upgrades step through v1.36.6 | `bootstrap/cluster/mgmt.env` |
| banlieue bootstrap script | v0.5.8 | `bootstrap/cluster/bootstrap-mgmt.sh` |
| cert-manager | v1.21.3 (latest; officially supports Kubernetes up to 1.36) | `hack/vendor.sh` |
| Cluster API | v1.14.4 (supports Kubernetes 1.37 from v1.14.1) | `hack/vendor.sh` |
| k0smotron | v2.3.1 (tested on k0s 1.35, 1.36, 1.37) | `hack/vendor.sh` |
| banlieue (in-cluster) | v0.5.8 | `hack/vendor.sh` |
| Flux, Flux Operator | latest 2.x / latest | `clusters/homelab/flux-system/` |

## Tooling

| Component | Version | Pinned in |
|---|---|---|
| flux-schema | v0.17.0 | `.github/workflows/validate.yaml` |
| Docs: Astro / Starlight / React Flow | 7.4 / 0.43 / 12.12 | `docs/package.json`, `docs/bun.lock` |
| Bun | 1.4 | `.github/workflows/docs.yaml` |

## Kubernetes version policy

Clusters run the latest Kubernetes minor. Before moving to a new one, check every component's
support matrix (Cluster API, k0smotron, cert-manager, banlieue): a component that hasn't
certified the new minor yet is called out above. Running clusters upgrade **one minor at a
time** (`bootstrap-mgmt.sh upgrade` walks `K0S_UPGRADE_PATH`); workload clusters upgrade by
changing their `K0smotronControlPlane` and machine template versions, also one minor at a time.
