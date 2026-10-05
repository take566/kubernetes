#!/bin/bash
# 02-install-kubeadm.sh — install kubeadm, kubelet, kubectl
# Usage: sudo ./kubeadm/scripts/02-install-kubeadm.sh
# Override version: export K8S_VERSION=v1.30.4

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

log "=== Installing Kubernetes ${K8S_VERSION} (apt repo ${K8S_APT_VERSION}) ==="

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_APT_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_APT_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Pin kubelet to requested version if apt installed a different patch
INSTALLED="$(kubelet --version 2>/dev/null | awk '{print $2}')"
if [[ "${INSTALLED}" != "${K8S_VERSION}" ]]; then
  warn "Installed kubelet ${INSTALLED}; requested ${K8S_VERSION}. Adjust K8S_APT_VERSION or apt install kubelet=${K8S_VERSION}-*"
fi

systemctl enable kubelet

log "Installed: kubeadm $(kubeadm version -o short 2>/dev/null || true)"
log "Installed: kubectl $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 || kubectl version --client 2>/dev/null | head -1)"
log "Run 03-init-control-plane.sh on the first control-plane node."
