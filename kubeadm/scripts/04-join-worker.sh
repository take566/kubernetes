#!/bin/bash
# 04-join-worker.sh — worker node join helper
# Usage on worker (after 01 + 02 on this node):
#   sudo ./kubeadm/scripts/04-join-worker.sh --print-command   # show instructions
#   sudo ./kubeadm/scripts/04-join-worker.sh --join 'kubeadm join ...'  # run join
#   sudo ./kubeadm/scripts/04-join-worker.sh --config /path/to/join-config.yaml

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

print_usage() {
  cat <<'EOF'
Worker node join helper

On the control plane, generate a join command:
  kubeadm token create --print-join-command

For control-plane nodes (HA), also upload certs:
  kubeadm init phase upload-certs --upload-certs

Then on this worker:
  sudo ./kubeadm/scripts/04-join-worker.sh --join '<paste join command>'

Or use a filled join-config.yaml (copy from kubeadm/join-config.yaml.example):
  sudo ./kubeadm/scripts/04-join-worker.sh --config kubeadm/join-config.yaml

Optional GPU node labels (run after join, from admin kubeconfig):
  kubectl label node <node> nvidia.com/gpu.present=true
  kubectl label node <node> amd.com/gpu.present=true
  kubectl taint nodes <node> nvidia.com/gpu=:NoSchedule   # optional dedicated GPU
EOF
}

MODE="${1:-}"
case "${MODE}" in
  --print-command|--help|-h)
    print_usage
    exit 0
    ;;
  --join)
    JOIN_CMD="${2:-}"
    [[ -n "${JOIN_CMD}" ]] || die "Provide join command: --join 'kubeadm join ...'"
    log "Running: ${JOIN_CMD}"
    # shellcheck disable=SC2086
    eval "${JOIN_CMD}"
    log "Worker joined."
    ;;
  --config)
    JOIN_CFG="${2:-}"
    [[ -f "${JOIN_CFG}" ]] || die "Config not found: ${JOIN_CFG}"
    log "Joining with config ${JOIN_CFG}"
    kubeadm join --config "${JOIN_CFG}"
    log "Worker joined."
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
