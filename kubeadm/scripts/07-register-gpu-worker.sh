#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NODE_NAME=""
VENDOR=""
APPLY_VLLM=false
OVERLAY="kubeadm/amd"
TIMEOUT_SEC="${TIMEOUT_SEC:-120}"

log() { printf '==> %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  kubeadm/scripts/07-register-gpu-worker.sh --node <name> --vendor amd|nvidia [--apply-vllm] [--overlay kubeadm/amd]

Examples:
  ./kubeadm/scripts/07-register-gpu-worker.sh --node gpu-worker-01 --vendor amd
  ./kubeadm/scripts/07-register-gpu-worker.sh --node gpu-worker-01 --vendor amd --apply-vllm --overlay kubeadm/amd
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      NODE_NAME="${2:-}"
      shift 2
      ;;
    --vendor)
      VENDOR="${2:-}"
      shift 2
      ;;
    --apply-vllm)
      APPLY_VLLM=true
      shift
      ;;
    --overlay)
      OVERLAY="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${NODE_NAME}" ]] || die "Missing --node"
[[ "${VENDOR}" == "amd" || "${VENDOR}" == "nvidia" ]] || die "Missing/invalid --vendor amd|nvidia"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

if [[ "${VENDOR}" == "amd" ]]; then
  RESOURCE_KEY="amd.com/gpu"
  PRESENT_LABEL="amd.com/gpu.present=true"
  WORKLOAD_LABEL="workload=vllm-amd"
  PLUGIN_PATH="${REPO_ROOT}/kubeadm/addons/amd-gpu-device-plugin/"
  PLUGIN_SELECTOR="-l name=amdgpu-dp-ds"
else
  RESOURCE_KEY="nvidia.com/gpu"
  PRESENT_LABEL="nvidia.com/gpu.present=true"
  WORKLOAD_LABEL="workload=vllm-nvidia"
  PLUGIN_PATH="${REPO_ROOT}/kubeadm/addons/nvidia-device-plugin/"
  PLUGIN_SELECTOR="-l app=nvidia-device-plugin-daemonset"
fi

[[ -d "${PLUGIN_PATH}" ]] || die "Plugin path not found: ${PLUGIN_PATH}"

log "Applying ${VENDOR} device plugin"
kubectl apply -k "${PLUGIN_PATH}"

log "Labeling node ${NODE_NAME}"
kubectl label node "${NODE_NAME}" "${PRESENT_LABEL}" --overwrite
kubectl label node "${NODE_NAME}" "${WORKLOAD_LABEL}" --overwrite

log "Waiting for ${RESOURCE_KEY} allocatable (${TIMEOUT_SEC}s)"
RESOURCE_ESCAPED="${RESOURCE_KEY/\//\\.}"
max_retry=$(( TIMEOUT_SEC / 5 ))
if (( max_retry < 1 )); then
  max_retry=1
fi

for _ in $(seq 1 "${max_retry}"); do
  ALLOCATABLE_GPU="$(kubectl get node "${NODE_NAME}" -o jsonpath="{.status.allocatable.${RESOURCE_ESCAPED}}" 2>/dev/null || true)"
  if [[ -n "${ALLOCATABLE_GPU}" && "${ALLOCATABLE_GPU}" != "0" ]]; then
    log "${RESOURCE_KEY} allocatable on ${NODE_NAME}: ${ALLOCATABLE_GPU}"
    break
  fi
  sleep 5
done

ALLOCATABLE_GPU="$(kubectl get node "${NODE_NAME}" -o jsonpath="{.status.allocatable.${RESOURCE_ESCAPED}}" 2>/dev/null || true)"
if [[ -z "${ALLOCATABLE_GPU}" || "${ALLOCATABLE_GPU}" == "0" ]]; then
  warn "${RESOURCE_KEY} is not allocatable on ${NODE_NAME}"
  warn "Device plugin pods:"
  kubectl get pods -A ${PLUGIN_SELECTOR} || true
  warn "Node resources:"
  kubectl describe node "${NODE_NAME}" | sed -n '1,140p' || true
  die "GPU is not allocatable. Check host driver/ROCm(or NVIDIA) install, then retry."
fi

if [[ "${APPLY_VLLM}" == true ]]; then
  OVERLAY_PATH="${REPO_ROOT}/vllm/overlays/${OVERLAY}"
  [[ -d "${OVERLAY_PATH}" ]] || die "Overlay path not found: ${OVERLAY_PATH}"
  log "Applying vLLM overlay: vllm/overlays/${OVERLAY}/"
  kubectl kustomize "${OVERLAY_PATH}" --load-restrictor LoadRestrictionsNone | kubectl apply -f -
fi

log "Done. ${NODE_NAME} registered as ${VENDOR} GPU worker."
