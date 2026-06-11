#!/usr/bin/env bash
# kubeadm-connect.sh — Fetch, merge, tunnel, and verify remote kubeadm cluster access (Linux/WSL)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACTION="${1:-status}"
KUBEADM_SSH_TARGET="${KUBEADM_SSH_TARGET:-}"
KUBEADM_CONTEXT_NAME="${KUBEADM_CONTEXT_NAME:-kubeadm-prod}"
KUBEADM_SERVER_URL="${KUBEADM_SERVER_URL:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
LOCAL_PORT="${LOCAL_PORT:-16443}"
REMOTE_HOST="${REMOTE_HOST:-127.0.0.1}"
REMOTE_PORT="${REMOTE_PORT:-6443}"
CONTEXT="${CONTEXT:-}"

KUBE_DIR="${HOME}/.kube"
MAIN_CONFIG="${KUBE_DIR}/config"
DEFAULT_KUBEADM_CONFIG="${KUBE_DIR}/config-kubeadm"

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./scripts/kubeadm-connect.sh status
  KUBEADM_SSH_TARGET=user@cp ./scripts/kubeadm-connect.sh fetch
  ./scripts/kubeadm-connect.sh merge [KUBECONFIG_PATH]
  KUBEADM_SSH_TARGET=user@cp ./scripts/kubeadm-connect.sh tunnel
  ./scripts/kubeadm-connect.sh verify

Environment:
  KUBEADM_SSH_TARGET    SSH target for fetch/tunnel (user@host)
  KUBEADM_CONTEXT_NAME  Context name after merge (default: kubeadm-prod)
  KUBEADM_SERVER_URL    Optional cluster server URL override after merge
  KUBECONFIG_PATH       Path to fetched/admin kubeconfig (default: ~/.kube/config-kubeadm)
  LOCAL_PORT            Local tunnel port (default: 16443)
  REMOTE_HOST           Remote tunnel host (default: 127.0.0.1)
  REMOTE_PORT           Remote API port (default: 6443)
  CONTEXT               Context for verify (default: KUBEADM_CONTEXT_NAME)
EOF
}

extract_control_plane_dns() {
  if [[ -n "${KUBEADM_SERVER_URL}" ]]; then
    echo "${KUBEADM_SERVER_URL}" | sed -E 's|https?://([^:/]+).*|\1|'
  elif [[ -n "${KUBEADM_SSH_TARGET}" ]]; then
    echo "${KUBEADM_SSH_TARGET}" | sed -E 's|.*@||' | sed -E 's|:.*||'
  else
    echo ""
  fi
}

do_merge() {
  local src="${KUBECONFIG_PATH:-${DEFAULT_KUBEADM_CONFIG}}"
  [[ -f "${src}" ]] || die "Kubeconfig not found: ${src}"

  mkdir -p "${KUBE_DIR}"
  if [[ -f "${MAIN_CONFIG}" ]]; then
    local backup="${MAIN_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "${MAIN_CONFIG}" "${backup}"
    printf 'Backup: %s\n' "${backup}"
  fi

  if [[ -f "${MAIN_CONFIG}" ]]; then
    export KUBECONFIG="${MAIN_CONFIG}:${src}"
  else
    export KUBECONFIG="${src}"
  fi
  kubectl config view --flatten >"${MAIN_CONFIG}.tmp"
  mv -f "${MAIN_CONFIG}.tmp" "${MAIN_CONFIG}"
  chmod 600 "${MAIN_CONFIG}"
  unset KUBECONFIG

  local src_ctx
  src_ctx="$(kubectl config get-contexts -o name | grep -m1 'kubernetes-admin' || true)"
  if [[ -z "${src_ctx}" ]]; then
    src_ctx="$(kubectl config get-contexts -o name | grep -Ev '^(kind-dev|awx)$' | head -n1 || true)"
  fi

  if [[ -n "${src_ctx}" && "${src_ctx}" != "${KUBEADM_CONTEXT_NAME}" ]]; then
    if ! kubectl config rename-context "${src_ctx}" "${KUBEADM_CONTEXT_NAME}" 2>/dev/null; then
      printf 'Context rename skipped (may already be %s)\n' "${KUBEADM_CONTEXT_NAME}"
    fi
  fi

  if [[ -n "${KUBEADM_SERVER_URL}" ]]; then
    local cluster
    cluster="$(kubectl config view -o "jsonpath={.contexts[?(@.name==\"${KUBEADM_CONTEXT_NAME}\")].context.cluster}")"
    [[ -n "${cluster}" ]] || die "Cluster for context ${KUBEADM_CONTEXT_NAME} not found"
    kubectl config set-cluster "${cluster}" --server="${KUBEADM_SERVER_URL}"
  fi

  kubectl config use-context "${KUBEADM_CONTEXT_NAME}"
  printf 'Merged into %s; current context: %s\n' "${MAIN_CONFIG}" "${KUBEADM_CONTEXT_NAME}"
}

do_fetch() {
  [[ -n "${KUBEADM_SSH_TARGET}" ]] || die "Set KUBEADM_SSH_TARGET (user@host)"

  local dest="${KUBECONFIG_PATH:-${DEFAULT_KUBEADM_CONFIG}}"
  local remote_tmp="/tmp/kubeadm-export-$$.conf"
  local export_script="${REPO_ROOT}/kubeadm/scripts/08-export-kubeconfig.sh"
  local cp_dns
  cp_dns="$(extract_control_plane_dns)"
  [[ -f "${export_script}" ]] || die "Missing export script: ${export_script}"
  [[ -n "${cp_dns}" ]] || die "Could not determine CONTROL_PLANE_DNS; set KUBEADM_SERVER_URL"

  mkdir -p "${KUBE_DIR}"

  scp -q "${export_script}" "${KUBEADM_SSH_TARGET}:/tmp/08-export-kubeconfig.sh"
  ssh "${KUBEADM_SSH_TARGET}" \
    "chmod +x /tmp/08-export-kubeconfig.sh && sudo CONTROL_PLANE_DNS='${cp_dns}' /tmp/08-export-kubeconfig.sh '${remote_tmp}' && rm -f /tmp/08-export-kubeconfig.sh"

  ssh "${KUBEADM_SSH_TARGET}" "sudo cat '${remote_tmp}'" >"${dest}.tmp"
  ssh "${KUBEADM_SSH_TARGET}" "sudo rm -f '${remote_tmp}'"
  mv -f "${dest}.tmp" "${dest}"
  chmod 600 "${dest}"

  printf 'Fetched kubeconfig to %s\n' "${dest}"
  KUBECONFIG_PATH="${dest}"
  do_merge
}

do_status() {
  log 'kubectl contexts'
  kubectl config get-contexts || true
  log 'Notes'
  printf '%s\n' 'awx context = minikube profile (not kubeadm). See docs/kubeadm-connect.md'
  if [[ -f "${DEFAULT_KUBEADM_CONFIG}" ]]; then
    printf 'Found: %s\n' "${DEFAULT_KUBEADM_CONFIG}"
  else
    printf 'Missing: %s (run fetch or scp from control-plane admin.conf)\n' "${DEFAULT_KUBEADM_CONFIG}"
  fi
  local ctx
  for ctx in awx kind-dev "${KUBEADM_CONTEXT_NAME}"; do
    [[ -n "${ctx}" ]] || continue
    printf '\n--- cluster-info: %s ---\n' "${ctx}"
    if kubectl --context="${ctx}" cluster-info 2>/dev/null | head -n 3; then
      :
    else
      printf '  unreachable\n'
    fi
  done
}

do_tunnel() {
  [[ -n "${KUBEADM_SSH_TARGET}" ]] || die "Set KUBEADM_SSH_TARGET (user@host)"
  printf 'Starting SSH tunnel: localhost:%s -> %s:%s via %s\n' \
    "${LOCAL_PORT}" "${REMOTE_HOST}" "${REMOTE_PORT}" "${KUBEADM_SSH_TARGET}"
  printf '%s\n' 'Leave this terminal open. Use Ctrl+C to stop.'
  exec ssh -N -L "${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT}" "${KUBEADM_SSH_TARGET}"
}

do_verify() {
  local use_ctx="${CONTEXT:-${KUBEADM_CONTEXT_NAME}}"
  log "nodes (${use_ctx})"
  kubectl --context="${use_ctx}" get nodes -o wide
  log 'GPU allocatable (nvidia.com/gpu, amd.com/gpu)'
  kubectl --context="${use_ctx}" get nodes -o custom-columns=NAME:.metadata.name,NVIDIA_GPU:.status.allocatable.nvidia\.com/gpu,AMD_GPU:.status.allocatable.amd\.com/gpu
  log 'nvidia device plugin pods'
  if ! kubectl --context="${use_ctx}" get pods -A -l app=nvidia-device-plugin-daemonset 2>/dev/null; then
    printf '%s\n' 'No nvidia-device-plugin pods found (label may differ or addon not applied).'
  fi
  log 'amdgpu device plugin pods'
  if ! kubectl --context="${use_ctx}" get pods -A -l name=amdgpu-dp-ds 2>/dev/null; then
    printf '%s\n' 'No amdgpu-dp-ds pods found (label may differ or addon not applied).'
  fi
}

case "${ACTION}" in
  status)
    do_status
    ;;
  fetch)
    do_fetch
    ;;
  merge)
    if [[ -n "${2:-}" ]]; then
      KUBECONFIG_PATH="$2"
    fi
    do_merge
    ;;
  tunnel)
    do_tunnel
    ;;
  verify)
    do_verify
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    die "Unknown action: ${ACTION}"
    ;;
esac
