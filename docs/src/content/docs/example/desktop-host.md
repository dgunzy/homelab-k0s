---
title: A single desktop host
description: The deployment this runs on today, and what its constraints change (and don't).
---

The reference deployment runs on one machine: a dual-boot desktop with one consumer GPU. Every
constraint below is a property of this host, not of the architecture.

## The host

| | |
|---|---|
| CPU / RAM | 6 cores / 12 threads, 16 GB |
| GPU | One consumer GPU (Turing, 8 GB), alone in its IOMMU group |
| Network | Wi-Fi only, behind a mesh router with no static routes |
| Disk | One 240 GB SSD for Linux; Windows on its own disk |
| Availability | Dual-boot: a host only while it's in Linux |

## What the constraints change

- **Wi-Fi** → a routed VM bridge with NAT, and a Tailscale subnet route to reach it. That turned
  out to be the better default anyway: [one subnet per host](../../architecture/hosts/).
- **16 GB of RAM** → the GPU VM's memory is pinned, so it's sized carefully and the GPU pool
  scales to zero when idle; the other VMs allocate lazily. One combined workload cluster rather
  than separate inference and agent clusters.
- **Dual-boot** → nothing is lost on a reboot (VMs start with the host, Flux reconciles), but a
  long time in Windows expires the host provider's credential.
- **8 GB of Turing VRAM** → small models: roughly 7–8B parameters quantized, or ~3B in fp16.
  No bf16, and no FlashAttention 2.
- **240 GB on ext4** → VM disks are full copies of their images (no reflinks); an XFS storage
  class or a second disk fixes that.

## Memory budget

| | RAM |
|---|---|
| Host | ~2 GB |
| Management node | 4.5 GB, allocated lazily (1.8 GB used before any workload cluster) |
| GPU node | ~5.5 GB, pinned |
| CPU node | ~4 GB, allocated lazily |
| Standalone VMs | ≤ 2 GB ceiling |

## Growing it

The design doesn't change with more hardware, only the numbers:

- **More RAM** (the board takes 64 GB) → room for separate inference and agent clusters.
- **A second host** (an always-on rack server is the plan) → another `Provider`, another
  subnet, and the place for anything that must stay up while the desktop is in Windows.
- **A bigger GPU** → larger models and modern serving stacks (bf16, FlashAttention); the same
  passthrough setup with new PCI IDs in the host config.
