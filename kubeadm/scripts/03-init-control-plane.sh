#!/bin/bash
# 03-init-control-plane.sh — kubeadm init with config file
# Usage (control-plane node, after 01 + 02):
#   export CONTROL_PLANE_IP=192.168.1.10
#   export CONTROL_PLANE_DNS=cp.example.com   # optional; defaults to CONTROL_PLANE_IP
#   sudo ./kubeadm/scripts/03-init-control-plane.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
CONTROL_PLANE_DNS="${CONTROL_PLANE_DNS:-${CONTROL_PLANE_IP}}"

if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  CONTROL_PLANE_IP="$(hostname -I | awk '{print $1}')"
  warn "CONTROL_PLANE_IP not set; using detected IP: ${CONTROL_PLANE_IP}"
fi
if [[ -z "${CONTROL_PLANE_DNS}" ]]; then
  CONTROL_PLANE_DNS="${CONTROL_PLANE_IP}"
fi

CONFIG_SRC="${KUBEADM_DIR}/kubeadm-config.yaml"
CONFIG_TMP="$(mktemp)"
trap 'rm -f "${CONFIG_TMP}"' EXIT

sed \
  -e "s/cp.example.com:6443/${CONTROL_PLANE_DNS}:6443/g" \
  -e "s/advertiseAddress: \"192.168.1.10\"/advertiseAddress: \"${CONTROL_PLANE_IP}\"/g" \
  "${CONFIG_SRC}" >"${CONFIG_TMP}"

log "=== kubeadm init (endpoint: ${CONTROL_PLANE_DNS}:6443, advertise: ${CONTROL_PLANE_IP}) ==="

if [[ -f /etc/kubernetes/admin.conf ]]; then
  warn "Cluster already initialized (/etc/kubernetes/admin.conf exists). Skipping kubeadm init."
else
  kubeadm init --config "${CONFIG_TMP}" --upload-certs
fi

# kubeconfig for admin user
ADMIN_USER="${SUDO_USER:-root}"
ADMIN_HOME="$(eval echo "~${ADMIN_USER}")"
mkdir -p "${ADMIN_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${ADMIN_HOME}/.kube/config"
chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.kube/config"
chmod 600 "${ADMIN_HOME}/.kube/config"

log "Control plane ready."
log "Next: run 05-install-cni.sh, then apply addons from kubeadm/addons/"
log "Worker join: sudo ./kubeadm/scripts/04-join-worker.sh --print-command"
