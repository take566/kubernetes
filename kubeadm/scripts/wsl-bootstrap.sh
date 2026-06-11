#!/bin/bash
# Bootstrap kubeadm single-node cluster on WSL2 (Ubuntu + systemd).
# Usage: sudo ./kubeadm/scripts/wsl-bootstrap.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${REPO_ROOT}/kubeadm/scripts"

export CONTROL_PLANE_IP="$(hostname -I | awk '{print $1}')"
export CONTROL_PLANE_DNS="${CONTROL_PLANE_DNS:-${CONTROL_PLANE_IP}}"
export KUBEADM_CONFIG_WSL="${REPO_ROOT}/kubeadm/kubeadm-config-wsl.yaml"

echo "=== WSL kubeadm bootstrap ==="
echo "CONTROL_PLANE_IP=${CONTROL_PLANE_IP}"
echo "CONTROL_PLANE_DNS=${CONTROL_PLANE_DNS}"

if bash "${SCRIPTS}/check-wsl-mounts.sh" 2>/dev/null | grep -q .; then
  echo "[WARN] /proc/mounts has lines with != 6 fields (Docker Desktop WSL integration)."
  echo "       Attempting umount /Docker/host (temporary workaround)..."
  umount /Docker/host 2>/dev/null || true
  if bash "${SCRIPTS}/check-wsl-mounts.sh" 2>/dev/null | grep -q .; then
    echo "[ERROR] Still broken. Disable Docker Desktop WSL Integration for this distro and re-run."
    exit 1
  fi
  echo "       umount OK — for permanent fix disable WSL Integration in Docker Desktop"
fi

chmod +x "${REPO_ROOT}/kubeadm/bootstrap.sh" "${SCRIPTS}"/*.sh "${REPO_ROOT}/kubeadm/addons/apply-addons.sh"

if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "Resetting previous kubeadm cluster..."
  kubeadm reset -f 2>/dev/null || true
  rm -rf /etc/cni/net.d/* 2>/dev/null || true
fi

"${SCRIPTS}/01-prerequisites.sh"

# WSL: cgroupfs — must run after 01-prerequisites (which sets SystemdCgroup=true)
sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' /etc/containerd/config.toml 2>/dev/null || true
systemctl restart containerd
echo "containerd: SystemdCgroup=false (WSL cgroupfs)"

# kubelet 1.34+ fixes /proc/mounts parse with Docker Desktop (7-field lines)
export K8S_VERSION="${K8S_VERSION:-v1.34.2}"
export K8S_APT_VERSION="${K8S_APT_VERSION:-1.34}"
"${SCRIPTS}/02-install-kubeadm.sh"
# WSL-specific kubeadm config (cgroupfs)
CONFIG_TMP="$(mktemp)"
trap 'rm -f "${CONFIG_TMP}"' EXIT
sed -n '/^---/,$p' "${KUBEADM_CONFIG_WSL}" | sed \
  -e "s/cp.example.com:6443/${CONTROL_PLANE_DNS}:6443/g" \
  -e "s/advertiseAddress: \"192.168.1.10\"/advertiseAddress: \"${CONTROL_PLANE_IP}\"/g" \
  >"${CONFIG_TMP}"
echo "=== kubeadm init (WSL / cgroupfs) ==="
kubeadm init --config "${CONFIG_TMP}" --upload-certs

# wsl -u root leaves SUDO_USER empty; prefer ADMIN_USER=tmf or first login UID.
resolve_admin_user() {
  if [[ -n "${ADMIN_USER:-}" ]]; then
    echo "${ADMIN_USER}"
    return
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return
  fi
  local login_user
  login_user="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)/ { print $1; exit }')"
  echo "${login_user:-root}"
}
ADMIN_USER="$(resolve_admin_user)"
ADMIN_HOME="$(eval echo "~${ADMIN_USER}")"
mkdir -p "${ADMIN_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${ADMIN_HOME}/.kube/config"
chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.kube/config" 2>/dev/null || true
chmod 600 "${ADMIN_HOME}/.kube/config"
"${SCRIPTS}/05-install-cni.sh"
"${REPO_ROOT}/kubeadm/addons/apply-addons.sh" --with-ingress --with-network-policies
"${SCRIPTS}/wsl-post-init.sh"

echo "=== Waiting for core addons ==="
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s 2>/dev/null || true
kubectl -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=300s 2>/dev/null || true

"${SCRIPTS}/run-integration-tests.sh" || true

echo ""
echo "=== WSL kubeadm cluster ready ==="
echo "Context: kubeadm-wsl (merge below)"
echo "  export KUBECONFIG=~/.kube/config-kubeadm-wsl"
ADMIN_USER="$(resolve_admin_user)"
ADMIN_HOME="$(eval echo "~${ADMIN_USER}")"
mkdir -p "${ADMIN_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${ADMIN_HOME}/.kube/config-kubeadm-wsl"
chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.kube/config-kubeadm-wsl"
chmod 600 "${ADMIN_HOME}/.kube/config-kubeadm-wsl"
kubectl --kubeconfig="${ADMIN_HOME}/.kube/config-kubeadm-wsl" config rename-context kubernetes-admin@kubernetes kubeadm-wsl 2>/dev/null || true
kubectl --kubeconfig="${ADMIN_HOME}/.kube/config-kubeadm-wsl" cluster-info
