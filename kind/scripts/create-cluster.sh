#!/bin/bash
# Create a kind cluster and apply base add-ons.
# Usage: ./kind/scripts/create-cluster.sh [cluster-name]
#
# Prerequisites: Docker, kind, kubectl
# Env: KIND_CLUSTER_NAME (default: dev), KIND_CONFIG (override config path)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="${1:-${KIND_CLUSTER_NAME:-dev}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${KIND_CONFIG:-${REPO_ROOT}/kind/kind-config.yaml}"
CONTEXT="kind-${CLUSTER_NAME}"

echo "=== kind cluster bootstrap ==="
echo "  cluster: ${CLUSTER_NAME}"
echo "  config:  ${CONFIG}"

for tool in docker kind kubectl; do
  if ! command -v "$tool" &> /dev/null; then
    echo -e "${RED}Error: ${tool} is not installed${NC}" >&2
    exit 1
  fi
done

if ! docker info &> /dev/null; then
  echo -e "${RED}Error: Docker daemon is not running${NC}" >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists — reusing${NC}"
else
  echo "--- Creating cluster ---"
  kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG}"
  echo -e "${GREEN}Cluster created${NC}"
fi

kubectl config use-context "${CONTEXT}"
kubectl cluster-info --context "${CONTEXT}"

echo "--- Applying add-ons (local-path, metrics-server) ---"
export KIND_CLUSTER_NAME="${CLUSTER_NAME}"
"${REPO_ROOT}/kind/addons/apply-addons.sh"

echo ""
echo -e "${GREEN}=== kind cluster ready ===${NC}"
echo "  context: kubectl config use-context ${CONTEXT}"
echo "  ingress: kubectl apply -k nginx/"
echo "  vLLM (smoke test, no GPU): kubectl apply -k vllm/overlays/kind/"
echo "  destroy: ./kind/scripts/delete-cluster.sh ${CLUSTER_NAME}"
