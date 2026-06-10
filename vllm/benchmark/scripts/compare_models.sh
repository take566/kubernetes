#!/usr/bin/env bash
# Compare vLLM inference models by redeploying each candidate and running bench_vllm.py.
# Requires: kubectl, cluster with vllm namespace, GPU node for production-sized models.
#
# Usage:
#   ./vllm/benchmark/scripts/compare_models.sh
#   MODELS="Qwen/Qwen2.5-0.5B-Instruct Qwen/Qwen2.5-1.5B-Instruct" ./vllm/benchmark/scripts/compare_models.sh
#   COMPARE_SET=extended ./vllm/benchmark/scripts/compare_models.sh
#   COMPARE_PROFILES=vllm/benchmark/model-profiles.json ./vllm/benchmark/scripts/compare_models.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-vllm}"
DEPLOYMENT="${DEPLOYMENT:-vllm}"
OVERLAY="${OVERLAY:-kubeadm}"
RESULTS_DIR="${RESULTS_DIR:-./vllm-bench-results}"
BENCH_KUSTOMIZE="${BENCH_KUSTOMIZE:-vllm/benchmark}"
HEALTH_TIMEOUT="${BENCH_HEALTH_TIMEOUT_S:-900}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-false}"
COMPARE_PROFILES="${COMPARE_PROFILES:-vllm/benchmark/model-profiles.json}"
FAILED=0

DEFAULT_MODELS=(
  "facebook/opt-125m"
  "Qwen/Qwen2.5-0.5B-Instruct"
  "Qwen/Qwen2.5-1.5B-Instruct"
)

EXTENDED_MODELS=(
  "LiquidAI/LFM2.5-350M"
  "LiquidAI/LFM2.5-1.2B-Instruct"
  "Qwen/Qwen2.5-1.5B-Instruct"
  "Qwen/Qwen3.6-35B-A3B"
  "google/gemma-4-E2B-it"
  "google/gemma-4-E4B-it"
)

declare -A MODEL_EXTRA_ARGS=()

load_profiles() {
  local profiles_file="$1"
  [[ -f "${profiles_file}" ]] || return 0
  while IFS=$'\t' read -r mid args; do
    [[ -n "${mid}" ]] && MODEL_EXTRA_ARGS["${mid}"]="${args}"
  done < <(python3 - <<'PY' "${profiles_file}"
import json, sys
for p in json.load(open(sys.argv[1])):
    print(f"{p['id']}\t{p.get('extra_args','')}")
PY
)
}

if [[ -n "${MODELS:-}" ]]; then
  # shellcheck disable=SC2206
  CANDIDATES=(${MODELS})
elif [[ "${COMPARE_SET:-}" == "extended" ]]; then
  CANDIDATES=("${EXTENDED_MODELS[@]}")
elif [[ "${COMPARE_SET:-}" == "all" ]]; then
  CANDIDATES=("${DEFAULT_MODELS[@]}" "${EXTENDED_MODELS[@]}")
else
  CANDIDATES=("${DEFAULT_MODELS[@]}")
fi

load_profiles "${COMPARE_PROFILES}"

mkdir -p "${RESULTS_DIR}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESULTS_DIR}/compare-${RUN_ID}"
mkdir -p "${RUN_DIR}"

echo "=== vLLM model comparison ==="
echo "namespace=${NAMESPACE} overlay=${OVERLAY} candidates=${#CANDIDATES[@]}"
echo "results=${RUN_DIR}"

patch_model() {
  local model="$1"
  local extra_args="${MODEL_EXTRA_ARGS[${model}]:-}"
  echo ""
  echo "--- Patching VLLM_MODEL -> ${model} ---"
  if [[ -n "${extra_args}" ]]; then
    echo "    extra_args=${extra_args}"
    kubectl -n "${NAMESPACE}" patch configmap vllm-config \
      --type merge \
      -p "$(python3 - <<'PY' "${model}" "${extra_args}"
import json, sys
model, extra = sys.argv[1], sys.argv[2]
print(json.dumps({"data": {"VLLM_MODEL": model, "VLLM_EXTRA_ARGS": extra}}))
PY
)"
  else
    kubectl -n "${NAMESPACE}" patch configmap vllm-config \
      --type merge \
      -p "{\"data\":{\"VLLM_MODEL\":\"${model}\"}}"
  fi
  kubectl -n "${NAMESPACE}" rollout restart "deployment/${DEPLOYMENT}"
  kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout="${HEALTH_TIMEOUT}s"
}

run_benchmark() {
  local model="$1"
  local safe_name
  safe_name="$(echo "${model}" | tr '/:' '__')"
  local out="${RUN_DIR}/${safe_name}.json"
  local meta="${RUN_DIR}/${safe_name}.meta.json"

  echo "--- Benchmark: ${model} ---"
  kubectl -n "${NAMESPACE}" delete job vllm-benchmark --ignore-not-found
  kubectl apply -k "${BENCH_KUSTOMIZE}"
  kubectl -n "${NAMESPACE}" patch configmap vllm-benchmark-config \
    --type merge \
    -p "{\"data\":{\"VLLM_MODEL\":\"${model}\"}}" || true
  kubectl -n "${NAMESPACE}" wait --for=condition=complete job/vllm-benchmark --timeout=25m
  kubectl -n "${NAMESPACE}" logs job/vllm-benchmark > "${out}"
  local profile_args="${MODEL_EXTRA_ARGS[${model}]:-}"
  python3 - <<'PY' "${model}" "${profile_args}" "${meta}"
import json, sys
from datetime import datetime, timezone
payload = {
    "model": sys.argv[1],
    "extra_args": sys.argv[2],
    "recorded_at": datetime.now(timezone.utc).isoformat(),
}
json.dump(payload, open(sys.argv[3], "w"), indent=2)
PY
  echo "  saved: ${out}"
}

summary_line() {
  local file="$1"
  python3 - <<'PY' "${file}" 2>/dev/null || echo "  (parse failed) ${file}"
import json, sys
data = json.load(open(sys.argv[1]))
lat = data.get("latency") or {}
thr = data.get("throughput") or {}
print(
    f"  model={data.get('model')} "
    f"p50={lat.get('p50_ms')}ms p99={lat.get('p99_ms')}ms "
    f"tok/s={thr.get('output_tokens_per_second')}"
)
PY
}

for model in "${CANDIDATES[@]}"; do
  if ! patch_model "${model}"; then
    echo "  WARN: deploy failed for ${model}"
    FAILED=$((FAILED + 1))
    [[ "${CONTINUE_ON_ERROR}" == "true" ]] && continue || exit 1
  fi
  if ! run_benchmark "${model}"; then
    echo "  WARN: benchmark failed for ${model}"
    FAILED=$((FAILED + 1))
    [[ "${CONTINUE_ON_ERROR}" == "true" ]] && continue || exit 1
  fi
done

echo ""
echo "=== Summary ==="
for f in "${RUN_DIR}"/*.json; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == *.meta.json ]] && continue
  summary_line "$f"
done

echo ""
if [[ "${FAILED}" -gt 0 ]]; then
  echo "Completed with ${FAILED} failure(s). JSON (if any) under ${RUN_DIR}"
  exit 1
fi
echo "Done. Full JSON under ${RUN_DIR}"
