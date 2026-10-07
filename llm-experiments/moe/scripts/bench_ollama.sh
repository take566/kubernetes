#!/usr/bin/env bash
# Benchmark one Ollama model with fixed settings so runs are comparable.
#
#   ./scripts/bench_ollama.sh granite3.1-moe:3b [label]
#
# 1. scripts/bench_ollama_openai.sh (repo root) -> bench_vllm.py:
#    /v1/chat/completions latency p50/p99 + concurrent throughput.
# 2. One native /api/generate call (num_predict=128) for single-stream decode
#    tok/s (eval_count / eval_duration) - the number comparable to llmfit's
#    estimated_tps - plus load and prompt-eval time.
# 3. /api/ps afterwards: how much of the model sat in VRAM (size_vram / size).
#
# Output (gitignored): results/bench-<label>-<model>-<ts>.json,
#                      results/native-<label>-<model>-<ts>.json
# Settings come from env with the defaults below; everything is recorded.
set -euo pipefail

MODEL="${1:?usage: bench_ollama.sh MODEL [label]}"
LABEL="${2:-${BENCH_LABEL:-run}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MOE_DIR}/../.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${MOE_DIR}/results}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
VENV="${LLM_EXP_VENV:-${HOME}/llm-exp/.venv}"

export BENCH_PROMPT="${BENCH_PROMPT:-Write a short paragraph about Kubernetes GPU scheduling.}"
export BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS:-64}"
export BENCH_LATENCY_SAMPLES="${BENCH_LATENCY_SAMPLES:-10}"
export BENCH_THROUGHPUT_REQUESTS="${BENCH_THROUGHPUT_REQUESTS:-12}"
export BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-2}"
export BENCH_WARMUP="${BENCH_WARMUP:-2}"
export BENCH_TIMEOUT_S="${BENCH_TIMEOUT_S:-300}"
NATIVE_PREDICT="${NATIVE_PREDICT:-128}"

# bench_ollama_openai.sh calls "python3" and needs aiohttp; the experiment venv
# has it, and a system "pip install --user" is refused on Ubuntu 24.04 (PEP 668).
if [[ -x "${VENV}/bin/python3" ]]; then
  export PATH="${VENV}/bin:${PATH}"
fi

mkdir -p "$RESULTS_DIR"
safe="${MODEL//\//_}"; safe="${safe//:/_}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
bench_json="${RESULTS_DIR}/bench-${LABEL}-${safe}-${ts}.json"
native_json="${RESULTS_DIR}/native-${LABEL}-${safe}-${ts}.json"

curl -fsS "${OLLAMA_URL}/api/version" >/dev/null || { echo "[ERROR] Ollama not reachable at ${OLLAMA_URL}" >&2; exit 1; }

"${REPO_ROOT}/scripts/bench_ollama_openai.sh" \
  --model "$MODEL" \
  --base-url "${OLLAMA_URL}/v1" \
  --max-tokens "$BENCH_MAX_TOKENS" \
  --latency-samples "$BENCH_LATENCY_SAMPLES" \
  --throughput-requests "$BENCH_THROUGHPUT_REQUESTS" \
  --output "$bench_json"

payload="$(jq -n --arg m "$MODEL" --arg p "$BENCH_PROMPT" --argjson n "$NATIVE_PREDICT" \
  '{model:$m, prompt:$p, stream:false, options:{temperature:0, num_predict:$n}}')"
native="$(curl -fsS "${OLLAMA_URL}/api/generate" -d "$payload")"
ps_json="$(curl -fsS "${OLLAMA_URL}/api/ps")"

jq -n --argjson g "$native" --argjson ps "$ps_json" --arg model "$MODEL" --arg label "$LABEL" \
  --arg bench "$bench_json" '
  ($ps.models // [] | map(select(.name == $model or .model == $model)) | first) as $p
  | {
      model: $model, label: $label, bench_file: $bench,
      eval_count: $g.eval_count,
      decode_tps: (if ($g.eval_duration // 0) > 0 then ($g.eval_count / ($g.eval_duration / 1e9)) else null end),
      prompt_eval_count: $g.prompt_eval_count,
      prompt_tps: (if ($g.prompt_eval_duration // 0) > 0 then ($g.prompt_eval_count / ($g.prompt_eval_duration / 1e9)) else null end),
      load_s: (($g.load_duration // 0) / 1e9),
      total_s: (($g.total_duration // 0) / 1e9),
      size_bytes: ($p.size // null),
      size_vram_bytes: ($p.size_vram // null),
      vram_fraction: (if ($p.size // 0) > 0 then ($p.size_vram / $p.size) else null end),
      context_length: ($p.context_length // null)
    }' > "$native_json"

echo "[OK] ${bench_json}"
echo "[OK] ${native_json}"
jq -r '"latency p50 \(.latency.p50_ms // "-") ms / p99 \(.latency.p99_ms // "-") ms | throughput \(.throughput.output_tokens_per_second // "-") tok/s"' "$bench_json" 2>/dev/null || true
jq -r '"decode \(.decode_tps|tostring|.[0:6]) tok/s | prompt \(.prompt_tps|tostring|.[0:7]) tok/s | VRAM share \(.vram_fraction|tostring|.[0:5])"' "$native_json"
