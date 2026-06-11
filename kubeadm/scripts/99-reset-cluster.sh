#!/bin/bash
# 99-reset-cluster.sh — reset a kubeadm node (control-plane or worker)
#
# Usage:
#   sudo ./kubeadm/scripts/99-reset-cluster.sh              # interactive confirm
#   sudo ./kubeadm/scripts/99-reset-cluster.sh --yes          # skip confirmation
#   sudo ./kubeadm/scripts/99-reset-cluster.sh --purge-data   # also remove etcd/CNI leftovers
#   sudo ./kubeadm/scripts/99-reset-cluster.sh --dry-run      # print steps only
#   sudo ./kubeadm/scripts/99-reset-cluster.sh --yes --purge-data
#
# Works on control-plane and worker nodes. On HA clusters, drain/remove the node
# from the cluster (kubectl) before resetting a control-plane member.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

YES=false
PURGE_DATA=false
DRY_RUN=false

print_usage() {
  cat <<'EOF'
Reset a kubeadm node (control-plane or worker)

Usage:
  sudo ./kubeadm/scripts/99-reset-cluster.sh [options]

Options:
  --yes          Skip interactive confirmation
  --purge-data   Remove leftover data dirs (/var/lib/etcd, /etc/cni/net.d, kubelet state hints)
  --dry-run      Print planned steps without executing
  -h, --help     Show this help

Examples:
  sudo ./kubeadm/scripts/99-reset-cluster.sh --dry-run
  sudo ./kubeadm/scripts/99-reset-cluster.sh --yes
  sudo ./kubeadm/scripts/99-reset-cluster.sh --yes --purge-data

HA control-plane: drain/delete the node from the cluster before reset when possible.
See kubeadm/docs/ha-control-plane.md
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      YES=true
      shift
      ;;
    --purge-data)
      PURGE_DATA=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (try --help)"
      ;;
  esac
done

detect_node_role() {
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo "control-plane"
  elif [[ -d /etc/kubernetes/manifests ]] && [[ -n "$(ls -A /etc/kubernetes/manifests 2>/dev/null || true)" ]]; then
    echo "control-plane"
  elif [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo "worker"
  else
    echo "unknown"
  fi
}

run_or_log() {
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] $*"
    return 0
  fi
  log "Running: $*"
  "$@"
}

confirm_reset() {
  if [[ "${YES}" == true || "${DRY_RUN}" == true ]]; then
    return 0
  fi
  local role="$1"
  warn "This will reset this node (detected role: ${role})."
  warn "Cluster membership and local kubeconfig will be removed."
  if [[ "${role}" == "control-plane" ]]; then
    warn "On HA clusters, ensure this node was drained/removed from the cluster first."
  fi
  read -r -p "Continue? [y/N] " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || die "Aborted."
}

purge_leftover_data() {
  local role="$1"

  if [[ "${role}" == "control-plane" && -d /var/lib/etcd ]]; then
    run_or_log rm -rf /var/lib/etcd
  elif [[ "${role}" != "control-plane" && -d /var/lib/etcd ]]; then
    warn "/var/lib/etcd exists on a non-control-plane node; skipping removal (use --purge-data on CP if needed)"
  elif [[ "${DRY_RUN}" == true && "${role}" == "control-plane" ]]; then
    log "[dry-run] rm -rf /var/lib/etcd   # control-plane etcd data"
  fi

  if [[ -d /etc/cni/net.d ]]; then
    run_or_log rm -rf /etc/cni/net.d
  elif [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] rm -rf /etc/cni/net.d   # CNI config leftovers"
  fi

  if [[ -d /var/lib/kubelet ]]; then
    if [[ "${PURGE_DATA}" == true ]]; then
      run_or_log rm -rf /var/lib/kubelet/*
    else
      warn "Hint: clear kubelet state with: rm -rf /var/lib/kubelet/* (or re-run with --purge-data)"
    fi
  fi

  if [[ -f "${HOME}/.kube/config" ]]; then
    warn "Hint: remove local kubeconfig if stale: rm -f ${HOME}/.kube/config"
  fi
  if [[ -f /root/.kube/config ]]; then
    warn "Hint: remove root kubeconfig if stale: rm -f /root/.kube/config"
  fi
}

reset_iptables_hints() {
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X"
    log "[dry-run] ipvsadm --clear   # if ipvsadm is installed"
    return 0
  fi
  if command_exists iptables; then
    iptables -F || true
    iptables -t nat -F || true
    iptables -t mangle -F || true
    iptables -X || true
  fi
  if command_exists ipvsadm; then
    ipvsadm --clear || true
  fi
}

if [[ "${DRY_RUN}" != true ]]; then
  require_root
fi

NODE_ROLE="$(detect_node_role)"
log "=== kubeadm reset (role=${NODE_ROLE}, purge-data=${PURGE_DATA}, dry-run=${DRY_RUN}) ==="

confirm_reset "${NODE_ROLE}"

if command_exists kubeadm; then
  run_or_log kubeadm reset -f
else
  warn "kubeadm not found; skipping kubeadm reset"
fi

if [[ "${PURGE_DATA}" == true ]]; then
  log "=== Purging leftover data (--purge-data) ==="
  purge_leftover_data "${NODE_ROLE}"
else
  log "=== Post-reset cleanup hints (use --purge-data to apply) ==="
  if [[ "${NODE_ROLE}" == "control-plane" ]]; then
    warn "Hint: remove etcd data on control-plane: rm -rf /var/lib/etcd"
  fi
  warn "Hint: remove CNI config: rm -rf /etc/cni/net.d"
  warn "Hint: clear kubelet state: rm -rf /var/lib/kubelet/*"
fi

log "=== Optional network rule cleanup ==="
reset_iptables_hints

if [[ "${DRY_RUN}" == true ]]; then
  log "=== Dry-run complete (no changes made) ==="
else
  log "=== Reset complete ==="
  log "Re-bootstrap: 01-prerequisites.sh → 02-install-kubeadm.sh → join or init"
fi

exit 0
