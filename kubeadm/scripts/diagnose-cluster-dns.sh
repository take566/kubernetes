#!/bin/bash
# Diagnose CoreDNS / Calico / cluster Service IP connectivity on kubeadm (especially WSL).
# Usage: ./kubeadm/scripts/diagnose-cluster-dns.sh
# Env:   KUBECONFIG (default: ~/.kube/config-kubeadm-wsl or /etc/kubernetes/admin.conf)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config-kubeadm-wsl" ]]; then
    export KUBECONFIG="${HOME}/.kube/config-kubeadm-wsl"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
fi

command_exists kubectl || die "kubectl not found"

log "=== Cluster DNS / Calico diagnostics ==="
log "KUBECONFIG=${KUBECONFIG:-<default>}"

log "--- Nodes ---"
kubectl get nodes -o wide || die "kubectl failed — check KUBECONFIG"

log "--- CoreDNS / kube-dns ---"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide || true
kubectl get svc -n kube-system kube-dns -o wide || true
kubectl get endpoints kube-dns -n kube-system 2>/dev/null || kubectl get endpointslices -n kube-system -l kubernetes.io/service-name=kube-dns || true

log "--- Calico ---"
kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers -o wide 2>/dev/null || true
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide 2>/dev/null || true

log "--- kubernetes Service ---"
kubectl get svc kubernetes -o wide
kubectl get endpoints kubernetes -o yaml 2>/dev/null | grep -E 'ip:|port:' || true

log "--- NetworkPolicies (kube-system) ---"
kubectl get networkpolicies -n kube-system -o custom-columns=NAME:.metadata.name,POD_SELECTOR:.spec.podSelector,EGRESS:.spec.policyTypes 2>/dev/null || true

log "--- Pod logs (crictl fallback if kubectl logs forbidden) ---"
COREDNS_ID="$(crictl ps --name coredns -q 2>/dev/null | head -1 || true)"
CALICO_ID="$(crictl ps -a --name calico-kube-controllers -q 2>/dev/null | head -1 || true)"
if [[ -n "${COREDNS_ID}" ]]; then
  log "CoreDNS log tail (crictl ${COREDNS_ID}):"
  crictl logs --tail 15 "${COREDNS_ID}" 2>/dev/null | grep -E 'timeout|ready|error|10\.96\.0\.1' || crictl logs --tail 8 "${COREDNS_ID}" 2>/dev/null || true
fi
if [[ -n "${CALICO_ID}" ]]; then
  log "Calico controllers log tail (crictl ${CALICO_ID}):"
  crictl logs --tail 15 "${CALICO_ID}" 2>/dev/null | grep -E 'timeout|ERROR|10\.96\.0\.1|initialize' || crictl logs --tail 8 "${CALICO_ID}" 2>/dev/null || true
fi

log "--- API ClusterIP from node ---"
if command -v curl >/dev/null 2>&1; then
  curl -k -m 3 -s -o /dev/null -w "curl https://10.96.0.1:443/healthz → HTTP %{http_code}\n" https://10.96.0.1:443/healthz 2>/dev/null || log "curl 10.96.0.1 failed (expected if routing broken from host netns)"
fi

log "--- Recommendations ---"
if kubectl get endpoints kube-dns -n kube-system -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | grep -q .; then
  log "kube-dns endpoints: OK"
else
  warn "kube-dns has no ready endpoints — check CoreDNS readiness and NetworkPolicy egress"
  warn "Fix: kubectl apply -k kubeadm/addons/network-policies/ (includes allow-kube-system-addon-egress.yaml)"
  warn "Doc: kubeadm/docs/cluster-dns-troubleshooting.md"
fi

READY="$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '{print $2}' | grep -c '1/1' || true)"
if [[ "${READY:-0}" -ge 1 ]]; then
  log "CoreDNS ready count: ${READY}"
else
  warn "No CoreDNS pod Ready — see logs above for 10.96.0.1 timeout"
fi

log "Done."
