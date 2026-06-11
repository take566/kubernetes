#!/bin/bash
# Unified kubeadm cluster bootstrap entrypoint.
# Orchestrates scripts in kubeadm/scripts/ for init or worker join.
#
# Make executable: chmod +x kubeadm/bootstrap.sh
#
# Usage:
#   sudo ./kubeadm/bootstrap.sh --role init
#   sudo ./kubeadm/bootstrap.sh --role init --with-cni cilium --with-nvidia
#   sudo ./kubeadm/bootstrap.sh --role join-worker --join-command 'kubeadm join ...'
#   sudo ./kubeadm/bootstrap.sh --role init --dry-run
#   sudo ./kubeadm/bootstrap.sh --role init --skip-prerequisites

set -euo pipefail

KUBEADM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${KUBEADM_DIR}/scripts"
# shellcheck source=scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

ROLE=""
JOIN_COMMAND=""
DRY_RUN=false
SKIP_PREREQUISITES=false
WITH_NVIDIA=false
WITH_AMD=false
ADDON_ARGS=()

print_usage() {
  cat <<EOF
Unified kubeadm bootstrap

Usage:
  sudo ./kubeadm/bootstrap.sh --role init [options]
  sudo ./kubeadm/bootstrap.sh --role join-worker --join-command '<cmd>' [options]
  sudo ./kubeadm/bootstrap.sh --role join-cp [options]

Roles:
  init         First control-plane: 01 → 02 → 03 → 05 (CNI) → addons
  join-worker  Worker node: 01 → 02 → 04 (requires --join-command)
  join-cp      Stub — HA control-plane join (see 03b script, future)

Options:
  --with-cni calico|cilium   CNI plugin (default: calico, init only)
  --with-nvidia              Apply NVIDIA device plugin addon (init only)
  --with-amd                 Apply AMD GPU device plugin addon (init only)
  --join-command '<cmd>'     kubeadm join command (join-worker only)
  --skip-prerequisites       Skip 01-prerequisites.sh
  --dry-run                  Print phases without executing
  -h, --help                 Show this help

Environment (see scripts/common.sh):
  K8S_VERSION, CONTROL_PLANE_IP, CONTROL_PLANE_DNS, CNI, POD_SUBNET, ...
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      ROLE="${2:-}"
      shift 2
      ;;
    --join-command)
      JOIN_COMMAND="${2:-}"
      shift 2
      ;;
    --with-cni)
      export CNI="${2:-}"
      shift 2
      ;;
    --with-nvidia)
      WITH_NVIDIA=true
      ADDON_ARGS+=(--with-nvidia)
      shift
      ;;
    --with-amd)
      WITH_AMD=true
      ADDON_ARGS+=(--with-amd)
      shift
      ;;
    --skip-prerequisites)
      SKIP_PREREQUISITES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (try --help)"
      ;;
  esac
done

[[ -n "${ROLE}" ]] || die "Missing --role (init|join-worker|join-cp)"

case "${CNI}" in
  calico|cilium) ;;
  *) die "Invalid CNI=${CNI}. Use calico or cilium." ;;
esac

run_phase() {
  local name="$1"
  shift
  log "=== Phase: ${name} ==="
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] ${*}"
    return 0
  fi
  if "$@"; then
    log "Phase OK: ${name}"
    return 0
  fi
  local ec=$?
  echo "[ERROR] Phase failed: ${name} (exit ${ec})" >&2
  exit "${ec}"
}

if [[ "${DRY_RUN}" != true ]]; then
  require_root
fi

log "=== kubeadm bootstrap (role=${ROLE}, cni=${CNI}, dry-run=${DRY_RUN}) ==="

run_prerequisites() {
  if [[ "${SKIP_PREREQUISITES}" == true ]]; then
    log "Skipping prerequisites (--skip-prerequisites)"
    return 0
  fi
  run_phase "01-prerequisites" "${SCRIPTS_DIR}/01-prerequisites.sh"
}

run_install_kubeadm() {
  run_phase "02-install-kubeadm" "${SCRIPTS_DIR}/02-install-kubeadm.sh"
}

role_init() {
  run_prerequisites
  run_install_kubeadm
  run_phase "03-init-control-plane" "${SCRIPTS_DIR}/03-init-control-plane.sh"
  run_phase "05-install-cni" "${SCRIPTS_DIR}/05-install-cni.sh"
  run_phase "apply-addons" "${KUBEADM_DIR}/addons/apply-addons.sh" "${ADDON_ARGS[@]}"
  log "=== Bootstrap complete (init) ==="
  log "Next: join workers with --role join-worker, then ./scripts/bootstrap.sh for Argo CD"
}

role_join_worker() {
  [[ -n "${JOIN_COMMAND}" ]] || die "join-worker requires --join-command '<kubeadm join ...>'"
  run_prerequisites
  run_install_kubeadm
  run_phase "04-join-worker" "${SCRIPTS_DIR}/04-join-worker.sh" --join "${JOIN_COMMAND}"
  log "=== Bootstrap complete (join-worker) ==="
}

role_join_cp() {
  log "=== join-cp (stub) ==="
  echo "[INFO] HA control-plane join is not implemented in this MVP." >&2
  echo "[INFO] Planned script: kubeadm/scripts/03b-join-control-plane.sh" >&2
  echo "[INFO] Until then, use kubeadm join with --control-plane and --certificate-key from the first CP node." >&2
  exit 2
}

case "${ROLE}" in
  init) role_init ;;
  join-worker) role_join_worker ;;
  join-cp) role_join_cp ;;
  *) die "Invalid --role=${ROLE}. Use init, join-worker, or join-cp." ;;
esac

exit 0
