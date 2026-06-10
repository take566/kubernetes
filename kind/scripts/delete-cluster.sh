#!/bin/bash
# Delete a kind cluster.
# Usage: ./kind/scripts/delete-cluster.sh [cluster-name]

set -euo pipefail

CLUSTER_NAME="${1:-${KIND_CLUSTER_NAME:-dev}}"

if ! command -v kind &> /dev/null; then
  echo "Error: kind is not installed" >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "Deleted kind cluster: ${CLUSTER_NAME}"
else
  echo "Cluster '${CLUSTER_NAME}' not found — nothing to delete"
fi
