---
title: Prepare a host
description: Turn a bare-metal Linux machine into a hypervisor host for the platform.
---

A host needs a server Linux install, firmware virtualization switched on, and one config file.
Everything else is one idempotent script.

## Requirements

- x86_64 bare metal (not a VM), with **VT-x / AMD-V** enabled in the firmware.
- For GPU passthrough: **VT-d / AMD-Vi** (the IOMMU) enabled, and the GPU in a slot whose IOMMU
  group contains only the GPU's own functions (and its PCIe root port).
- Ubuntu Server 24.04 is what's tested. cgroup v2 and systemd 255 are what the VM tooling expects.
- A user with passwordless `sudo` and your SSH keys.

:::tip[Check the IOMMU group before buying into passthrough]
```sh
for d in /sys/kernel/iommu_groups/*/devices/*; do
  echo "group $(basename $(dirname $(dirname $d))): $(lspci -nns ${d##*/})"
done | grep -i -A3 -B1 vga
```
If the GPU shares a group with a SATA or USB controller, use a different slot.
:::

## 1. Write the host config

Copy `bootstrap/host/hosts/k0s-gpu-01.env` to `bootstrap/host/hosts/<short-hostname>.env` and
edit it:

```sh
PROVIDER_NAME=my-host-02          # the banlieue Provider for this host
LAB_BRIDGE=br-lab
LAB_ADDR=10.43.0.1/24             # a subnet no other host uses
LAB_CIDR=10.43.0.0/24
GUEST_MEMORY_MAX=8G               # ceiling for standalone/sandbox VMs on this host

GPU_PCI_IDS=""                    # vendor:device of every function in the GPU's IOMMU group, or empty
GPU_PCI_SLOT=""                   # e.g. 0000:01:00
IOMMU=intel                       # intel | amd

DUAL_BOOT=false
TAILSCALE_SUBNET_ROUTER=true
```

`lspci -nn -s 01:00` lists a GPU's functions and their `vendor:device` IDs.

## 2. Run the host prep

```sh
git clone https://github.com/dgunzy/homelab-k0s && cd homelab-k0s
sudo ./bootstrap/host/prepare-host.sh
```

It installs and configures, skipping whatever's already in place:

- host packages, and Ubuntu's default `sshd_config` with keys-only login;
- for GPU hosts: `vfio-pci` binding by ID (in the initramfs, ordered before the drivers that
  would otherwise claim the card), the IOMMU kernel flags, and a check that no vendor driver
  is installed on the host;
- the routed VM bridge with DHCP, DNS and NAT (systemd-networkd and systemd-resolved);
- Tailscale (optional), `k0sctl` and `kubectl`, all pinned and checksum-verified;
- banlieue's Cloud Hypervisor host install: VMM and firmware (pinned), guest uid range,
  template units and the provider service (left disabled until it has a cluster credential).

If it asks for a reboot (kernel command line or initramfs changed), reboot and run it again.
The second run changes nothing and prints the GPU functions, which must all be on `vfio-pci`.

## 3. Route the VM subnet

Other machines need a route to `LAB_CIDR`:

- a static route on the LAN router to the host's address, or
- `sudo tailscale up --advertise-routes=<LAB_CIDR> --accept-dns=false`, then approve the route
  in the Tailscale admin console.

:::caution[Don't let Tailscale take over the host's DNS]
`--accept-dns=false` matters: with MagicDNS as the host's resolver, name resolution became
intermittently flaky for the host and every VM behind it. The script enforces it.
:::

## Next

- GPU host: [prove GPU passthrough](../gpu-passthrough/) before building on it.
- First host: [bootstrap the management cluster](../management-cluster/).
- Additional host: add its `Provider` under `infrastructure/hosts/` and issue it a credential.
