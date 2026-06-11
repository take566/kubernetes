#!/bin/bash
# Pre-load container images into a kind cluster (avoids pull during CI/offline dev).
# Usage: ./kind/scripts/load-images.sh [cluster-name]
#
# GPU note: kind runs inside Docker and does NOT expose host GPUs.
# vLLM GPU workloads will stay Pending; use this script for manifest/smoke validation only.

set -euo pipefail

CLUSTER_NAME="${1:-${KIND_CLUSTER_NAME:-dev}}"

if ! command -v kind &> /dev/null; then
  echo "Error: kind is not installed" >&2
  exit 1
fi

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Error: kind cluster '${CLUSTER_NAME}' does not exist" >&2
  echo "Run: ./kind/scripts/create-cluster.sh ${CLUSTER_NAME}" >&2
  exit 1
fi

# Default vLLM inference image (see vllm/base/vllm-deployment.yaml)
# Mac/kind CPU overlay: export VLLM_CPU_IMAGE=openeuler/vllm-cpu:0.20.1-oe2403sp3
IMAGES=(
  "vllm/vllm-openai:latest"
)
if [[ -n "${VLLM_CPU_IMAGE:-}" ]]; then
  IMAGES+=("${VLLM_CPU_IMAGE}")
fi

# Optional: pull before load
# for img in "${IMAGES[@]}"; do docker pull "$img"; done

echo "=== Loading images into kind cluster '${CLUSTER_NAME}' ==="
for img in "${IMAGES[@]}"; do
  echo "  kind load docker-image ${img} --name ${CLUSTER_NAME}"
  kind load docker-image "${img}" --name "${CLUSTER_NAME}"
done

echo "Done. GPU workloads still require kubeadm or a cloud cluster with device plugins."
