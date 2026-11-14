# 03: GitOps for the management cluster

## Goal

After the first node exists, every change to the cluster goes through this
repo: validated in CI, published as a signed OCI artifact, pulled and applied
by Flux. Nothing is `kubectl apply`'d by hand except the two objects that
start Flux itself.

## Flow

```
PR ──> validate.yaml ──> merge ──> validate.yaml (main) ──> publish.yaml
        flux schema                                          flux push artifact :<sha>
        shellcheck                                           cosign sign (keyless, GitHub OIDC)
                                                             flux tag artifact :latest
                                                                   │
cluster: FluxInstance ─ OCIRepository ghcr.io/dgunzy/homelab-k0s-manifests:latest
                         (verify: only publish.yaml on main) ─ Kustomization clusters/homelab
```

## Layout

```
clusters/homelab/            what the FluxInstance syncs (spec.sync.path)
  flux-system/
    flux-instance.yaml       Flux itself: version 2.x, components, sync source
    flux-operator.yaml       the operator updating itself (OCIRepository + Kustomization)
  infrastructure.yaml        one Flux Kustomization per add-on, with dependsOn
infrastructure/              vendored release manifests, one directory per add-on
  cert-manager/  cluster-api/  k0smotron/  banlieue/
  hosts/                     one banlieue Provider per hypervisor host
hack/vendor.sh               pins + re-vendoring of everything in infrastructure/
schemas/                     JSON schemas for CRDs not in the schema catalog (banlieue)
.fluxschema.yml              validation config shared by CI and local runs
```

## Decisions and why

**Flux Operator, not `flux bootstrap`.** The `FluxInstance` is a normal
resource in this repo, reconciled like everything else, so Flux's own
configuration is declarative and reviewable. `flux bootstrap` writes generated
manifests into the repo and needs a deploy key.

**Flux follows the latest 2.x by itself.** `distribution.version: "2.x"` plus
`reconcileArtifactEvery: 10m`: the operator watches its signed distribution
artifact and upgrades Flux when a new release appears. The operator updates
itself the same way (`flux-system/flux-operator.yaml`, `prune: false` so a
bad artifact can't delete it). This is a test cluster; staying current is the
point. Everything else is pinned.

**Gitless: the cluster pulls an OCI artifact, not git.** CI pushes the repo's
manifests to GHCR as an OCI artifact tagged with the commit and `latest`.
Reasons: no git credentials on the cluster, registry pulls are cheap, and
the artifact can be signed. Only commits that passed validation are published
(`publish.yaml` runs on `validate`'s success, at that commit).

**Signed, and verified on pull.** CI signs each artifact's digest with cosign
*keyless*: the signing certificate is issued for the GitHub Actions OIDC
identity of `publish.yaml` on `main`, so there's no key to manage. The
`FluxInstance` patches its sync `OCIRepository` with `spec.verify`, so an
artifact pushed by anything else (a leaked token, a laptop) is refused. The
digest is signed before it's tagged `latest`, so the cluster never sees an
unsigned `latest`.

**No Helm: raw release manifests, vendored.** Each add-on is applied from the
manifest its project publishes per release (`cert-manager.yaml`,
`core-components.yaml`, ...). `hack/vendor.sh` downloads them at pinned
versions (verifying checksums where the project publishes them) and stamps
each with its source. That means:

- a version bump is a reviewable diff of exactly what will be applied;
- the OCI artifact is self-contained: no remote bases or chart repositories
  fetched at reconcile time;
- no helm-controller in the cluster.

**No Cluster API Operator, no clusterctl.** CAPI core, k0smotron and banlieue
all publish clusterctl "components" files. clusterctl's job is mostly to
substitute `${VAR:=default}` placeholders and apply them; Flux's `postBuild`
substitution does the same (it uses the same envsubst semantics), so Flux
applies the components directly. banlieue is the exception: its manifest
contains literal `${FQDN}` templates, so its Kustomization has no `postBuild`.

**One Kustomization per add-on, ordered with `dependsOn` + `wait`.**
`wait: true` makes each one Ready only when what it applied is healthy, so
`cluster-api` really starts after cert-manager is serving. Order:
cert-manager → cluster-api → k0smotron, banlieue → hosts.

**Validation: flux-schema.** Every directory with a `kustomization.yaml` is
built the way kustomize-controller builds it, and every resource is checked
against its JSON schema *and* its CEL rules, offline from the API server.
Schemas come from the plugin's built-in catalog (Kubernetes, Flux), the
ecosystem catalog at schemas.fluxoperator.dev (cert-manager, Cluster API,
k0smotron, Flux Operator, GPU Operator), and `schemas/` for banlieue, which
isn't in the catalog yet (request it in `controlplaneio-fluxcd/schema-catalog`;
once it's there, drop `schemas/` and the extract step).

Locally:

```bash
flux plugin install schema
flux schema validate --config .fluxschema.yml clusters/homelab
flux schema validate --config .fluxschema.yml infrastructure/banlieue
```

## One-time setup

1. Push to `main`; `publish` creates the package
   `ghcr.io/dgunzy/homelab-k0s-manifests`.
2. Make it public: GitHub → Packages → homelab-k0s-manifests → Package
   settings → Change visibility → Public. (Or keep it private and give the
   FluxInstance a `sync.pullSecret`.)
3. On the host: `./bootstrap/cluster/bootstrap-mgmt.sh flux`.

## Upgrading an add-on

```bash
$EDITOR hack/vendor.sh        # change the pin
./hack/vendor.sh              # re-vendor (and re-extract banlieue schemas)
git diff --stat infrastructure schemas
```

banlieue's pin also lives in `bootstrap/host/prepare-host.sh` (the host
binary and VMM) and `bootstrap/cluster/bootstrap-mgmt.sh` (its bootstrap
script); keep the three in step.

## Things to revisit

- SOPS + age for secrets, once there are any.
- Notifications (notification-controller is installed, nothing is wired).
- The child cluster (k0smotron-hosted `workload`) gets its own
  `clusters/<name>/` path in the same artifact.
