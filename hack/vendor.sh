#!/usr/bin/env bash
# Vendor the raw release manifests of every cluster add-on into
# infrastructure/<component>/, and regenerate the JSON schemas CI validates
# banlieue's custom resources against (schemas/).
#
# No Helm: each project's own install manifest, committed as released, so a
# version bump is a reviewable diff and the OCI artifact Flux pulls is
# self-contained (no remote bases fetched at reconcile time).
#
#   ./hack/vendor.sh            # re-vendor everything at the pins below
#
# To upgrade: change a pin, run this, review the diff, commit.
# Idempotent: re-running at the same pins produces no diff.
set -euo pipefail

# --- Pins ---------------------------------------------------------------------
CERT_MANAGER_VERSION="v1.21.3"
CAPI_VERSION="v1.14.4"            # Cluster API core, v1beta2 contract
K0SMOTRON_VERSION="v2.3.1"        # bootstrap + control plane providers, v1beta2 contract
BANLIEUE_VERSION="v0.5.7"         # keep in step with prepare-host.sh (host binary)
# banlieue signs a checksums file per release; the others don't publish one
# for these manifests, so their review is the git diff.
BANLIEUE_COMPONENTS_SHA256="a66a933dcb0dcab040eed21e1061270f90bcaafdd7b42b811233939f99829f12"
BANLIEUE_CRDS_SHA256="6678ca2c90c4a6d6bda5dbabc7ad3a029b913a2d3b55216a9c5452d5e932157b"
BANLIEUE_ADMISSION_SHA256="277b285b7d6ddc7e60dcaf1c6841c648b73e4664a13bd0a96730d6ec0d21d947"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log() { printf '==> %s\n' "$*"; }

# fetch <url> <dest> [sha256] [filter]: download, optionally verify, optionally
# run <filter> on the raw file, and write <dest> with a provenance header.
fetch() {
  local url="$1" dest="$2" sum="${3:-}" filter="${4:-}" got
  curl -fsSL -o "$tmp/dl" "$url"
  got="$(shasum -a 256 "$tmp/dl" | awk '{print $1}')"
  if [[ -n "$sum" && "$got" != "$sum" ]]; then
    echo "checksum mismatch for $url: want $sum, got $got" >&2; exit 1
  fi
  [[ -n "$filter" ]] && "$filter" "$tmp/dl"
  mkdir -p "$(dirname "$dest")"
  { printf '# Vendored by hack/vendor.sh. Do not edit; change the pin and re-run.\n'
    printf '# Source: %s\n# sha256 (as released): %s\n' "$url" "$got"
    [[ -n "$filter" ]] && printf '# Filtered: %s\n' "$filter"
    cat "$tmp/dl"; } > "$dest"
  log "$(basename "$(dirname "$dest")")/$(basename "$dest") <- $url"
}

# drop_kinds <file> <kind>...: remove documents of the given kinds from a
# downloaded manifest, before the provenance header is added.
drop_kinds() {
  python3 -I - "$@" <<'PY'
import re, sys
path, kinds = sys.argv[1], set(sys.argv[2:])
docs = re.split(r"(?m)^---[ \t]*\n", open(path).read())
def kind(d):
    m = re.search(r"(?m)^kind:[ \t]*(\S+)[ \t]*$", d)
    return m.group(1) if m else None
keep = [d for d in docs if d.strip() and kind(d) not in kinds]
open(path, "w").write("---\n" + "---\n".join(keep))
PY
}

# Two manifests applied together that each declare the same Namespace, which
# kustomize rejects as a duplicate; the kustomization declares it once instead.
drop_namespaces() { drop_kinds "$1" Namespace; }

# MutatingAdmissionPolicy is served (admissionregistration.k8s.io/v1) only
# from Kubernetes 1.36; on 1.35 applying it fails the whole Kustomization.
# Delete this filter (and re-vendor) only AFTER `bootstrap-mgmt.sh upgrade`
# has moved the management cluster to 1.36+ (target: 1.37), not before.
drop_mutating_admission_policies() {
  drop_kinds "$1" MutatingAdmissionPolicy MutatingAdmissionPolicyBinding
}

gh_dl() { printf 'https://github.com/%s/releases/download/%s/%s' "$1" "$2" "$3"; }

fetch "$(gh_dl cert-manager/cert-manager "$CERT_MANAGER_VERSION" cert-manager.yaml)" \
  "$root/infrastructure/cert-manager/cert-manager.yaml"

fetch "$(gh_dl kubernetes-sigs/cluster-api "$CAPI_VERSION" core-components.yaml)" \
  "$root/infrastructure/cluster-api/core-components.yaml"

fetch "$(gh_dl k0sproject/k0smotron "$K0SMOTRON_VERSION" bootstrap-components.yaml)" \
  "$root/infrastructure/k0smotron/bootstrap-components.yaml" "" drop_namespaces
fetch "$(gh_dl k0sproject/k0smotron "$K0SMOTRON_VERSION" control-plane-components.yaml)" \
  "$root/infrastructure/k0smotron/control-plane-components.yaml" "" drop_namespaces

fetch "$(gh_dl firestoned/banlieue "$BANLIEUE_VERSION" infrastructure-components.yaml)" \
  "$root/infrastructure/banlieue/infrastructure-components.yaml" "$BANLIEUE_COMPONENTS_SHA256"
# ValidatingAdmissionPolicies (banlieue ADR-0007), e.g. a VirtualMachine may
# only reference user-data its creator could read itself (ADR-0042).
fetch "$(gh_dl firestoned/banlieue "$BANLIEUE_VERSION" admission-policies.yaml)" \
  "$root/infrastructure/banlieue/admission-policies.yaml" "$BANLIEUE_ADMISSION_SHA256" \
  drop_mutating_admission_policies

# banlieue isn't in the flux-schema ecosystem catalog yet: extract its CRDs'
# schemas so CI can validate Provider, VMImage, VirtualMachine, ...
log "schemas/ <- banlieue $BANLIEUE_VERSION crds.yaml"
curl -fsSL -o "$tmp/crds.yaml" "$(gh_dl firestoned/banlieue "$BANLIEUE_VERSION" crds.yaml)"
[[ "$(shasum -a 256 "$tmp/crds.yaml" | awk '{print $1}')" == "$BANLIEUE_CRDS_SHA256" ]] \
  || { echo "checksum mismatch for banlieue crds.yaml" >&2; exit 1; }
rm -rf "$root/schemas/banlieue.io" "$root/schemas/infrastructure.banlieue.io"
flux schema extract crd -d "$root/schemas" "$tmp/crds.yaml" >/dev/null

log "Done. Review with: git diff --stat infrastructure schemas"
