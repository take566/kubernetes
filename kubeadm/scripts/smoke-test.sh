#!/bin/bash
# Post-bootstrap smoke tests (run on any cluster with kubeconfig configured).
# Usage:
#   ./kubeadm/scripts/smoke-test.sh
#   KUBECONFIG=~/.kube/config-kubeadm ./kubeadm/scripts/smoke-test.sh --with-ingress

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WITH_INGRESS=false
SKIP_INGRESS_TEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-ingress) WITH_INGRESS=true; shift ;;
    --skip-ingress-test) SKIP_INGRESS_TEST=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--with-ingress] [--skip-ingress-test]"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "[PASS] ${name}"
    pass=$((pass + 1))
  else
    echo "[FAIL] ${name}" >&2
    fail=$((fail + 1))
  fi
}

echo "=== kubeadm smoke-test ==="
echo "Context: $(kubectl config current-context 2>/dev/null || echo unknown)"

check "kubectl cluster-info" kubectl cluster-info
check "nodes Ready" bash -c '! kubectl get nodes --no-headers 2>/dev/null | grep -q NotReady'
check "metrics-server pod" kubectl -n kube-system get pods -l k8s-app=metrics-server --no-headers 2>/dev/null | grep -q Running || \
  kubectl -n kube-system get deployment metrics-server --no-headers 2>/dev/null | grep -q .
check "local-path StorageClass" kubectl get storageclass local-path --no-headers 2>/dev/null | grep -q local-path

if [[ "${WITH_INGRESS}" == true ]]; then
  check "ingress-nginx controller" kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | grep -q Running
  if [[ "${SKIP_INGRESS_TEST}" != true ]]; then
    kubectl apply -f "${REPO_ROOT}/kubeadm/addons/ingress-nginx/test-ingress.yaml" >/dev/null
    kubectl -n ingress-test wait --for=condition=available deployment/echo --timeout=120s
    node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
    if curl -sf -H 'Host: echo.local' "http://${node_ip}/" | grep -qi echo; then
      echo "[PASS] ingress curl http://${node_ip}/"
      pass=$((pass + 1))
    else
      echo "[FAIL] ingress curl http://${node_ip}/" >&2
      fail=$((fail + 1))
    fi
    kubectl delete -f "${REPO_ROOT}/kubeadm/addons/ingress-nginx/test-ingress.yaml" --ignore-not-found >/dev/null
  fi
fi

echo ""
echo "=== Results: ${pass} passed, ${fail} failed ==="
[[ "${fail}" -eq 0 ]]
