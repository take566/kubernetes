#!/bin/bash
# Post-init orchestration for kubeadm clusters (control plane)
# Usage: sudo ./kubeadm/scripts/bootstrap-cluster.sh
# Prerequisites: 03-init-control-plane.sh completed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
[[ -f "${KUBECONFIG}" ]] || die "Run 03-init-control-plane.sh first."

log "=== kubeadm cluster bootstrap (CNI + addons) ==="
"${SCRIPT_DIR}/05-install-cni.sh"
"${KUBEADM_DIR}/addons/apply-addons.sh" "$@"
log "Optional: kubectl apply -k nginx/ && kubectl apply -f argocd/apps/root-application.yaml"
