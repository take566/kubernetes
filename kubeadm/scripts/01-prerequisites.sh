#!/bin/bash
# 01-prerequisites.sh — swap off, kernel modules, sysctl, containerd
# Target: Ubuntu 22.04/24.04 or Debian 12 on Linux (not Windows dev host)
# Usage: sudo ./kubeadm/scripts/01-prerequisites.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

log "=== kubeadm prerequisites ==="

# --- swap off (idempotent) ---
if swapon --show | grep -q .; then
  log "Disabling swap..."
  swapoff -a
fi
if grep -qE '^\s*[^#].*\sswap\s' /etc/fstab; then
  sed -i.bak-kubeadm '/\sswap\s/s/^/# kubeadm-disabled: /' /etc/fstab
  log "Commented swap entries in /etc/fstab (backup: /etc/fstab.bak-kubeadm)"
else
  log "Swap already disabled in fstab"
fi

# --- kernel modules ---
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

# --- sysctl ---
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# --- containerd ---
if ! command_exists containerd; then
  log "Installing containerd..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq containerd.io
else
  log "containerd already installed"
fi

mkdir -p /etc/containerd
if [[ ! -f /etc/containerd/config.toml ]] || ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  log "Configured containerd with SystemdCgroup=true"
fi

systemctl enable containerd
systemctl restart containerd

# --- optional: disable firewalld/ufw hints ---
if systemctl is-active --quiet ufw 2>/dev/null; then
  warn "ufw is active. Ensure ports 6443, 10250, 2379-2380, and CNI ports are open."
fi

log "Prerequisites complete."
