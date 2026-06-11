#!/bin/bash
# Verify ingress end-to-end (kind + kubeadm). In-cluster curl avoids Docker/hostPort/proxy issues.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

kubectl apply -f "${REPO_ROOT}/kubeadm/addons/ingress-nginx/test-ingress.yaml"
kubectl -n ingress-test wait --for=condition=available deployment/echo --timeout=120s
kubectl -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=180s 2>/dev/null || true
sleep 5

cleanup() {
  kubectl delete -f "${REPO_ROOT}/kubeadm/addons/ingress-nginx/test-ingress.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pod ingress-verify-curl -n ingress-test --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

verify_hostport() {
  if command -v curl >/dev/null 2>&1; then
    # WSL may set http_proxy; bypass for localhost hostPort test
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -sf -m 15 -H 'Host: echo.local' 'http://127.0.0.1/' 2>/dev/null && return 0
  fi
  return 1
}

if verify_hostport | grep -q 'echo.local'; then
  echo 'Ingress OK (hostPort curl http://127.0.0.1/)'
  exit 0
fi

kubectl delete pod ingress-verify-curl -n ingress-test --ignore-not-found >/dev/null 2>&1 || true
kubectl -n ingress-test run ingress-verify-curl \
  --restart=Never \
  --image=curlimages/curl:8.5.0 \
  --command -- \
  curl -sf -m 30 -H 'Host: echo.local' 'http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/'

kubectl -n ingress-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/ingress-verify-curl --timeout=90s 2>/dev/null || true

out="$(kubectl -n ingress-test logs ingress-verify-curl 2>/dev/null || true)"
if echo "${out}" | grep -q 'echo.local'; then
  echo 'Ingress OK (in-cluster curl via ingress-nginx Service)'
  exit 0
fi

if verify_hostport | grep -q 'echo.local'; then
  echo 'Ingress OK (hostPort curl fallback)'
  exit 0
fi

echo "Ingress response: ${out:0:300}" >&2
echo 'Ingress verification FAILED' >&2
exit 1
