#!/bin/bash
# Apply kubeadm cluster add-ons (run on control plane with kubeconfig)
# Usage: ./kubeadm/addons/apply-addons.sh [--with-nvidia]

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

WITH_NVIDIA=false
for arg in "$@"; do
  case "${arg}" in
    --with-nvidia) WITH_NVIDIA=true ;;
  esac
done

echo "=== Applying base addons (local-path, metrics-server) ==="
kubectl apply -k "${REPO_ROOT}/kubeadm/addons/"

if [[ "${WITH_NVIDIA}" == true ]]; then
  echo "=== Applying NVIDIA device plugin ==="
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/nvidia-device-plugin/"
fi

echo "=== StorageClasses ==="
kubectl get storageclass
echo "=== Done ==="
echo "Ingress: use existing nginx/ manifests or Argo CD nginx-app"
echo "  kubectl apply -k nginx/"
