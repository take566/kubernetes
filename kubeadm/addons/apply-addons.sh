#!/bin/bash
# Apply kubeadm cluster add-ons (run on control plane with kubeconfig)
# Usage: ./kubeadm/addons/apply-addons.sh [--with-nvidia] [--with-amd] [--with-ingress]
#        [--with-longhorn] [--with-metallb] [--with-network-policies]

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

WITH_NVIDIA=false
WITH_AMD=false
WITH_INGRESS=false
WITH_LONGHORN=false
WITH_METALLB=false
WITH_NETWORK_POLICIES=false
for arg in "$@"; do
  case "${arg}" in
    --with-nvidia) WITH_NVIDIA=true ;;
    --with-amd) WITH_AMD=true ;;
    --with-ingress) WITH_INGRESS=true ;;
    --with-longhorn) WITH_LONGHORN=true ;;
    --with-metallb) WITH_METALLB=true ;;
    --with-network-policies) WITH_NETWORK_POLICIES=true ;;
  esac
done

echo "=== Applying base addons (local-path, metrics-server) ==="
kubectl apply -k "${REPO_ROOT}/kubeadm/addons/"

if [[ "${WITH_INGRESS}" == true ]]; then
  echo "=== Applying ingress-nginx (DaemonSet + hostPort 80/443) ==="
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/ingress-nginx/"
  echo "  Validate: ${REPO_ROOT}/kubeadm/scripts/verify-ingress.sh"
fi

if [[ "${WITH_NVIDIA}" == true ]]; then
  echo "=== Applying NVIDIA device plugin ==="
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/nvidia-device-plugin/"
fi

if [[ "${WITH_AMD}" == true ]]; then
  echo "=== Applying AMD GPU device plugin ==="
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/amd-gpu-device-plugin/"
fi

if [[ "${WITH_LONGHORN}" == true ]]; then
  echo "=== Applying Longhorn (v1.7.2) ==="
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/longhorn/"
  echo "=== Promoting longhorn to default StorageClass ==="
  kubectl annotate storageclass longhorn storageclass.kubernetes.io/is-default-class=true --overwrite
  if kubectl get storageclass local-path &>/dev/null; then
    kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class- --overwrite
  fi
  echo "Longhorn UI: kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
  echo "vLLM: uncomment longhorn-storage-patch.yaml in vllm/overlays/kubeadm/kustomization.yaml"
fi

if [[ "${WITH_METALLB}" == true ]]; then
  echo "=== Applying MetalLB ==="
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/metallb/"
  echo "=== Waiting for MetalLB controller (CRDs) ==="
  kubectl -n metallb-system rollout status deployment/controller --timeout=180s 2>/dev/null || true
  if ! kubectl get ipaddresspool -n metallb-system default &>/dev/null; then
    echo "=== Re-applying MetalLB IPAddressPool ==="
    kubectl apply -f "${REPO_ROOT}/kubeadm/addons/metallb/ipaddresspool.yaml" || true
  fi
  echo "  Edit kubeadm/addons/metallb/ipaddresspool.yaml or METALLB_IP_POOL env before production use"
fi

if [[ "${WITH_NETWORK_POLICIES}" == true ]]; then
  if [[ -d "${REPO_ROOT}/kubeadm/addons/network-policies" ]]; then
    echo "=== Applying network policies ==="
    kubectl apply -k "${REPO_ROOT}/kubeadm/addons/network-policies/"
  else
    echo "[WARN] Network policies addon not found (kubeadm/addons/network-policies/)"
  fi
fi

echo "=== StorageClasses ==="
kubectl get storageclass
echo "=== Done ==="
if [[ "${WITH_INGRESS}" != true ]]; then
  echo "Ingress: kubectl apply -k kubeadm/addons/ingress-nginx/  or  bootstrap.sh --with-ingress"
fi
