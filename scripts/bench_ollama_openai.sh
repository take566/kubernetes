#!/usr/bin/env bash
# Run bench_vllm.py against Ollama OpenAI-compatible API (/v1/chat/completions).
# Usage:
#   ./scripts/bench_ollama_openai.sh -m sam860/LFM2:1.2b
#   ./scripts/bench_ollama_openai.sh --hf-id Qwen/Qwen2.5-1.5B-Instruct

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_PY="${REPO_ROOT}/vllm/benchmark/scripts/bench_vllm.py"
MAP_FILE="${REPO_ROOT}/vllm/benchmark/ollama-model-map.json"
RESULTS_DIR="${REPO_ROOT}/vllm/benchmark/results"

MODEL="${OLLAMA_MODEL:-}"
HF_ID="${HF_MODEL_ID:-}"
BASE_URL="${OLLAMA_OPENAI_BASE_URL:-http://127.0.0.1:11434/v1}"
PROMPT="${BENCH_PROMPT:-Write a short paragraph about Kubernetes GPU scheduling.}"
MAX_TOKENS="${BENCH_MAX_TOKENS:-64}"
LATENCY_SAMPLES="${BENCH_LATENCY_SAMPLES:-10}"
THROUGHPUT_REQUESTS="${BENCH_THROUGHPUT_REQUESTS:-20}"
OUTPUT_FILE="${BENCH_OUTPUT_FILE:-}"

usage() {
  cat <<'EOF'
Usage: bench_ollama_openai.sh [-m MODEL] [--hf-id HF_ID] [options]

Options:
  -m, --model TAG           Ollama tag (default: qwen2.5:1.5b)
  --hf-id ID                HuggingFace ID — lookup in ollama-model-map.json
  --base-url URL            OpenAI base URL (default: http://127.0.0.1:11434/v1)
  --max-tokens N
  --latency-samples N
  --throughput-requests N
  -o, --output FILE         Output JSON path
  -h, --help
EOF
}

resolve_ollama_tag() {
  local id_or_tag="$1"
  if [[ "$id_or_tag" != */* ]]; then
    echo "$id_or_tag"
    return
  fi
  python3 - "$MAP_FILE" "$id_or_tag" <<'PY'
import json, sys
map_file, hf_id = sys.argv[1], sys.argv[2]
with open(map_file) as f:
    data = json.load(f)
tag = data.get("mappings", {}).get(hf_id)
if not tag:
    sys.exit(f"No Ollama mapping for {hf_id} in {map_file}")
print(tag)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model) MODEL="$2"; shift 2 ;;
    --hf-id) HF_ID="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --latency-samples) LATENCY_SAMPLES="$2"; shift 2 ;;
    --throughput-requests) THROUGHPUT_REQUESTS="$2"; shift 2 ;;
    -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -n "$HF_ID" ]]; then
  MODEL="$(resolve_ollama_tag "$HF_ID")"
elif [[ -z "$MODEL" ]]; then
  MODEL="qwen2.5:1.5b"
fi

if [[ ! -f "$BENCH_PY" ]]; then
  echo "Error: bench_vllm.py not found: $BENCH_PY" >&2
  exit 1
fi

if ! python3 -c 'import aiohttp' 2>/dev/null; then
  echo "Installing aiohttp for benchmark..."
  python3 -m pip install --user -q aiohttp
fi

mkdir -p "$RESULTS_DIR"
if [[ -z "$OUTPUT_FILE" ]]; then
  SAFE_MODEL="${MODEL//\//_}"
  SAFE_MODEL="${SAFE_MODEL//:/_}"
  TS="$(date -u +%Y-%m-%dT%H%M%S)"
  OUTPUT_FILE="${RESULTS_DIR}/bench-ollama-openai-${SAFE_MODEL}-${TS}.json"
fi

echo "=== Ollama OpenAI benchmark (bench_vllm.py) ==="
echo "  model:    $MODEL"
echo "  base_url: $BASE_URL"
echo "  output:   $OUTPUT_FILE"

JSON_OUT="$(python3 "$BENCH_PY" \
  --base-url "$BASE_URL" \
  --model "$MODEL" \
  --prompt "$PROMPT" \
  --max-tokens "$MAX_TOKENS" \
  --latency-samples "$LATENCY_SAMPLES" \
  --throughput-requests "$THROUGHPUT_REQUESTS" \
  --skip-health)"

printf '%s\n' "$JSON_OUT" > "$OUTPUT_FILE"
echo "Wrote: $OUTPUT_FILE"
