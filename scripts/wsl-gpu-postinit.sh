#!/usr/bin/env bash
# Post-init WSL GPU: RuntimeClass + device plugin host mounts
set -euo pipefail
export PATH="/usr/lib/wsl/lib:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
REPO="${1:?repo path}"

kubectl apply --validate=false -f "${REPO}/kubeadm/addons/nvidia-runtime-class.yaml"
kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type=json \
  --patch-file "${REPO}/kubeadm/addons/nvidia-device-plugin/wsl-patch.json" 2>/dev/null || true
sleep 10
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
