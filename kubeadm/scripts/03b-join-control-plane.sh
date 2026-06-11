#!/bin/bash
# 03b-join-control-plane.sh — HA control-plane join helper (stacked etcd)
# Usage on additional control-plane node (after 01-prerequisites + 02-install-kubeadm):
#   sudo ./kubeadm/scripts/03b-join-control-plane.sh --join 'kubeadm join ...' --certificate-key <key>
#   sudo ./kubeadm/scripts/03b-join-control-plane.sh --config /path/to/join-config.yaml
#
# The join command from the first CP must include --control-plane and --certificate-key,
# or pass --certificate-key to this script. See kubeadm/docs/ha-control-plane.md.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

print_usage() {
  cat <<'EOF'
HA control-plane join helper (stacked etcd, 3-node recommended)

Prerequisites on THIS node:
  - 01-prerequisites.sh and 02-install-kubeadm.sh already completed
  - Network reachability to controlPlaneEndpoint (VIP/DNS:6443)
  - Join token and CA cert hash from the first control-plane node

On the first control-plane (after init), retrieve certificate key:
  kubeadm init phase upload-certs --upload-certs
  # Output line: [upload-certs] Using certificate key: <key>

Generate a worker-style join command (token + hash):
  kubeadm token create --print-join-command

Join with flags (append --control-plane and --certificate-key):
  sudo ./kubeadm/scripts/03b-join-control-plane.sh \
    --join 'kubeadm join cp.example.com:6443 --token ... --discovery-token-ca-cert-hash sha256:...' \
    --certificate-key '<certificate-key>'

Equivalent one-liner (flags already in command):
  sudo ./kubeadm/scripts/03b-join-control-plane.sh --join \
    'kubeadm join cp.example.com:6443 --token ... --discovery-token-ca-cert-hash sha256:... \
     --control-plane --certificate-key <key>'

Or use join-config.yaml (copy kubeadm/join-config.yaml.example, fill controlPlane.certificateKey):
  sudo ./kubeadm/scripts/03b-join-control-plane.sh --config kubeadm/join-config.yaml

After join, copy admin kubeconfig from any existing CP node for kubectl access.
EOF
}

ensure_prerequisites() {
  command_exists kubeadm || die "kubeadm not found. Run 02-install-kubeadm.sh first."
  command_exists kubelet || die "kubelet not found. Run 02-install-kubeadm.sh first."
  if [[ -f /etc/kubernetes/kubelet.conf ]] && [[ ! -f /etc/kubernetes/admin.conf ]]; then
    warn "This node appears joined as a worker (/etc/kubernetes/kubelet.conf exists)."
    warn "HA control-plane join should be run on a fresh node (not an existing worker)."
  fi
}

append_cp_flags() {
  local cmd="$1"
  local cert_key="${2:-}"

  if [[ "${cmd}" != *"--control-plane"* ]]; then
    cmd="${cmd} --control-plane"
  fi
  if [[ -n "${cert_key}" && "${cmd}" != *"--certificate-key"* ]]; then
    cmd="${cmd} --certificate-key ${cert_key}"
  fi
  echo "${cmd}"
}

MODE="${1:-}"
CERTIFICATE_KEY="${CERTIFICATE_KEY:-}"

case "${MODE}" in
  --print-command|--help|-h)
    print_usage
    exit 0
    ;;
  --join)
    JOIN_CMD="${2:-}"
    [[ -n "${JOIN_CMD}" ]] || die "Provide join command: --join 'kubeadm join ...'"
    if [[ $# -ge 3 && "${3}" == "--certificate-key" ]]; then
      CERTIFICATE_KEY="${4:-}"
    fi
    [[ -n "${CERTIFICATE_KEY}" ]] || die "HA CP join requires --certificate-key (or set CERTIFICATE_KEY env)"
    ensure_prerequisites
    JOIN_CMD="$(append_cp_flags "${JOIN_CMD}" "${CERTIFICATE_KEY}")"
    log "Running: ${JOIN_CMD}"
    # shellcheck disable=SC2086
    eval "${JOIN_CMD}"
    log "Control-plane node joined."
    log "Next: copy admin.conf from an existing CP and verify: kubectl get nodes -l node-role.kubernetes.io/control-plane"
    ;;
  --config)
    JOIN_CFG="${2:-}"
    [[ -f "${JOIN_CFG}" ]] || die "Config not found: ${JOIN_CFG}"
    ensure_prerequisites
    if ! grep -q 'certificateKey:' "${JOIN_CFG}"; then
      die "HA CP join config must set controlPlane.certificateKey (see join-config.yaml.example)"
    fi
    log "Joining control-plane with config ${JOIN_CFG}"
    kubeadm join --config "${JOIN_CFG}"
    log "Control-plane node joined."
    log "Next: copy admin.conf from an existing CP and verify: kubectl get nodes -l node-role.kubernetes.io/control-plane"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
