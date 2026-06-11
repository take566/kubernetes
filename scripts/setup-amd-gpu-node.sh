#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_NAME="${NODE_NAME:-}"

if [[ -z "${NODE_NAME}" ]]; then
  NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
fi

if [[ -z "${NODE_NAME}" ]]; then
  echo "ERROR: NODE_NAME is empty. Export NODE_NAME and retry." >&2
  exit 1
fi

OVERLAY="${OVERLAY:-kind/amd}"

echo "=== Applying AMD GPU device plugin ==="
kubectl apply -k "${REPO_ROOT}/kubeadm/addons/amd-gpu-device-plugin/"

echo "=== Labeling node: ${NODE_NAME} ==="
kubectl label node "${NODE_NAME}" amd.com/gpu.present=true --overwrite
kubectl label node "${NODE_NAME}" workload=vllm-amd --overwrite

echo "=== Waiting for device plugin (up to 60s) ==="
for _ in $(seq 1 12); do
  ALLOCATABLE_GPU="$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.allocatable.amd\.com/gpu}' 2>/dev/null || true)"
  if [[ -n "${ALLOCATABLE_GPU}" && "${ALLOCATABLE_GPU}" != "0" ]]; then
    break
  fi
  sleep 5
done

echo "=== Verifying allocatable AMD GPU ==="
ALLOCATABLE_GPU="$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.allocatable.amd\.com/gpu}')"
if [[ -z "${ALLOCATABLE_GPU}" || "${ALLOCATABLE_GPU}" == "0" ]]; then
  echo "WARN: amd.com/gpu is not allocatable on node ${NODE_NAME}" >&2
  echo "Check plugin pods: kubectl get pods -n kube-system -l name=amdgpu-dp-ds" >&2
  echo "Host preflight (WSL/Linux): ls -la /dev/kfd /dev/dri; rocminfo | head" >&2
  echo "RX 5700 on WSL: ROCm is unsupported — use Linux ROCm worker or Ollama on Windows." >&2
  echo "See docs/LOCAL_GPU_SETUP_WINDOWS.md" >&2
  exit 1
fi
echo "amd.com/gpu allocatable on ${NODE_NAME}: ${ALLOCATABLE_GPU}"

echo "=== Applying vLLM AMD overlay: vllm/overlays/${OVERLAY}/ ==="
kubectl kustomize "${REPO_ROOT}/vllm/overlays/${OVERLAY}" --load-restrictor LoadRestrictionsNone | kubectl apply -f -

cat <<EOF
=== Done ===
Monitor: kubectl -n vllm get pods -l app=vllm -w
EOF
