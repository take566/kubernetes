#!/bin/bash
# Apply kind cluster add-ons (local-path, metrics-server).
# Usage: ./kind/addons/apply-addons.sh
#
# Uses the same manifests as kubeadm/addons/ via kind/addons/kustomization.yaml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-dev}"
CONTEXT="kind-${CLUSTER_NAME}"

export KUBECONFIG="${KUBECONFIG:-$(kind get kubeconfig --name "${CLUSTER_NAME}")}"

echo "=== Applying kind add-ons (context: ${CONTEXT}) ==="
kubectl --context "${CONTEXT}" apply -k "${REPO_ROOT}/kind/addons/"

echo "=== StorageClasses ==="
kubectl --context "${CONTEXT}" get storageclass
echo "=== Done ==="
