#!/bin/bash
# 08-export-kubeconfig.sh — Export admin kubeconfig with client-facing API URL (control-plane only)
# Usage:
#   export CONTROL_PLANE_DNS=cp.example.com
#   sudo ./kubeadm/scripts/08-export-kubeconfig.sh /tmp/kubeconfig-export.conf
#
# Does not print certificate or token contents.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

OUTPUT_PATH="${1:-${OUTPUT_PATH:-}}"
CONTROL_PLANE_DNS="${CONTROL_PLANE_DNS:-}"
ADMIN_SRC="/etc/kubernetes/admin.conf"

usage() {
  cat <<'EOF'
Usage:
  sudo CONTROL_PLANE_DNS=cp.example.com ./kubeadm/scripts/08-export-kubeconfig.sh OUTPUT_PATH

Environment:
  CONTROL_PLANE_DNS  API hostname clients should use (default: hostname -f)
  OUTPUT_PATH        Destination file (may also be passed as first argument)
EOF
}

if [[ -z "${OUTPUT_PATH}" ]]; then
  usage >&2
  die "OUTPUT_PATH is required."
fi

if [[ ! -f "${ADMIN_SRC}" ]]; then
  die "${ADMIN_SRC} not found. Run 03-init-control-plane.sh first."
fi

if [[ -z "${CONTROL_PLANE_DNS}" ]]; then
  CONTROL_PLANE_DNS="$(hostname -f 2>/dev/null || hostname)"
  warn "CONTROL_PLANE_DNS not set; using ${CONTROL_PLANE_DNS}"
fi

SERVER_URL="https://${CONTROL_PLANE_DNS}:6443"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
cp -f "${ADMIN_SRC}" "${OUTPUT_PATH}"
chmod 600 "${OUTPUT_PATH}"

# Rewrite clusters[].cluster.server without echoing secret fields.
sed -i -E "s|^[[:space:]]*server:[[:space:]]*https?://[^[:space:]]+|    server: ${SERVER_URL}|" "${OUTPUT_PATH}"

log "Exported kubeconfig to ${OUTPUT_PATH} (server: ${SERVER_URL})"
