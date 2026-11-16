#!/usr/bin/env bash
# Bring up the management cluster on this host, then hand it to Flux.
# Run on k0s-gpu-01 as ops (not root; it uses sudo where needed), from the repo:
#
#   ./bootstrap/cluster/bootstrap-mgmt.sh node      # mgmt-01 VM + k0s (banlieue's bootstrap script)
#   ./bootstrap/cluster/bootstrap-mgmt.sh flux      # Flux Operator + this repo's FluxInstance
#   ./bootstrap/cluster/bootstrap-mgmt.sh provider  # connect this host's banlieue provider to the cluster
#   ./bootstrap/cluster/bootstrap-mgmt.sh all       # the three above, in order
#   ./bootstrap/cluster/bootstrap-mgmt.sh resilience # recover on boot after any shutdown (node runs it too)
#   ./bootstrap/cluster/bootstrap-mgmt.sh heal      # on boot: new provider credential if it expired
#   ./bootstrap/cluster/bootstrap-mgmt.sh upgrade   # step a running cluster to K0S_VERSION, one minor at a time
#   ./bootstrap/cluster/bootstrap-mgmt.sh status
#   ./bootstrap/cluster/bootstrap-mgmt.sh destroy   # delete mgmt-01 and its disk (asks first)
#
# `flux` needs the OCI artifact to exist and be public: push to main first
# (.github/workflows/publish.yaml) and make the GHCR package public once.
# Idempotent: every step can be re-run.
set -euo pipefail

# --- Pins ---------------------------------------------------------------------
# banlieue's k0s bootstrap script at the release prepare-host.sh installs.
BANLIEUE_VERSION="0.5.8"
BANLIEUE_SCRIPT_SHA256="b23a99686a35be5e31b9cc17df38d361445c90fe91b303cdfc9a330079705adf"
# Flux Operator: deliberately the latest release (test cluster; Flux keeps it
# current afterwards from the signed distribution artifact).
FLUX_OPERATOR_INSTALL="https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml"
PROVIDER_NAME="k0s-gpu-01"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$repo/bootstrap/cluster/mgmt.env"
# shellcheck source=mgmt.env
source "$ENV_FILE"
KUBECONFIG_PATH="$HOME/.kube/$CLUSTER_NAME.kubeconfig"
export KUBECONFIG="$KUBECONFIG_PATH"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as ops, not root (the script uses sudo itself)"
sudo -n true 2>/dev/null || die "needs passwordless sudo"

banlieue_script() {
  local s="$HOME/.cache/homelab/bootstrap-k0s-cluster-v$BANLIEUE_VERSION.sh"
  if [[ ! -f "$s" ]]; then
    mkdir -p "$(dirname "$s")"
    curl -fsSLo "$s.tmp" \
      "https://raw.githubusercontent.com/firestoned/banlieue/v$BANLIEUE_VERSION/scripts/bootstrap-k0s-cluster.sh" \
      || die "could not download banlieue's bootstrap script"
    mv "$s.tmp" "$s"
  fi
  echo "$BANLIEUE_SCRIPT_SHA256  $s" | sha256sum -c --quiet - \
    || { rm -f "$s"; die "banlieue bootstrap script checksum mismatch (deleted; re-run)"; }
  echo "$s"
}

run_banlieue() {
  # Not inline in the command: a failing $(...) there wouldn't stop us.
  local s
  s="$(banlieue_script)" || exit 1
  BANLIEUE_ENV_FILE="$ENV_FILE" bash "$s" "$@"
}

step_node() {
  # SSH key k0sctl uses to reach the node (the script puts it in cloud-init).
  [[ -f "$HOME/.ssh/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C "ops@$(hostname)" -f "$HOME/.ssh/id_ed25519"

  # The script writes images and seeds as this user, VM disks via sudo.
  sudo install -d -m 0755 -o "$USER" -g "$USER" "$POOL_DIR"

  # Static DHCP lease: k0s doesn't survive its node changing address.
  local lease="/etc/systemd/network/50-$CH_BRIDGE.network.d/60-$VM_PREFIX-01.conf"
  local want
  want=$(printf '[DHCPServerStaticLease]\nMACAddress=%s\nAddress=%s' "$VM_MACS" "$MGMT_IP")
  if [[ "$(sudo cat "$lease" 2>/dev/null)" != "$want" ]]; then
    log "Static lease $VM_MACS -> $MGMT_IP on $CH_BRIDGE"
    sudo install -d "$(dirname "$lease")"
    printf '%s\n' "$want" | sudo tee "$lease" >/dev/null
    sudo networkctl reload
  fi

  log "banlieue bootstrap (v$BANLIEUE_VERSION): vms config apply kubeconfig"
  run_banlieue vms
  run_banlieue config
  run_banlieue apply
  run_banlieue kubeconfig
  step_resilience

  local out="${WORKDIR:-$HOME/.local/share/k0s-bootstrap}/$CLUSTER_NAME.kubeconfig"
  [[ -f "$out" ]] || die "kubeconfig not found at $out"
  install -d -m 0700 "$HOME/.kube"
  install -m 0600 "$out" "$KUBECONFIG_PATH"
  log "kubeconfig: $KUBECONFIG_PATH (server $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'))"
  kubectl get nodes -o wide
}

# The node VM must come back on its own after any host shutdown, including a
# power cut or a held power button (the console looks frozen once vfio-pci owns
# the GPU, so a clean shutdown is easy to mistake for a hang).
# - A clean shutdown is already graceful: the unit's ExecStop presses the VM's
#   ACPI power button and waits for the guest (TimeoutStopSec).
# - After a power cut the qcow2 is left marked dirty and Cloud Hypervisor
#   refuses to open it (InvalidClusterIndex). `qemu-img check -r leaks` before
#   every start clears that: it only frees leaked clusters, and fails (so the VM
#   stays down, its disk untouched) if it finds real corruption.
# - A failed start leaves serial.sock behind and every retry then fails on
#   "Address in use"; the unit only removes api.sock. Remove both.
# - The provider's token lives 24 h and is renewed while it runs (banlieue
#   hard-codes the renewal lifetime), so a host that was off longer comes
#   back unauthorized. homelab-heal.service runs `heal` on every boot.
# A drop-in, so re-running banlieue's script (which owns the unit) keeps it.
step_resilience() {
  local node="$VM_PREFIX-01"
  local unit="k0s-vm-$node.service"
  local dropin="/etc/systemd/system/$unit.d/50-homelab-resilience.conf"
  local disk="$CH_VM_DIR/$node/disk.qcow2"
  local want
  want=$(cat <<EOF
# Installed by bootstrap/cluster/bootstrap-mgmt.sh resilience (homelab-k0s).
[Service]
ExecStartPre=/bin/rm -f /run/k0s-vm-$node/serial.sock
ExecStartPre=/usr/bin/qemu-img check -q -r leaks $disk
EOF
)
  if [[ "$(sudo cat "$dropin" 2>/dev/null)" != "$want" ]]; then
    log "Power-cut recovery for $unit ($dropin)"
    sudo install -d "$(dirname "$dropin")"
    printf '%s\n' "$want" | sudo tee "$dropin" >/dev/null
    sudo systemctl daemon-reload
  fi

  local heal=/etc/systemd/system/homelab-heal.service
  want=$(cat <<EOF
# Installed by bootstrap/cluster/bootstrap-mgmt.sh resilience (homelab-k0s).
[Unit]
Description=homelab: reconnect the banlieue host provider after a long shutdown
Wants=network-online.target
After=network-online.target $unit

[Service]
Type=oneshot
User=$USER
ExecStart=$repo/bootstrap/cluster/bootstrap-mgmt.sh heal
TimeoutStartSec=20min

[Install]
WantedBy=multi-user.target
EOF
)
  if [[ "$(sudo cat "$heal" 2>/dev/null)" != "$want" ]]; then
    log "Boot-time provider credential check ($heal)"
    printf '%s\n' "$want" | sudo tee "$heal" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable homelab-heal.service
  fi
}

# Seconds until the provider's token expires (negative once it has; 0 when
# there is none). The token is a JWT: read `exp` from its payload.
provider_token_ttl() {
  local tok exp
  tok=$(sudo cat /etc/banlieue/credentials/token 2>/dev/null) || { echo 0; return; }
  exp=$(printf '%s' "$tok" | python3 -c 'import sys,json,base64
p=sys.stdin.read().split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))["exp"])' 2>/dev/null) \
    || { echo 0; return; }
  echo $(( exp - $(date +%s) ))
}

step_heal() {
  log "Waiting for the management cluster API"
  local i
  for i in {1..60}; do
    kubectl get --raw /readyz >/dev/null 2>&1 && break
    (( i == 60 )) && die "management cluster API not reachable after 10 min"
    sleep 10
  done
  local ttl; ttl=$(provider_token_ttl)
  if (( ttl > 3600 )); then
    log "Provider credential valid for another $(( ttl / 3600 ))h; nothing to do"
    return
  fi
  log "Provider credential expired or about to; issuing a new one"
  step_provider
}

step_flux() {
  log "Flux Operator (latest release)"
  kubectl apply --server-side -f "$FLUX_OPERATOR_INSTALL"
  kubectl -n flux-system rollout status deploy/flux-operator --timeout=5m

  log "FluxInstance from clusters/homelab/flux-system/flux-instance.yaml"
  kubectl apply --server-side -f "$repo/clusters/homelab/flux-system/flux-instance.yaml"
  if ! kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m; then
    kubectl -n flux-system get fluxinstance/flux -o yaml | sed -n '/^status:/,$p'
    die "FluxInstance not Ready. Is the artifact published and the GHCR package public?"
  fi
  kubectl -n flux-system get kustomizations
}

step_provider() {
  log "Waiting for Flux to create Provider/$PROVIDER_NAME (banlieue + hosts Kustomizations)"
  for _ in {1..90}; do
    kubectl -n banlieue-system get providers.banlieue.io "$PROVIDER_NAME" >/dev/null 2>&1 && break
    sleep 10
  done
  kubectl -n banlieue-system get providers.banlieue.io "$PROVIDER_NAME" >/dev/null || die "Provider/$PROVIDER_NAME never appeared"

  # A ServiceAccount token for this host's provider; it renews it itself at
  # half its lifetime. Re-run this step if the host was off (e.g. in Windows)
  # for longer than a lifetime. Same steps as banlieue's ch-host-provider-up.sh.
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  log "Issuing the host's credential"
  banlieue bootstrap cloud-hypervisor-host --provider "$PROVIDER_NAME" --output-dir "$tmp"
  sudo install -d -m 0700 -o banlieue -g banlieue /etc/banlieue/credentials
  for f in kubeconfig token; do
    sudo install -m 0600 -o banlieue -g banlieue "$tmp/$f" "/etc/banlieue/credentials/$f"
  done
  sudo systemctl enable banlieue-provider-cloud-hypervisor.service
  sudo systemctl restart banlieue-provider-cloud-hypervisor.service
  sleep 10
  sudo systemctl --no-pager status banlieue-provider-cloud-hypervisor.service | head -8
  kubectl -n banlieue-system get providers.banlieue.io "$PROVIDER_NAME" -o wide
}

# version_lt <a> <b>: a is older than b, comparing the Kubernetes version only
# (v1.35.10+k0s and 1.36.6+k0s.0 compare as 1.35.10 and 1.36.6).
version_lt() {
  local a="${1#v}" b="${2#v}"
  a="${a%%+*}"; b="${b%%+*}"
  [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$a" ]]
}

server_version() { kubectl version -o json | jq -r .serverVersion.gitVersion; }

# A control plane can't skip Kubernetes minors, so a running cluster steps
# through K0S_UPGRADE_PATH. Each step regenerates the k0sctl config at that
# version and applies it; k0sctl upgrades the node in place.
step_upgrade() {
  local current v
  current="$(server_version)"
  log "Cluster is at $current; target ${K0S_VERSION}"
  for v in $K0S_UPGRADE_PATH; do
    if ! version_lt "$current" "$v"; then
      log "  skip $v (already at or past it)"
      continue
    fi
    log "Upgrading to k0s $v"
    K0S_VERSION="$v" run_banlieue config
    K0S_VERSION="$v" run_banlieue apply
    kubectl wait node --all --for=condition=Ready --timeout=10m
    current="$(server_version)"
    log "  now at $current"
  done
  kubectl get nodes -o wide
}

step_status() {
  sudo systemctl --no-pager --lines=0 status "k0s-vm-$VM_PREFIX-01.service" || true
  kubectl get nodes -o wide || true
  kubectl -n flux-system get fluxinstance,ocirepositories,kustomizations 2>/dev/null || true
  kubectl -n banlieue-system get providers.banlieue.io 2>/dev/null || true
}

step_destroy() {
  echo "This deletes $VM_PREFIX-01, its disk and the whole management cluster."
  read -r -p "Type the cluster name ($CLUSTER_NAME) to continue: " answer
  [[ "$answer" == "$CLUSTER_NAME" ]] || die "aborted"
  run_banlieue destroy
}

case "${1:-}" in
  node) step_node ;;
  flux) step_flux ;;
  provider) step_provider ;;
  all) step_node; step_flux; step_provider ;;
  upgrade) step_upgrade ;;
  resilience) step_resilience ;;
  heal) step_heal ;;
  status) step_status ;;
  destroy) step_destroy ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
