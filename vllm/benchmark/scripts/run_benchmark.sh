#!/usr/bin/env bash
# Run vLLM API benchmark and optionally wrap with Linux perf stat.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${BENCH_OUTPUT_DIR:-/tmp/vllm-bench}"
mkdir -p "${OUTPUT_DIR}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_FILE="${OUTPUT_DIR}/benchmark-${TIMESTAMP}.json"
PERF_FILE="${OUTPUT_DIR}/perf-stat-${TIMESTAMP}.txt"

echo "==> vLLM benchmark starting at ${TIMESTAMP}"
echo "    base_url=${VLLM_BASE_URL:-http://vllm.vllm.svc.cluster.local:8000}"
echo "    model=${VLLM_MODEL:-facebook/opt-125m}"

run_bench() {
  python3 "${SCRIPT_DIR}/bench_vllm.py" "$@" | tee "${RESULT_FILE}"
}

if [[ "${PERF_ENABLE:-false}" == "true" ]] && command -v perf >/dev/null 2>&1; then
  echo "==> Running benchmark under perf stat"
  # -d duplicates counters; adjust for your kernel/CPU
  perf stat -d -o "${PERF_FILE}" -- \
    python3 "${SCRIPT_DIR}/bench_vllm.py" "$@" | tee "${RESULT_FILE}"
  echo "==> perf stat written to ${PERF_FILE}"
  cat "${PERF_FILE}"
else
  if [[ "${PERF_ENABLE:-false}" == "true" ]]; then
    echo "WARN: PERF_ENABLE=true but perf not found; running without perf" >&2
  fi
  run_bench "$@"
fi

echo "==> Benchmark JSON: ${RESULT_FILE}"
