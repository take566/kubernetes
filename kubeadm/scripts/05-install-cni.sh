#!/bin/bash
# 05-install-cni.sh — Calico (default) or Cilium
# Usage (with working kubeconfig on control plane):
#   sudo ./kubeadm/scripts/05-install-cni.sh
#   CNI=cilium sudo ./kubeadm/scripts/05-install-cni.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
[[ -f "${KUBECONFIG}" ]] || die "Kubeconfig not found: ${KUBECONFIG}. Run 03-init-control-plane.sh first."

log "=== Installing CNI: ${CNI} (podSubnet=${POD_SUBNET}) ==="

case "${CNI}" in
  calico)
    CALICO_VERSION="${CALICO_VERSION:-v3.27.3}"
    curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
      | sed "s|# - name: CALICO_IPV4POOL_CIDR|  - name: CALICO_IPV4POOL_CIDR|; s|#   value: \"192.168.0.0/16\"|    value: \"${POD_SUBNET}\"|" \
      | kubectl apply -f -
    ;;
  cilium)
    CILIUM_VERSION="${CILIUM_VERSION:-1.15.6}"
    if ! command_exists helm; then
      die "helm required for Cilium. Install helm or use CNI=calico."
    fi
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update
    helm upgrade --install cilium cilium/cilium --version "${CILIUM_VERSION}" \
      --namespace kube-system \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_SUBNET}}"
    ;;
  *)
    die "Unknown CNI=${CNI}. Use calico or cilium."
    ;;
esac

log "Waiting for kube-system pods..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s 2>/dev/null || \
  warn "Some kube-system pods not Ready yet; check: kubectl get pods -n kube-system"

log "CNI install complete."
