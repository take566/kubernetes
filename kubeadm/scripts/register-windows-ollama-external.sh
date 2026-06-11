#!/usr/bin/env bash
# Register Windows-native Ollama as an in-cluster external endpoint (non-ROCm AMD GPU path).
# Usage: ./kubeadm/scripts/register-windows-ollama-external.sh [--host-ip <ip>] [--verify]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-kubeadm-wsl}"
HOST_IP=""
VERIFY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-ip) HOST_IP="$2"; shift 2 ;;
    --verify) VERIFY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--host-ip <windows-host-ip>] [--verify]"
      echo "  Default host IP: WSL default gateway (Windows host on WSL2)."
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="$(ip route show default | awk '{print $3}')"
fi

if [[ -z "${HOST_IP}" ]]; then
  echo "ERROR: could not detect Windows host IP. Pass --host-ip." >&2
  exit 1
fi

echo "=== Register Windows Ollama external endpoint ==="
echo "  Windows host IP: ${HOST_IP}"
echo "  KUBECONFIG: ${KUBECONFIG}"

# Avoid corporate http_proxy breaking curl to RFC1918 (see kubeadm/scripts/verify-ingress.sh)
noproxy_curl() {
  curl --noproxy '*' "$@"
}

echo "=== Preflight: Windows Ollama reachable from WSL ==="
if ! noproxy_curl -sf --connect-timeout 5 "http://${HOST_IP}:11434/api/tags" >/dev/null; then
  cat >&2 <<EOF
ERROR: Cannot reach http://${HOST_IP}:11434 from WSL.

Fix on Windows (PowerShell):
  .\\scripts\\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
  # Restart Ollama, then re-run this script.

If Ollama listens on 127.0.0.1 only:
  netstat -an | findstr 11434   # expect 0.0.0.0:11434 after OLLAMA_HOST + restart
EOF
  exit 1
fi
echo "  Ollama API: OK"

echo "=== Applying Service (kustomize) ==="
kubectl apply -k "${REPO_ROOT}/vllm/overlays/kubeadm/windows-ollama-external/"

echo "=== Applying Endpoints ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Endpoints
metadata:
  name: ollama-external
  namespace: vllm
  labels:
    app: ollama-external
    app.kubernetes.io/part-of: vllm
    app.kubernetes.io/component: windows-ollama-bridge
subsets:
  - addresses:
      - ip: ${HOST_IP}
    ports:
      - name: http
        port: 11434
        protocol: TCP
EOF

echo "=== Done ==="
kubectl get svc,endpoints -n vllm ollama-external

if [[ "${VERIFY}" == true ]]; then
  echo "=== In-cluster verify (Job) ==="
  kubectl -n vllm delete pod ollama-ext-verify --ignore-not-found
  kubectl apply -f - <<'JOBEOF'
apiVersion: v1
kind: Pod
metadata:
  name: ollama-ext-verify
  namespace: vllm
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.5.0
      command:
        - sh
        - -c
        - |
          set -eu
          curl -sf "http://ollama-external.vllm:11434/api/tags" | head -c 300
          echo
JOBEOF
  kubectl -n vllm wait --for=jsonpath='{.status.phase}'=Succeeded pod/ollama-ext-verify --timeout=120s
  echo "  Pod phase: Succeeded (in-cluster → Windows Ollama OK)"
  kubectl -n vllm delete pod ollama-ext-verify --ignore-not-found
fi

cat <<EOF

In-cluster URLs:
  Native API:  http://ollama-external.vllm.svc.cluster.local:11434/api/generate
  OpenAI API:  http://ollama-external.vllm.svc.cluster.local:11434/v1/chat/completions

Example (from a Pod):
  curl http://ollama-external.vllm:11434/v1/models
EOF
