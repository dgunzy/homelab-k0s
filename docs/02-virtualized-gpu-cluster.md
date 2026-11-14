# 02: A virtualized GPU cluster on one desktop

## Goal

Run the cluster as **VMs on a hypervisor host** instead of one bare-metal k0s
node, the way managed GPU clouds do: GPU worker nodes are VMs with the GPU
passed through, provisioned and replaced through an API (Cluster API), with
the control plane hosted elsewhere. Then practise the jobs that run on top of
that: node images, nodepool upgrades, GPU health and remediation, and GPU
scheduling.

The building blocks are [banlieue](https://github.com/firestoned/banlieue)
(Kubernetes-native VMs on Cloud Hypervisor, and a Cluster API infrastructure
provider) and, later, [bindy](https://github.com/firestoned/bindy) for DNS.

## Architecture

```
k0s-gpu-01 (bare metal Ubuntu 24.04, i7-8700 6c/12t, 16 GB, Wi-Fi only)
│  KVM + Cloud Hypervisor, no k0s, no NVIDIA driver
│  RTX 2070 bound to vfio-pci at boot
│  banlieue CH provider (systemd; a Provider in the mgmt cluster)
│  br-lab 10.42.0.1/24: DHCP + DNS + NAT out of wlo1; tailscale subnet route
│
├── mgmt-01   VM  2 vCPU / 4.5 GB   tiny management cluster (k0s 1.35, built by bootstrap-mgmt.sh)
│                                   Flux, Cluster API, k0smotron, banlieue
│                                   └── control plane of the "workload" cluster runs here as pods
│
│   "workload" cluster: k0smotron-hosted control plane (k0s 1.36+), workers from
│   Cluster API MachineDeployments backed by banlieue CloudHypervisorMachines
├── gpu-01    VM  4 vCPU / ~5.5 GB  node pool "gpu": RTX 2070 via VFIO, tainted for GPU work
│                                   NVIDIA R580, GPU Operator, inference server
└── cpu-01    VM  2 vCPU / ~4 GB    node pool "cpu": Agent Substrate (gVisor actors),
                                    its Postgres + object store, cluster add-ons
```

Two clusters, on purpose: a tiny management cluster that only provisions
and reconciles, and one child cluster that does all the work, inference and
agents side by side in separate node pools. Agents reach the inference
server through Substrate's egress gateway (credentials and policy stay
outside the sandbox). Only gpu-01's RAM is pinned; the other VMs allocate
lazily, which is what makes this fit in 16 GB. The RAM upgrade (below) buys
headroom, not a different design.

## Decisions and why

### Nodes are Cloud Hypervisor VMs, through banlieue

Cloud Hypervisor (CH) is a small Rust VMM: one process per VM, run by systemd,
no daemon. banlieue drives it from Kubernetes: `VirtualMachine`,
`VirtualMachinePool` (warm VMs) and `VirtualMachineClaim`, and its
`CloudHypervisorMachine` satisfies the Cluster API InfraMachine contract, so
CAPI `MachineDeployment`s can create real VMs on this host.

The **management cluster's own node can't be a banlieue VM**: banlieue needs
the cluster to create a VM, and after a host reboot the cluster is down
until its node is up. banlieue's `scripts/bootstrap-k0s-cluster.sh` handles
this (its ADR-0099): each management node is three plain systemd units (tap,
vTPM, VMM) that start at boot without Kubernetes, and k0sctl installs k0s.
Everything after that is declarative.

### The GPU goes to one VM whole; sharing happens in Kubernetes

There is no way to split this card between VMs that's worth using:

| Option | Why not |
|---|---|
| vGPU (mediated devices) | Needs NVIDIA's licensed vGPU host driver and a datacenter card. GeForce hacks (vgpu_unlock) only work on old driver branches. |
| MIG | Ampere-and-newer datacenter GPUs only. |
| SR-IOV | Not on this card. |

So the GPU is **passed through whole** to one worker VM, which is also how
cloud GPU instances work. Sharing happens inside Kubernetes: GPU Operator
time-slicing (or MPS), then DRA. Moving the GPU *between* VMs (CH hot-unplug
and hotplug, `ch-remote remove-device` / `add-device`) is a later experiment.

**GPU concepts used here:**

- **IOMMU (Intel VT-d).** A device does DMA straight into RAM. The IOMMU
  translates device addresses the way the MMU does for CPUs, so a
  passed-through GPU can only reach its own VM's memory. Without it,
  passthrough would hand the VM all of host memory.
- **IOMMU groups.** The smallest set of devices the IOMMU can isolate from
  each other. Everything in a group goes to the same owner. On this board
  group 1 is the CPU's x16 root port plus the GPU's four functions, nothing
  else: the ideal case. (Cards in chipset slots often share a group with
  SATA or USB, which makes passthrough impractical without ACS hacks.)
- **Four functions, one card.** Turing GeForce cards expose VGA (`01:00.0`),
  HDMI audio (`.1`), a USB-C xHCI controller (`.2`) and a USB-C UCSI
  controller (`.3`). All four must leave their host drivers
  (`nouveau`, `snd_hda_intel`, `xhci_pci`, `i2c_nvidia_gpu`) and sit on
  `vfio-pci`. Only `.0` needs to go to the VM.
- **VFIO** is the kernel framework that gives a userspace process (the VMM)
  safe access to a device: config space, BARs (the device's memory windows)
  and interrupts, all behind the IOMMU.
- **Guest memory is pinned.** The GPU can DMA anywhere in the guest's RAM at
  any time, so all of it is locked into host RAM at boot: no ballooning, no
  overcommit, no swap. A 7 GB GPU VM costs 7 GB, always. The VMM needs
  `LimitMEMLOCK=infinity` (or root).
- **Boot VGA.** The 2070 is the only display device (`boot_vga=1`; the
  i7's iGPU is hidden while a card is installed). Firmware draws GRUB on
  it, then vfio-pci takes it and the host goes headless. Recent kernels make
  vfio-pci evict the firmware framebuffer by themselves. If the guest
  ever fails with `BAR 1: can't reserve`, add `initcall_blacklist=sysfb_init`
  to the host's kernel command line.
- **Reset.** A VM restart must reset the GPU. This card advertises Function
  Level Reset (`DevCap: FLReset+` in `lspci -vv`), which VFIO uses; the
  fallback would be a secondary bus reset on the root port, which also works
  here because the card is alone behind it.
- **BARs.** The VGA function exposes 16 MB of registers (BAR0), a 256 MB
  window into VRAM (BAR1) and 32 MB more (BAR3). The VMM maps them into the
  guest's physical address space. Datacenter cards with Resizable BAR expose
  all of VRAM at once, which is why some VMMs need a large 64-bit MMIO window.

### The host runs no NVIDIA driver

The driver moves into the GPU VM (`bootstrap/node/prepare-gpu-node.sh`:
R580 `server-open`, apt-held, same pin as before). The host's job is only to
keep the card away from every driver except vfio-pci. Windows is unaffected:
VFIO only exists under Linux.

### A routed VM network, because the uplink is Wi-Fi

A Wi-Fi client can't be a bridge port: the access point only accepts frames
from MACs that associated with it, so VMs can't share the home LAN directly.
The host routes instead:

- `br-lab` (systemd-networkd) holds `10.42.0.1/24`, hands out DHCP
  (`.100–.199`), and masquerades VM traffic out of `wlo1`.
- systemd-resolved listens on `10.42.0.1`, so VMs use whatever DNS the Wi-Fi
  hands the host.
- k0s nodes need **stable** addresses: they get fixed MACs and static
  addresses below `.100` (the smoke VM uses `.10`).
- To reach VMs from the MacBook, the home router (a mesh behind the ISP
  router) can't hold a static route, so the host is a **Tailscale subnet
  router** for `10.42.0.0/24`. That also works away from home.

### A hosted control plane (phase 2)

The `workload` cluster's control plane runs as pods in the management cluster
(k0smotron), not on controller VMs. That saves a VM's RAM, and it's the
hosted control-plane model managed Kubernetes services use. Workers come
from CAPI `MachineDeployment`s (one per node pool: `gpu`, `cpu`) backed by
banlieue `CloudHypervisorMachine`s.

Its Kubernetes version and API feature gates are set in its own
`K0smotronControlPlane`, independent of mgmt. Agent Substrate needs 1.36+
plus `ClusterTrustBundle`, `ClusterTrustBundleProjection`,
`PodCertificateRequest` and `certificates.k8s.io/v1beta1`; mgmt can stay on
1.35 and is upgraded on its own schedule.

### Memory budget (16 GB)

| | RAM | Notes |
|---|---|---|
| host | ~2 GB | systemd, provider, tailscale, page cache |
| mgmt-01 | 4.5 GB (lazy) | mgmt k0s + workload control plane pods + Flux/CAPI/banlieue (measured 1.8 GB used before the child cluster) |
| gpu-01 | ~5.5 GB (pinned) | VFIO pins all of it. llama.cpp with every layer offloaded keeps the model in VRAM; host RAM is only for loading |
| cpu-01 | ~4 GB (lazy) | Substrate control plane, 1–2 gVisor workers with 256–512 MB actors, Postgres, object store |
| banlieue guests | ≤2 GB | `banlieue-guests.slice` ceiling, `--guest-memory-max 2G`; test VMs only |

Ways to stay inside it: monitoring as DCGM exporter + a single-binary
metrics store rather than kube-prometheus-stack; Substrate without its
OTel collector at first; scale the `gpu` MachineDeployment to 0 when not
doing inference (scale-to-zero GPU pools are a normal cost control).

**RAM upgrade.** Current: 2× 8 GB DDR4-2666 in `ChannelA-DIMM2` and
`ChannelB-DIMM2`; `DIMM1` in both channels is empty. Adding a matched
2× 16 GB pair gives 48 GB in symmetric dual channel (24 GB per channel).
The board takes up to 64 GB. Search for
`16GB PC4-2666V-U` / `2Rx8 PC4-2666 UDIMM` (used) or a `2x16GB DDR4-3200`
desktop kit (runs at 2666 on this CPU). Avoid `RDIMM`, `ECC Registered`,
`-R` part numbers and `SODIMM`.

### Bindy waits

Nodes and k0s use IPs, never DNS, so nothing during bring-up needs it. bindy
becomes useful once there are LoadBalancer Services and Gateway routes to
name: authoritative for something like `lab.home.arpa`, with Scout writing
records for them. Clients resolve it through `/etc/resolver/lab.home.arpa`
on macOS, or through the host's resolved.

### A second host later (R610)

The R610 becomes a second CH host and a second banlieue `Provider` (its own
failure domain) for CPU-only VMs. It's always on and this desktop dual-boots,
so if a multi-node control plane ever exists, its controllers go on the R610.
Its DDR3 RDIMMs are the cheapest RAM in the lab.

## Host facts (verified 2026-11-14)

```
IOMMU group 1:
  00:01.0 PCIe Controller (x16) [8086:1901]          root port, stays on the host
  01:00.0 TU106 [GeForce RTX 2070] [10de:1f02]       -> VM
  01:00.1 TU106 HD Audio [10de:10f9]                 vfio-pci, unused
  01:00.2 TU106 USB 3.1 xHCI [10de:1ada]             vfio-pci, unused
  01:00.3 TU106 USB-C UCSI [10de:1adb]               vfio-pci, unused
```

VT-x and VT-d are enabled in the BIOS. The kernel enables DMA remapping by
default. cgroup v2, systemd 255.

**Phase 1 passed (2026-11-14).** After `prepare-host.sh` and a reboot, all
four functions were on `vfio-pci`. `gpu-smoke-vm.sh up` booted a Cloud
Hypervisor v53.0 guest with `01:00.0` passed through (the guest sees it at
`00:05.0`), and `verify` installed R580 and ran `nvidia-smi`: RTX 2070,
driver 580.178.04, CUDA 13.0, 8192 MiB. A full guest power-off and boot
brought the GPU back with no VFIO reset errors on the host, so FLR works.
Host RAM in use rose by the guest's 6 GB, as pinning predicts.

Two things learned on the way:

- **Ubuntu's AppArmor profile for `swtpm`** only allows libvirt's paths, so
  `banlieue host cloud-hypervisor install` failed at its EK CA stage
  (`apparmor="DENIED" operation="mknod" profile="swtpm"`). `prepare-host.sh`
  now extends the profile via `/etc/apparmor.d/local/usr.bin.swtpm` (the
  hook the packaged profile includes for local rules). banlieue is tested on
  Debian 13, which doesn't hit this; worth reporting upstream.
- **The guest's driver install upgraded its kernel** (6.8.0-147 → 149),
  because `linux-modules-nvidia-580-server-open-generic` follows the
  newest `-generic` kernel. Harmless here, but it's why node images should
  pin the kernel and driver together and be tested as a pair (phase 4).

## Phases

Each phase has an exit check. Don't start the next phase until it passes.

1. **Hypervisor host and GPU passthrough.** `prepare-host.sh`, reboot,
   re-run it (all four functions on `vfio-pci`), then
   `gpu-smoke-vm.sh up && gpu-smoke-vm.sh verify`.
   *Exit:* `nvidia-smi` inside the smoke VM shows the RTX 2070.
2. **Management cluster.** mgmt-01 via banlieue's bootstrap script (pinned
   to the release tag), Flux Operator (`FluxInstance`), then banlieue,
   Cluster API and k0smotron as Flux-managed add-ons. Connect this host's
   provider (`banlieue bootstrap cloud-hypervisor-host`).
   *Exit:* the host's `Provider` reports capacity, and a test `VirtualMachine` boots.
   *Progress (2026-11-14):* `bootstrap-mgmt.sh node` built mgmt-01 (CH VM,
   Ubuntu 24.04, 10.42.0.11) and k0s v1.35.10 came up Ready in about a
   minute of k0sctl time. The GitOps side is in [docs/03](03-gitops.md).
   Lesson: Tailscale's MagicDNS (`accept-dns`, on by default) became the
   host's default DNS route and broke name resolution intermittently, for the
   VMs too; a subnet-router host runs with `--accept-dns=false`.
   `bootstrap-mgmt.sh flux` then brought up Flux v2.10.0 and all add-ons
   (cert-manager, Cluster API, k0smotron, banlieue) in ~90 s, with cosign
   verification on both OCI sources. `provider` connected this host:
   `Provider/k0s-gpu-01` Ready, heartbeat Alive, reporting 12 CPUs,
   15909 MiB, Cloud Hypervisor v53.0. Still open for the exit check: a test
   `VirtualMachine`.
   Two gotchas: `kubectl get provider` resolves to Cluster API's clusterctl
   inventory kind (`providers.clusterctl.cluster.x-k8s.io`), so banlieue's
   must be `providers.banlieue.io`; and the provider reports
   `storageWithoutReflink: default`: the root LV is ext4, so each VM disk is
   a full copy of its image instead of a copy-on-write clone (banlieue ships
   `scripts/ch-storage-to-xfs.sh` for an XFS storage class).
3. **The workload cluster.** A k0smotron-hosted control plane (k0s 1.36+
   with Substrate's feature gates) and a `cpu` MachineDeployment of one
   (cpu-01) through banlieue. Then the `gpu` pool: needs GPU passthrough in
   banlieue (see "Gaps" below); gpu-01 becomes a `MachineDeployment` of one.
   GPU Operator with `driver.enabled=false` first, then try its
   containerized driver.
   *Exit:* the CUDA sample pod passes on a node CAPI created, and deleting
   the Machine brings back a working replacement.
4. **Node image pipeline.** A GPU node image with the driver baked in
   (Kairos, or a cloud image), signed (cosign), SBOM, CVE gate, and a
   rolling image upgrade of the MachineDeployment.
5. **Health and remediation.** DCGM exporter, Prometheus/Grafana, NVSentinel
   or a homegrown controller, MachineHealthCheck. Fault injection is the
   advantage of VMs: hot-unplug the GPU, kill the VMM, fill the disk, and
   watch detection → cordon → drain → replace.
6. **Scheduling.** Time-slicing vs MPS, Kueue and KAI Scheduler, DRA,
   Slurm on Kubernetes (Slinky).
7. **Workloads.** Inference on the `gpu` pool (llama.cpp first, then vLLM;
   Turing: fp16/quantized, no FlashAttention 2) and Agent Substrate on the
   `cpu` pool in gVisor mode (its `microvm` class needs `/dev/kvm`, i.e.
   nested virtualization, which these VMs don't have; Substrate can't hand
   GPUs to actors yet anyway). Agents call inference through Substrate's
   egress gateway. Optionally compare with banlieue `VirtualMachinePool`
   sandboxes (a full VM per agent).

## Gaps in banlieue (upstream contributions)

Found by reading banlieue v0.5.7. These are what stand between phase 1 and
phase 3:

1. **No PCI/GPU passthrough.** `gpuPassthrough` is only an advisory string in
   `ProviderCapabilities.features`. Needed: a device request on
   `VMClass`/`CloudHypervisorMachine`, host-side device inventory and
   capacity on the Provider, `--device` in the VMM command line, and in the
   guest unit `DeviceAllow=/dev/vfio/*` plus `LimitMEMLOCK=infinity`
   (today's units are `DevicePolicy=closed` with only `/dev/kvm` and
   `/dev/net/tun`).
2. **Bootstrap script: one size for all nodes.** `VCPUS`/`MEM_MB`/`DISK_GB`
   are global. Per-node lists (like `NODE_ROLES`) would be needed if a GPU
   node were ever built by the script.
3. **Bootstrap script: `cloud` images default to `.../latest/`.** Override
   `CLOUD_IMAGE_URL` with a dated image and pin its checksum.
4. **Ubuntu hosts: AppArmor confines `swtpm`** to libvirt's paths. The host
   install could detect it (its preflight already checks commands) or ship
   the local rule. Worked around in `prepare-host.sh`.

## Known risks

- **Provider token vs. dual-boot.** The host's provider renews its
  ServiceAccount token at half its lifetime (24 h by default). After longer
  than one lifetime in Windows, it comes back with an expired token and needs
  `banlieue bootstrap cloud-hypervisor-host` again. Issue a longer-lived
  token, or treat re-issuing as a runbook step.
- **vTPM.** CH's vTPM needs an upstream fix (cloud-hypervisor#9053) that
  isn't released. Build nodes with `CH_TPM=false`; nothing here needs a vTPM yet.
- **Consumer GPU under CH.** CH's VFIO support is mostly exercised with
  datacenter GPUs. If the smoke test fails in ways that look VMM-specific,
  fall back to QEMU for the GPU node only (the bootstrap script can mix
  VMMs per node).
- **Wi-Fi bandwidth.** ~70 Mbps. Cloud images and the driver download are
  cached on the host. Keep CUDA images on a node-local cache; don't re-pull.
- **Disk.** VM disks and container images share the 240 GB SSD.

## Troubleshooting passthrough

| Symptom | Check |
|---|---|
| `banlieue host … install` fails at "EK CA" with swtpm exit 256 | AppArmor: `journalctl -k \| grep DENIED.*swtpm`; the local rule in `/etc/apparmor.d/local/usr.bin.swtpm` must be loaded (`apparmor_parser -r /etc/apparmor.d/usr.bin.swtpm`) |
| A GPU function isn't on `vfio-pci` after reboot | `lspci -nnk -s 01:00`; `cat /etc/modprobe.d/vfio.conf`; `lsinitramfs /boot/initrd.img-$(uname -r) \| grep vfio` |
| VMM: "group … is not viable" | Another device in group 1 still has a host driver (`gpu-smoke-vm.sh` names it) |
| Guest: `BAR 1: can't reserve` / no `nvidia-smi` | Add `initcall_blacklist=sysfb_init` to the host cmdline (see Boot VGA above) |
| VMM fails to start, "Cannot allocate memory" | Not enough free host RAM to pin the guest; stop other VMs |
| `nvidia-smi` fails after a VM restart | The GPU didn't reset. Reboot the host and check `dmesg \| grep -i vfio` |
