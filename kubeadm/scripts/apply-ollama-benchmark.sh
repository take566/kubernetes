#!/usr/bin/env bash
# Apply kubeadm Ollama benchmark Job; patches Windows host IP when cluster DNS is flaky.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-kubeadm-wsl}"
GW="$(ip route show default | awk "{print \$3}")"
[[ -n "$GW" ]] || { echo "Cannot detect Windows gateway IP" >&2; exit 1; }
kubectl apply -k "${REPO_ROOT}/vllm/overlays/kubeadm/ollama-benchmark/"
kubectl patch configmap vllm-benchmark-config -n vllm --type merge \
  -p "{\"data\":{\"VLLM_BASE_URL\":\"http://${GW}:11434/v1\"}}"
kubectl delete job vllm-benchmark -n vllm --ignore-not-found
kubectl apply -f "${REPO_ROOT}/vllm/benchmark/benchmark-job.yaml"
echo "Benchmark Job submitted (base_url=http://${GW}:11434/v1)"
