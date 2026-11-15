---
title: Bootstrap the management cluster
description: Build the management node, hand the cluster to Flux, and connect the host's VM provider.
---

This is the only part of the platform applied by hand, and it's three commands. Run them on the
first host as the admin user, from a clone of the repository.

## Before you start

- The host is [prepared](../prepare-a-host/).
- CI has published the repository as an OCI artifact and the package is pullable by the cluster
  (public, or give the `FluxInstance` a `sync.pullSecret`). Pushing to `main` runs the
  publish workflow.
- `bootstrap/cluster/mgmt.env` holds the node's size, MAC and static address, the cloud image
  pin and the k0s version. Edit it for your host.

## 1. The node

```sh
./bootstrap/cluster/bootstrap-mgmt.sh node
```

- Gives the node's fixed MAC a static DHCP lease on the host bridge.
- Downloads banlieue's bootstrap script at the pinned release, verifies its checksum, and runs
  it: a Cloud Hypervisor VM as plain systemd units, booted from the pinned cloud image with
  cloud-init, then k0sctl installs k0s.
- Writes the admin kubeconfig to `~/.kube/<cluster>.kubeconfig`.

## 2. Flux

```sh
./bootstrap/cluster/bootstrap-mgmt.sh flux
```

Installs the Flux Operator and applies `clusters/homelab/flux-system/flux-instance.yaml`. From
here Flux reconciles the repository: the operator manages Flux, Flux manages the operator, and
every add-on follows in dependency order.

```sh
kubectl -n flux-system get fluxinstance,ocirepositories,kustomizations
```

Both `OCIRepository` objects should report a verified signature.

## 3. The host's VM provider

```sh
./bootstrap/cluster/bootstrap-mgmt.sh provider
```

Waits for Flux to create this host's `Provider`, issues the host a ServiceAccount credential,
installs it for the provider service, and starts the service. The provider renews its own token
from then on.

```sh
kubectl -n banlieue-system get providers.banlieue.io
```

`READY True` and `HEARTBEAT Alive` mean the host is ready to run VMs.

:::caution[Use the full resource name]
Cluster API also defines a `Provider` kind (clusterctl's inventory). `kubectl get provider`
resolves to that one; use `providers.banlieue.io`.
:::

:::note[Hosts that sleep]
A host that's off for longer than its token lifetime (a dual-boot desktop, for example) comes
back with an expired credential. Run `bootstrap-mgmt.sh provider` again.
:::

## From another machine

The kubeconfig points at the management node's address on the host bridge, reachable through
the subnet route:

```sh
scp <host>:.kube/homelab-mgmt.kubeconfig ~/.kube/
KUBECONFIG=~/.kube/homelab-mgmt.kubeconfig kubectl get nodes
```
