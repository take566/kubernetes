#!/usr/bin/env bash
# Benchmark vLLM CPU on macOS via Docker (openeuler/vllm-cpu).
# Replaces kind/kubectl when those tools are unavailable locally.
#
# Usage:
#   ./scripts/bench_vllm_macos_cpu.sh                    # default model set
#   MODELS="facebook/opt-125m Qwen/Qwen2.5-0.5B-Instruct" ./scripts/bench_vllm_macos_cpu.sh
#   VLLM_CPU_IMAGE=openeuler/vllm-cpu:0.20.1-oe2403sp3 ./scripts/bench_vllm_macos_cpu.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_PY="${REPO_ROOT}/vllm/benchmark/scripts/bench_vllm.py"
RESULTS_DIR="${REPO_ROOT}/vllm/benchmark/results"
CONTAINER_NAME="${VLLM_CPU_CONTAINER:-vllm-cpu-bench}"
CPU_IMAGE="${VLLM_CPU_IMAGE:-openeuler/vllm-cpu:0.20.1-oe2403sp3}"
HOST_PORT="${VLLM_HOST_PORT:-8000}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"

# CPU-tuned flags (aligned with vllm/overlays/kind/cpu/model-patch.yaml; v0.20 drops --device)
VLLM_CPU_ARGS=(
  --dtype float16
  --max-num-seqs 2
  --max-model-len 1024
  --max-num-batched-tokens 512
  --enforce-eager
)

DEFAULT_MODELS=(
  "facebook/opt-125m"
  "Qwen/Qwen2.5-0.5B-Instruct"
  "LiquidAI/LFM2.5-350M"
  "Qwen/Qwen2.5-1.5B-Instruct"
)

if [[ -n "${MODELS:-}" ]]; then
  # shellcheck disable=SC2206
  CANDIDATES=(${MODELS})
else
  CANDIDATES=("${DEFAULT_MODELS[@]}")
fi

BENCH_LATENCY_SAMPLES="${BENCH_LATENCY_SAMPLES:-10}"
BENCH_THROUGHPUT_REQUESTS="${BENCH_THROUGHPUT_REQUESTS:-20}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-2}"
BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS:-64}"
BENCH_HEALTH_TIMEOUT_S="${BENCH_HEALTH_TIMEOUT_S:-900}"
READY_POLL_S="${READY_POLL_S:-15}"
READY_MAX_ATTEMPTS="${READY_MAX_ATTEMPTS:-120}"

mkdir -p "${RESULTS_DIR}"

stop_container() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  sleep 3
}

wait_ready() {
  local attempt
  for attempt in $(seq 1 "${READY_MAX_ATTEMPTS}"); do
    if curl -sf "${BASE_URL}/health" >/dev/null 2>&1; then
      echo "  ready (${attempt} polls)"
      return 0
    fi
    local cstate
    cstate="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo missing)"
    if [[ "${cstate}" == "exited" ]]; then
      echo "  ERROR: container exited during startup" >&2
      docker logs "${CONTAINER_NAME}" 2>&1 | tail -40 >&2
      return 1
    fi
    sleep "${READY_POLL_S}"
  done
  echo "  ERROR: health timeout after $((READY_MAX_ATTEMPTS * READY_POLL_S))s" >&2
  docker logs "${CONTAINER_NAME}" 2>&1 | tail -40 >&2
  return 1
}

start_model() {
  local model="$1"
  echo ""
  echo "=== Deploy ${model} ==="
  stop_container
  docker run -d --name "${CONTAINER_NAME}" \
    -p "${HOST_PORT}:8000" \
    --memory 10g \
    --cpus 4 \
    -e VLLM_DEVICE=cpu \
    -e VLLM_CPU_KVCACHE_SPACE=2 \
    "${CPU_IMAGE}" \
    --model "${model}" \
    --host 0.0.0.0 \
    --port 8000 \
    "${VLLM_CPU_ARGS[@]}" >/dev/null
  wait_ready
}

safe_name() {
  echo "$1" | tr '/:' '__'
}

run_bench() {
  local model="$1"
  local ts out
  ts="$(date -u +%Y-%m-%dT%H%M%SZ)"
  out="${RESULTS_DIR}/bench-vllm-cpu-$(safe_name "${model}")-${ts}.json"

  echo "=== Benchmark ${model} ==="
  VLLM_BASE_URL="${BASE_URL}" \
  VLLM_MODEL="${model}" \
  BENCH_LATENCY_SAMPLES="${BENCH_LATENCY_SAMPLES}" \
  BENCH_THROUGHPUT_REQUESTS="${BENCH_THROUGHPUT_REQUESTS}" \
  BENCH_CONCURRENCY="${BENCH_CONCURRENCY}" \
  BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS}" \
  BENCH_HEALTH_TIMEOUT_S="${BENCH_HEALTH_TIMEOUT_S}" \
    python3 "${BENCH_PY}" \
      --base-url "${BASE_URL}" \
      --model "${model}" \
      --latency-samples "${BENCH_LATENCY_SAMPLES}" \
      --throughput-requests "${BENCH_THROUGHPUT_REQUESTS}" \
      --concurrency "${BENCH_CONCURRENCY}" \
      --max-tokens "${BENCH_MAX_TOKENS}" \
      --health-timeout "${BENCH_HEALTH_TIMEOUT_S}" \
      | tee "${out}"

  if ! python3 -c "import json; json.load(open('${out}'))" 2>/dev/null; then
    echo "  ERROR: benchmark produced no JSON for ${model}" >&2
    rm -f "${out}"
    return 1
  fi

  # Tag backend in result
  VLLM_CPU_IMAGE="${CPU_IMAGE}" python3 - "${out}" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path))
data["backend"] = "vllm-cpu-docker"
data["image"] = os.environ.get("VLLM_CPU_IMAGE", "openeuler/vllm-cpu:0.20.1-oe2403sp3")
data["platform"] = "macos-arm64"
json.dump(data, open(path, "w"), indent=2)
print(f"  saved: {path}")
PY
}

trap stop_container EXIT

echo "vLLM macOS CPU benchmark"
echo "  image=${CPU_IMAGE}"
echo "  models=${#CANDIDATES[@]}"
echo "  results=${RESULTS_DIR}"

FAILED=()
for model in "${CANDIDATES[@]}"; do
  if ! start_model "${model}"; then
    FAILED+=("${model}:deploy")
    continue
  fi
  if ! run_bench "${model}"; then
    FAILED+=("${model}:bench")
  fi
done

echo ""
echo "=== Summary ==="
python3 - <<'PY' "${RESULTS_DIR}"
import glob, json, os, sys
results = sorted(glob.glob(os.path.join(sys.argv[1], "bench-vllm-cpu-*.json")))
print(f"{'Model':<45} {'p50_ms':>8} {'p99_ms':>8} {'tok/s':>8} {'req/s':>8}")
print("-" * 85)
for path in results:
    try:
        d = json.load(open(path))
    except Exception:
        continue
    lat = d.get("latency") or {}
    thr = d.get("throughput") or {}
    print(
        f"{d.get('model','?'):<45} "
        f"{lat.get('p50_ms', 'n/a'):>8} "
        f"{lat.get('p99_ms', 'n/a'):>8} "
        f"{thr.get('output_tokens_per_second', 'n/a'):>8} "
        f"{thr.get('requests_per_second', 'n/a'):>8}"
    )
PY

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "Failures: ${FAILED[*]}"
  exit 1
fi

echo ""
echo "Done."
