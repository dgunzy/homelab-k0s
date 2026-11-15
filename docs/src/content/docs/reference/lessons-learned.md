---
title: Lessons learned
description: Things that broke while building this, and what fixed them.
---

Collected while building the reference deployment. Most are general; each fix is now in the
scripts or manifests.

## Hosts and networking

| What happened | Why | Fix |
|---|---|---|
| VMs can't share the LAN when the host is on Wi-Fi | A Wi-Fi client can't be a bridge port; the access point drops frames from MACs that never associated | A routed bridge per host with DHCP, DNS and NAT; a subnet route to reach it |
| Name resolution intermittently failed on the host and in every VM | Tailscale's MagicDNS became the host's default DNS route | `--accept-dns=false` on subnet-router hosts |
| `scp` failed with "subsystem request failed" | `sshd_config` had been written before openssh was installed, so the package's defaults (sftp subsystem, `Include`, PAM) never landed | Restore the packaged default; keep policy in a drop-in |
| Kubernetes nodes can't change address | k0s doesn't survive it | Fixed MACs and static DHCP leases for node VMs |

## GPU passthrough

| What happened | Why | Fix |
|---|---|---|
| The VM tooling's install failed at its TPM step on Ubuntu | AppArmor confines `swtpm` to libvirt's paths | A local AppArmor rule, via the hook the packaged profile includes |
| Installing the guest driver upgraded the guest kernel | The prebuilt module package follows the newest kernel | Pin kernel and driver together in node images |
| A guest can't take the GPU if one function of the card is left on a host driver | Everything in an IOMMU group goes to one owner | Bind every function to `vfio-pci`, ordered ahead of the drivers that would claim them |

## Kubernetes and GitOps

| What happened | Why | Fix |
|---|---|---|
| `kubectl get provider <name>` returned NotFound for an object that existed | Cluster API also defines a `Provider` kind | Use `providers.banlieue.io` |
| A VM never scheduled | banlieue schedules VMs only onto Providers in the VM's own namespace | Put VMs for host providers in `banlieue-system` |
| An admission policy manifest failed to apply | `MutatingAdmissionPolicy` is only served from Kubernetes 1.36 | Filter it out at vendor time on older clusters |
| Flux would have erased literal `${...}` templates in a manifest | `postBuild` substitution applies to every string | Enable substitution only where a manifest is a clusterctl template |
| Interactive diagrams vanished on hover | React Flow hides nodes until measured; rebuilding node objects loses the measurements | Build nodes once; highlight with CSS |

## Installing the host OS

The example host's unattended install had its own set of lessons (an installer without Wi-Fi
support, offline package failures, a password hash broken by a stray carriage return). They're
on the [OS install helper](../../example/os-install/) page.
