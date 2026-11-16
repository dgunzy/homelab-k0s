---
title: Repository layout
description: Where everything lives, and what applies it.
---

```
bootstrap/                  everything before Flux; run by hand, idempotent
  host/
    prepare-host.sh         turns a bare-metal Linux machine into a hypervisor host
    hosts/<host>.env        per-host config: provider name, subnet, GPU, optional roles
    gpu-smoke-vm.sh         throwaway VM that proves GPU passthrough
    seed-vm-images.sh       places pinned raw VM images in banlieue's image cache
  node/
    prepare-gpu-node.sh     pinned GPU driver inside a GPU node VM
  cluster/
    mgmt.env                management node size, address, image and k0s version
    bootstrap-mgmt.sh       node → flux → provider
clusters/homelab/           what Flux syncs (FluxInstance spec.sync.path)
  flux-system/              the FluxInstance and the operator's self-update
  infrastructure.yaml       one Flux Kustomization per add-on, ordered with dependsOn
  apps.yaml                 workloads on the management cluster
  workload-clusters.yaml    one Flux Kustomization per workload cluster
infrastructure/             vendored release manifests, one directory per add-on
  cert-manager/  cluster-api/  k0smotron/  banlieue/
  hosts/                    one banlieue Provider per hypervisor host
  vm-catalog/               VM images and classes
apps/                       workloads (today: the smoke VM)
workload-clusters/<name>/   a workload cluster as Cluster API objects: control plane, node pools,
                            health checks, and the add-ons applied into it (addons.yaml)
cluster-addons/             vendored add-ons for workload clusters (GPU Operator)
hack/vendor.sh              add-on version pins; re-vendors infrastructure/, cluster-addons/, schemas/
hack/values/                values for the one chart-only add-on, rendered at vendor time
schemas/                    JSON schemas for CRDs not in the flux-schema catalog
.fluxschema.yml             validation config shared by CI and local runs
.github/workflows/          validate, publish (signed OCI artifact), docs
docs/                       this site (Astro Starlight, Bun)
helpers/                    optional, specific to the example deployment
  os-install/               unattended Ubuntu install USB, built from Windows
  dual-boot/                reboot a dual-boot host into Windows once
```

## What applies what

| Path | Applied by |
|---|---|
| `bootstrap/` | You, once per host or cluster |
| `clusters/`, `infrastructure/`, `apps/`, `workload-clusters/` | The management cluster's Flux, from the signed OCI artifact CI publishes |
| `cluster-addons/` | The same Flux, applied into each workload cluster through its Cluster API kubeconfig |
| `hack/`, `schemas/` | You, when bumping versions |
| `docs/` | GitHub Pages, built by CI |
| `helpers/` | You, if your hosts need them |
