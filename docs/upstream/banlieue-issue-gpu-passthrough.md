# DRAFT GitHub issue for firestoned/banlieue

(banlieue is ADR-first: this is meant as input for an ADR, not a PR. No real
hostnames or addresses below, per the repo's no-real-infrastructure rule.)

---

## Title

Feature: PCI / GPU passthrough (VFIO) for Cloud Hypervisor guests

## Summary

Let a `VirtualMachine` (and a Cluster API `CloudHypervisorMachine`) ask for a
host PCI device, typically a GPU, passed through with VFIO. Today
`gpuPassthrough` exists only as an advisory string in
`ProviderCapabilities.features`; nothing in the API, the provider or the
guest units can attach a device.

## Motivation

- **GPU worker nodes as VMs.** This is how GPU clouds run Kubernetes GPU
  nodes: the hypervisor passes the whole GPU through, the guest runs the
  vendor driver, and Kubernetes (GPU Operator, device plugin, DRA) shares it
  from there. With banlieue's CAPI InfraMachine contract, a
  `MachineDeployment` of GPU workers on Cloud Hypervisor hosts becomes
  possible: nodepool upgrades, MachineHealthCheck replacement, and so on.
- **Fault injection.** Detaching or reattaching a device from a running guest
  (`ch-remote remove-device` / `add-device`) is a cheap way to test GPU
  health detection and remediation, which bare metal doesn't allow.
- Cloud Hypervisor already supports VFIO (`--device path=...`, hotplug), so
  most of the work is in banlieue: declaring devices, scheduling, sandboxing.

## Evidence it works with the VMM banlieue pins (v53.0)

Outside banlieue, as a smoke test (VMM run as root, unsandboxed), on an
Ubuntu 24.04 host with a consumer GPU (NVIDIA RTX 2070, Turing):

1. VT-d on; the GPU's IOMMU group holds only its four functions (VGA, HDMI
   audio, USB-C xHCI, USB-C UCSI) plus the CPU's root port.
2. All four functions bound to `vfio-pci` at boot (`vfio-pci.ids=` in
   modprobe.d, softdeps ahead of `nouveau`, `snd_hda_intel`, `xhci_pci`,
   `i2c_nvidia_gpu`, vfio modules in the initramfs, `intel_iommu=on iommu=pt`).
3. `cloud-hypervisor --firmware CLOUDHV.fd ... --device path=/sys/bus/pci/devices/0000:01:00.0/`
   with an Ubuntu 24.04 cloud image. Only the VGA function was attached;
   the others stay parked on vfio-pci.
4. The guest sees the GPU at `00:05.0`. NVIDIA R580 open kernel modules
   install, and `nvidia-smi` reports the card and 8 GiB.
5. A full guest power-off and boot brings the GPU back with no VFIO reset
   errors (the card advertises FLR).
6. Host memory in use rose by the guest's full size at boot: VFIO pins all
   guest RAM.

## Current state in banlieue (v0.5.7 / main)

- API: no device request on `VMClass`, `VirtualMachine` or
  `CloudHypervisorMachine(Template)`.
- Provider: no device inventory; `features: [gpuPassthrough]` isn't verified
  or acted on.
- Guest units (`banlieue-ch@`, and the bootstrap script's `k0s-vm-*`):
  `DevicePolicy=closed` with only `/dev/kvm` and `/dev/net/tun`, and no
  `LimitMEMLOCK`, so a sandboxed VMM can't open `/dev/vfio/*` or pin memory.

## Design sketch (input for an ADR)

Following ADR-0062 Decision 4's pattern (the host declares classes, machines
name a class, a stolen credential can only choose among what the host
declared):

- **Host config.** `banlieue host cloud-hypervisor install --device-class gpu=0000:01:00.0[,...]`
  writes `[device_classes]` to `cloud-hypervisor.toml`. Preflight and
  selftest check that the IOMMU is on, each device is on `vfio-pci`, its
  group is viable (every endpoint on vfio-pci, bridges aside), and
  `/dev/vfio/<group>` exists.
- **Provider status.** Each failure domain publishes per-class device count,
  free count and identity (vendor:device), alongside today's
  `cpus`/`memoryMiB` attributes.
- **API.** `VMClass.spec.hardware.devices: [{name: gpu0, deviceClass: gpu}]`,
  mirrored on `CloudHypervisorMachine(Template)`. The `Provider` capability
  becomes a verified, per-class mapping, like storage and network classes.
- **Scheduling (ADR-0107).** Devices are exclusive integer resources. A guest
  with any VFIO device has its whole memory pinned, so it counts at 100%
  against capacity with no overcommit.
- **Guest unit.** For a guest with devices, the provider (as it does for taps)
  makes `/dev/vfio/<group>` accessible to that guest's uid only, adds
  `DeviceAllow=/dev/vfio/vfio rw` and `DeviceAllow=/dev/vfio/<group> rw`,
  `LimitMEMLOCK=` of at least guest memory, and Landlock rules for the
  device's sysfs path and `/dev/vfio`.
- **Lifecycle.** Assignment recorded in status and released on delete; one
  device per guest at a time. `VirtualMachineMove` (ADR-0127) refuses guests
  with devices, or requires a free device of the same class on the target.
- **Bootstrap script (optional, separate).** `NODE_DEVICES` (and per-node
  `NODE_VCPUS` / `NODE_MEM_MB`) so a GPU node of the management cluster can
  be built the same way.

## Threat model notes

- DMA is confined by the IOMMU, so a non-viable group must be refused, not
  warned about.
- Device state can outlive a guest: FLR doesn't guarantee GPU memory is
  cleared. Sandboxes reusing a device need a scrub policy (or a documented
  "not for mutually distrusting tenants").
- The guest uid gains exactly one `/dev/vfio/<group>`; the host must not load
  the vendor driver for declared devices (preflight).
- Option ROMs and firmware come from the device itself.

## Open questions

- Identify devices by PCI address (stable per host, simplest) or by
  vendor:device selector?
- Multi-function devices: attach only the primary function (what worked
  above) or the whole group?
- NUMA and hugepages for large GPUs; 64-bit MMIO window sizing for
  Resizable-BAR cards.
- Later: SR-IOV VFs and mediated devices (vGPU) fit the same `deviceClass`
  shape with VF/mdev addresses.

## Offer

Happy to help with the ADR draft and to test on real hardware (single
consumer GPU, Turing, its own IOMMU group, Cloud Hypervisor v53.0).
