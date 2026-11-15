---
title: Prove GPU passthrough
description: Boot a throwaway VM with the GPU passed through and run the vendor's tools in it, before anything depends on it.
---

Passthrough has enough moving parts (firmware, IOMMU groups, driver binding, the VMM, the guest
driver) that it's worth proving in isolation. `bootstrap/host/gpu-smoke-vm.sh` boots one plain
Cloud Hypervisor VM with the host's GPU, outside the platform, so a failure is about
passthrough and nothing else.

```sh
sudo ./bootstrap/host/gpu-smoke-vm.sh up       # Ubuntu cloud image, GPU attached, static address .10
sudo ./bootstrap/host/gpu-smoke-vm.sh verify   # installs the pinned driver in the guest, runs nvidia-smi
sudo ./bootstrap/host/gpu-smoke-vm.sh down     # stop it, keep its disk
sudo ./bootstrap/host/gpu-smoke-vm.sh destroy  # stop it and delete its disk
```

It reads the GPU slot and bridge from the [host config](../prepare-a-host/), checks that every
device in the GPU's IOMMU group is on `vfio-pci`, downloads and checksum-verifies a pinned
Ubuntu cloud image (cached for next time), and seeds the guest with your SSH keys.

**Exit check:** `nvidia-smi` in the guest shows the card. Then run `down` and `up` once more:
the GPU must come back after a full guest power-off, which proves the device resets cleanly.

## Troubleshooting

| Symptom | Check |
|---|---|
| A GPU function isn't on `vfio-pci` after a reboot | `lspci -nnk -s <slot>`; `cat /etc/modprobe.d/vfio.conf`; `lsinitramfs /boot/initrd.img-$(uname -r) \| grep vfio` |
| VMM: "group … is not viable" | Another device in the GPU's IOMMU group still has a host driver; the script names it |
| Guest: `BAR 1: can't reserve`, or no `nvidia-smi` | The firmware framebuffer still holds the card. Add `initcall_blacklist=sysfb_init` to the host's kernel command line |
| VMM fails with "Cannot allocate memory" | The guest's RAM is pinned in full; free host memory or stop other VMs |
| GPU missing after a guest restart | The device didn't reset. Check `dmesg \| grep -i vfio`; reboot the host |
| `banlieue host … install` fails at "EK CA" with swtpm exit 256 | AppArmor confines `swtpm` on Ubuntu; `prepare-host.sh` adds the local rule. Check `journalctl -k \| grep DENIED.*swtpm` |

## Notes

- The guest's driver install may upgrade the guest kernel along with the prebuilt module. Fine
  for a smoke test; for nodes, pin kernel and driver together in the node image.
- The script runs the VMM as root and unsandboxed to keep the test simple. Platform VMs run as
  unprivileged per-guest uids; GPU node VMs additionally need `/dev/vfio/*` access and an
  unlimited memory lock.
