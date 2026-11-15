---
title: Management plane
description: One small cluster that provisions and reconciles everything else.
---

The management cluster is deliberately small and boring. It runs controllers, not workloads:

| Component | Role |
|---|---|
| **Flux Operator + Flux** | Applies this repository to the cluster, from a signed OCI artifact. See [GitOps](../gitops/). |
| **cert-manager** | Webhook serving certificates for the Cluster API controllers. |
| **Cluster API** | The API for clusters and machines: `Cluster`, `MachineDeployment`, `Machine`, `MachineHealthCheck`. |
| **k0smotron** | Cluster API control-plane and bootstrap provider for k0s. Runs workload control planes as pods here. |
| **banlieue** | Kubernetes-native VMs: `VirtualMachine`, pools and claims for standalone VMs, and `CloudHypervisorMachine` as the Cluster API infrastructure provider for node VMs. |

Every one of these is installed from its project's own release manifest, vendored at a pinned
version, and applied by a Flux Kustomization in dependency order.

## Bootstrapping the first node

There's one chicken-and-egg problem: banlieue creates VMs through the cluster, so it can't
create the cluster's own node. The management node is therefore built outside the cluster, by
banlieue's bootstrap script: a Cloud Hypervisor VM made of plain systemd units (VMM, network,
optional vTPM) that start at boot without Kubernetes. k0sctl installs k0s into it, then Flux
takes over and nothing is applied by hand again. See
[Bootstrap the management cluster](../../guides/management-cluster/).

After a host reboot the node VM starts with the host, the cluster comes up, Flux reconciles,
and the host's provider reconnects. No manual step.

## Why k0s

k0s is a single binary with no host dependencies, which makes nodes simple to build and
rebuild. It's also what k0smotron hosts, so the management cluster and the workload control
planes run the same distribution. Nothing in the architecture depends on it: any distribution
with a Cluster API control-plane provider works.

## Sizing

The management cluster runs a few hundred MiB of controllers plus the workload control planes
(each a k0s controller and its datastore, as pods). One node with 2 vCPUs and 4–5 GiB is enough
for one or two workload clusters. Grow it, or give it three controllers on separate hosts, when
it runs more.
