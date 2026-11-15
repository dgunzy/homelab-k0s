---
title: Hypervisor hosts
description: Bare-metal hosts that run VMs, own one subnet each, and hand GPUs to guests whole.
---

A host is a bare-metal Linux machine whose only job is to run VMs. It runs no Kubernetes
itself: every Kubernetes node in the platform is a VM on some host.

## What a host runs

| Piece | Why |
|---|---|
| **KVM + Cloud Hypervisor** | A small Rust VMM, one process per VM, run by systemd. No hypervisor daemon to keep alive, and each guest runs as its own unprivileged uid, sandboxed with seccomp and Landlock. |
| **banlieue's host provider** | A systemd service that is this host's *Provider* in the management cluster. It watches the machines assigned to this host and creates, starts and deletes their VMs. It holds a self-renewing ServiceAccount token and no hypervisor credentials. |
| **VFIO** (GPU hosts) | Every function of the GPU's IOMMU group is bound to `vfio-pci` at boot, so the host never loads a vendor driver and the GPU can be handed to a VM. See [GPUs, done properly](../gpu/). |
| **A routed VM bridge** | The host's VMs live on their own subnet behind the host. See below. |
| **Optional** | Tailscale as a subnet router; dual-boot helpers for a desktop host. |

All of it is set up by one idempotent script, `bootstrap/host/prepare-host.sh`, driven by a
per-host config file `bootstrap/host/hosts/<hostname>.env`. A host without a GPU leaves
`GPU_PCI_IDS` empty and skips the VFIO part. See [Prepare a host](../../guides/prepare-a-host/).

## One host, one subnet

Each host owns a non-overlapping subnet on a Linux bridge (`10.42.0.0/24` on the first host,
`10.43.0.0/24` on the next, ...). The host is the gateway: it serves DHCP and DNS on the bridge
and NATs VM traffic out of its uplink.

- **It works on any uplink.** A Wi-Fi client can't join a Linux bridge (the access point drops
  frames from MACs that never associated), so bridging VMs onto the LAN isn't always possible.
  Routing always is.
- **It scales by routing, not by stretching L2.** Adding a host adds a subnet and a route. Nodes
  on different hosts reach each other through those routes, the way cloud regions and racks do.
- **Routes to the VM subnets** come from the LAN router if it can hold static routes, or from
  each host advertising its subnet as a Tailscale subnet route. The second also reaches the
  platform from anywhere.
- **Nodes need stable addresses.** Node VMs get fixed MACs and static DHCP leases; Kubernetes
  doesn't survive a node changing address.

## One host, one failure domain

Each host registers as one banlieue `Provider`, which is one failure domain. The scheduler
places VMs onto Providers that have room (banlieue tracks capacity per host), and node pools
can spread across hosts. Losing a host loses its VMs and nothing else.

Hosts are also where availability differs: a dual-boot desktop is up when it's in Linux, a
rack server is always on. Put control-plane-critical things on the always-on hosts.

## Adding a host

1. Install a server Linux (Ubuntu 24.04 is what's tested).
2. Copy a host config, give it its own `PROVIDER_NAME` and subnet, and run `prepare-host.sh`.
3. Add its `Provider` to `infrastructure/hosts/` and issue it a credential
   (`bootstrap-mgmt.sh provider` does this for the first host).
4. Route the new subnet: a LAN route, or a Tailscale subnet route.

The [example deployment](../../example/desktop-host/) runs one host today.
