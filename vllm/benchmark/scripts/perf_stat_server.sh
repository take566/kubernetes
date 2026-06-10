#!/usr/bin/env bash
# Profile the vLLM server process on a GPU node using Linux perf.
# Requires: privileged pod, hostPID, perf on host or in container.
#
# Usage (from benchmark perf Job or debug pod on same node as vllm):
#   VLLM_CONTAINER_NAME=vllm PERF_DURATION_S=30 ./perf_stat_server.sh
set -euo pipefail

OUTPUT_DIR="${PERF_OUTPUT_DIR:-/tmp/vllm-perf}"
mkdir -p "${OUTPUT_DIR}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

CONTAINER_NAME="${VLLM_CONTAINER_NAME:-vllm}"
DURATION_S="${PERF_DURATION_S:-30}"
MODE="${PERF_MODE:-stat}"  # stat | record

if ! command -v perf >/dev/null 2>&1; then
  echo "ERROR: perf not installed. Install linux-tools matching host kernel." >&2
  exit 1
fi

# Find vLLM api_server PID (container or host namespace)
find_vllm_pid() {
  if [[ -r /host/proc/1/cgroup ]]; then
    # hostPID pod: search host processes
    pgrep -f "vllm.entrypoints.openai.api_server" | head -1 || true
  else
    pgrep -f "vllm.entrypoints.openai.api_server" | head -1 || true
  fi
}

PID="$(find_vllm_pid)"
if [[ -z "${PID}" ]]; then
  echo "ERROR: vLLM api_server process not found" >&2
  exit 1
fi

echo "==> Target PID: ${PID} (container=${CONTAINER_NAME}, duration=${DURATION_S}s, mode=${MODE})"

case "${MODE}" in
  stat)
    OUT="${OUTPUT_DIR}/perf-stat-server-${TIMESTAMP}.txt"
    perf stat -d -p "${PID}" -- sleep "${DURATION_S}" 2>&1 | tee "${OUT}"
    echo "==> perf stat saved: ${OUT}"
    ;;
  record)
    OUT="${OUTPUT_DIR}/perf.data.server-${TIMESTAMP}"
    perf record -F 99 -g -p "${PID}" -- sleep "${DURATION_S}"
    perf script > "${OUTPUT_DIR}/perf.script.${TIMESTAMP}.txt"
    mv perf.data "${OUT}" 2>/dev/null || true
    echo "==> perf record saved: ${OUT}"
    echo "    Flamegraph (on workstation with Brendan Gregg tools):"
    echo "    stackcollapse-perf.pl perf.script.*.txt | flamegraph.pl > flame.svg"
    ;;
  *)
    echo "ERROR: unknown PERF_MODE=${MODE} (use stat or record)" >&2
    exit 1
    ;;
esac
