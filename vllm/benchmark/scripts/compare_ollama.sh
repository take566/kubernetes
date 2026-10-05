#!/usr/bin/env bash
# Compare candidate models on the in-cluster CPU Ollama (ollama/k8s/) with bench_vllm.py (#9).
# GPU が無い環境（WSL の kubeadm / kind / CI）でモデル比較の流れと結果形式を検証するための経路。
# CPU の数値から GPU 上の順位は推定できないので、採用判断は GPU 実機の compare_models.sh で行う。
#
# Usage:
#   MODELS="Qwen/Qwen2.5-0.5B-Instruct Qwen/Qwen2.5-1.5B-Instruct" ./vllm/benchmark/scripts/compare_ollama.sh
# Env:
#   MODELS            HuggingFace ID（ollama-model-map.json で Ollama タグに変換）または Ollama タグ
#   OLLAMA_NS         Ollama の名前空間（既定 llm、Service ollama:11434）
#   RESULTS_DIR       結果の出力先（既定 ./vllm-bench-results/ollama-<時刻>）
#   BENCH_*           bench_vllm.py の設定（既定は CPU 向けに小さめ）
# 出力: RESULTS_DIR/<slug>.json
#   成功: {"model", "ollama_tag", "status": "ok", "latency": {p50_ms, p99_ms, ...}, "throughput": {...}}
#   失敗: {"model", "ollama_tag", "status": "failed", "reason"}（pull や推論に失敗しても他の候補は続ける）
# 終了コード: 0=全候補成功 / 1=失敗した候補あり（詳細は各 JSON）/ 2=引数エラー
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OLLAMA_NS="${OLLAMA_NS:-llm}"
RESULTS_DIR="${RESULTS_DIR:-./vllm-bench-results/ollama-$(date +%Y%m%d-%H%M%S)}"
MODEL_MAP="${MODEL_MAP:-${BENCH_DIR}/ollama-model-map.json}"
RUNNER=bench-runner
PULL_TIMEOUT="${PULL_TIMEOUT:-1200}"

[[ -n "${MODELS:-}" ]] || { echo "MODELS is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
mkdir -p "${RESULTS_DIR}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# HF ID → Ollama タグ（対応表に無ければそのまま Ollama タグとして扱う）
to_tag() { jq -r --arg m "$1" '.mappings[$m] // $m' "${MODEL_MAP}"; }
slug() { tr '/:' '__' <<<"$1"; }

write_failed() {  # <model> <tag> <reason>
  jq -n --arg m "$1" --arg t "$2" --arg r "$3" '{model:$m, ollama_tag:$t, status:"failed", reason:$r}' \
    > "${RESULTS_DIR}/$(slug "$1").json"
}

# bench_vllm.py を動かす Pod（python + aiohttp）。Ollama と同じ名前空間に置く
ensure_runner() {
  kubectl -n "${OLLAMA_NS}" get pod "${RUNNER}" >/dev/null 2>&1 && return 0
  kubectl -n "${OLLAMA_NS}" run "${RUNNER}" --restart=Never --image=python:3.11-slim-bookworm \
    --command -- sh -c 'pip install -q aiohttp && touch /tmp/ready && sleep 86400' >/dev/null
  kubectl -n "${OLLAMA_NS}" wait --for=condition=Ready "pod/${RUNNER}" --timeout=300s >/dev/null
  local i
  for i in $(seq 1 60); do
    kubectl -n "${OLLAMA_NS}" exec "${RUNNER}" -- test -f /tmp/ready 2>/dev/null && return 0
    sleep 5
  done
  echo "bench runner did not become ready (pip install aiohttp)" >&2
  return 1
}

FAILED=0
kubectl -n "${OLLAMA_NS}" rollout status deploy/ollama --timeout=600s >/dev/null
ensure_runner

for model in ${MODELS}; do
  tag="$(to_tag "${model}")"
  out="${RESULTS_DIR}/$(slug "${model}").json"
  log "=== ${model} (ollama: ${tag}) ==="
  if ! pull_log="$(timeout "${PULL_TIMEOUT}" kubectl -n "${OLLAMA_NS}" exec deploy/ollama -- ollama pull "${tag}" 2>&1)"; then
    log "pull failed: ${tag}"
    write_failed "${model}" "${tag}" "ollama pull failed: $( (grep -i 'error' <<<"${pull_log}" || tail -1 <<<"${pull_log}") | tail -1)"
    FAILED=$((FAILED + 1))
    continue
  fi
  if ! bench="$(kubectl -n "${OLLAMA_NS}" exec -i "${RUNNER}" -- python - \
      --base-url "http://ollama.${OLLAMA_NS}.svc:11434/v1" --model "${tag}" --api chat \
      --max-tokens "${BENCH_MAX_TOKENS:-32}" --warmup "${BENCH_WARMUP:-1}" \
      --latency-samples "${BENCH_LATENCY_SAMPLES:-5}" --throughput-requests "${BENCH_THROUGHPUT_REQUESTS:-8}" \
      --concurrency "${BENCH_CONCURRENCY:-2}" --timeout "${BENCH_TIMEOUT_S:-300}" \
      < "${SCRIPT_DIR}/bench_vllm.py" 2>"${out}.stderr")"; then
    log "bench failed: ${tag}"
    write_failed "${model}" "${tag}" "bench_vllm.py failed: $(tail -1 "${out}.stderr")"
    FAILED=$((FAILED + 1))
    continue
  fi
  jq --arg m "${model}" --arg t "${tag}" '. + {model:$m, ollama_tag:$t, status:"ok"}' <<<"${bench}" > "${out}"
  rm -f "${out}.stderr"
  log "p50=$(jq -r '.latency.p50_ms' "${out}")ms p99=$(jq -r '.latency.p99_ms' "${out}")ms tok/s=$(jq -r '.throughput.output_tokens_per_second' "${out}")"
done

kubectl -n "${OLLAMA_NS}" delete pod "${RUNNER}" --wait=false >/dev/null 2>&1 || true
jq -s 'map({model, status, p50_ms: .latency.p50_ms, p99_ms: .latency.p99_ms, tokens_per_s: .throughput.output_tokens_per_second, reason})' \
  "${RESULTS_DIR}"/*.json > "${RESULTS_DIR}/summary.json"
log "results: ${RESULTS_DIR} (failed: ${FAILED})"
[[ "${FAILED}" -eq 0 ]]
