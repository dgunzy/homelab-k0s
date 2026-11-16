---
title: Day 2
description: Upgrading add-ons, validating changes, and keeping hosts healthy.
---

## Change anything

Edit the repository, validate locally, open a pull request. CI validates again; merging
publishes a signed artifact, and Flux applies it within a minute.

```sh
flux plugin install schema                         # once
flux schema validate --config .fluxschema.yml clusters/homelab
flux schema validate --config .fluxschema.yml infrastructure/banlieue
```

To watch a change land:

```sh
flux get kustomizations --watch
```

## Upgrade an add-on

Every add-on version is a pin in `hack/vendor.sh`.

```sh
$EDITOR hack/vendor.sh        # bump the pin
./hack/vendor.sh              # re-vendor manifests (and regenerate schemas/)
git diff --stat infrastructure schemas
```

The diff is exactly what will change in the cluster. Some versions also live outside the
vendored manifests (banlieue's host binary in `prepare-host.sh`, its bootstrap script in
`bootstrap-mgmt.sh`); keep them in step.

Flux and the Flux Operator upgrade themselves within `2.x` from their signed distribution
artifact.

## Upgrade Kubernetes

The management cluster's version is `K0S_VERSION` in `bootstrap/cluster/mgmt.env`. A running
control plane can't skip minors, so the upgrade walks `K0S_UPGRADE_PATH`, skipping steps the
cluster is already past:

```sh
sudo ./bootstrap/host/prepare-host.sh            # kubectl on the host follows the new minor
./bootstrap/cluster/bootstrap-mgmt.sh upgrade    # e.g. 1.35 → 1.36 → 1.37, waiting for Ready after each
```

Each step regenerates the k0sctl config at that version and applies it; k0sctl upgrades the
node in place. Check the add-ons' support matrices first ([Versions](../../reference/versions/)).
Changes that depend on the new version (for example admission APIs that only exist from a
given minor) land after the upgrade, not before.

## Host lifecycle

- **Re-run `prepare-host.sh` any time.** It's idempotent; a run that changes nothing is the
  health check.
- **Host reboots and shutdowns** need nothing, including a power cut. A clean shutdown (a short
  press of the power button, `poweroff`) stops each VM through its virtual ACPI button and waits
  for it, which can take a minute or two while the console looks frozen (the GPU belongs to
  VFIO). Don't hold the button. If power is lost anyway, the management node's disk is checked
  and its leaked clusters freed before the VM starts again (`bootstrap-mgmt.sh resilience`
  installs that and the next item).
- **Provider credential expired** (host off for longer than its token's remaining 12–24 h):
  `homelab-heal.service` notices on boot and issues a new one; by hand, `bootstrap-mgmt.sh provider`.
- **Restarting the host provider** doesn't touch running VMs; they're their own systemd units.

## Useful queries

```sh
kubectl -n banlieue-system get providers.banlieue.io          # hosts, heartbeat, readiness
kubectl get vmimages,vmclasses                                  # catalog
kubectl -n banlieue-system get vm,cloudhypervisormachines -o wide
kubectl -n flux-system get ocirepositories                      # signature verification
```
