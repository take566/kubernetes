#!/bin/bash
# Post-init fixes for single-node kubeadm on WSL (schedule workloads on control-plane).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
[[ -f "${KUBECONFIG}" ]] || die "Run kubeadm init first."

log "=== WSL single-node post-init ==="

# Allow scheduling on control-plane (single-node dev cluster)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || \
  kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
log "Node: ${NODE}"

kubectl wait --for=condition=Ready "node/${NODE}" --timeout=300s
log "WSL post-init complete."
