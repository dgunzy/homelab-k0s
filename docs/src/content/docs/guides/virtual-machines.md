---
title: Run virtual machines
description: Images, VM classes and VirtualMachines through banlieue's API.
---

Standalone VMs (test machines, sandboxes, anything that isn't a Kubernetes node) are
`VirtualMachine` objects. They're declared in the repository like everything else.

## Images

The Cloud Hypervisor provider boots **raw** disk images that are placed in each host's image
cache. `bootstrap/host/seed-vm-images.sh` converts the pinned Ubuntu cloud image (verified
against Ubuntu's published checksum) and places it:

```sh
sudo ./bootstrap/host/seed-vm-images.sh
```

The matching `VMImage` is in `infrastructure/vm-catalog/`. Image files are named after their
release, so a new image is a new file and a new `VMImage`, never a change under a running VM.

## Classes

A `VMClass` is a hardware shape: CPUs, memory, disks by storage class, NICs by network class.
VMs name a class, never sizes. Storage and network *classes* are abstract names each host's
`Provider` maps to its own directories and bridges.

## A VM

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: smoke-01-cloud-config
  namespace: banlieue-system
data:
  user-data: |
    #cloud-config
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...
---
apiVersion: banlieue.io/v1alpha1
kind: VirtualMachine
metadata:
  name: smoke-01
  namespace: banlieue-system
spec:
  classRef: { name: small }
  imageRef: { name: ubuntu-24.04-20261017 }
  placement:
    providerSelector:
      matchLabels: { homelab/host: k0s-gpu-01 }
  userData:
    configMapRef: { name: smoke-01-cloud-config }
  desiredPowerState: PoweredOn
```

```sh
kubectl -n banlieue-system get vm smoke-01 -o wide
```

`READY True` with an address from the host bridge's DHCP pool, then `ssh ubuntu@<address>`.
The phase 2 smoke VM in `apps/smoke-vm/` is exactly this.

:::caution[VMs live next to their Provider]
banlieue schedules a VM only onto Providers in the VM's own namespace, and host providers live
in `banlieue-system`. VMs on those hosts go in `banlieue-system` too.
:::

## Pools and claims

`VirtualMachinePool` keeps warm VMs ready; `VirtualMachineClaim` hands one out and returns it.
That's the VM-per-agent sandbox model, compared with Agent Substrate on the
[Sandboxed agents](../../architecture/agents/) page.
