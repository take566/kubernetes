#!/usr/bin/env bash
# macOS Apple Silicon — Ollama Metal stack setup (primary local inference path).
# Usage: ./scripts/setup-ollama-macos.sh [--skip-benchmark]
#
# Prerequisites: Ollama (https://ollama.com), curl, optional python3+aiohttp for bench

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

SKIP_BENCHMARK=0
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"

for arg in "$@"; do
  case "$arg" in
    --skip-benchmark) SKIP_BENCHMARK=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-benchmark]"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { echo -e "\n${CYAN}==> $*${NC}"; }

ollama_reachable() {
  curl -sf --max-time 10 "${OLLAMA_BASE_URL}/api/tags" >/dev/null 2>&1
}

model_installed() {
  local name="$1"
  ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$name"
}

echo -e "${CYAN}=== Ollama macOS Setup (Metal GPU primary path) ===${NC}"

step "Platform"
ARCH="$(uname -m)"
echo "  arch: ${ARCH}"
if [[ "$ARCH" != "arm64" ]]; then
  echo -e "  ${RED}WARN:${NC} Apple Silicon (arm64) 向けです。Intel Mac でも Ollama は動作しますが未検証です。"
fi

step "Ollama connectivity"
if ! command -v ollama >/dev/null 2>&1; then
  echo -e "${RED}Error: ollama not found. Install from https://ollama.com${NC}" >&2
  exit 1
fi
if ! ollama_reachable; then
  echo -e "${RED}Error: Ollama not reachable at ${OLLAMA_BASE_URL}${NC}" >&2
  echo "  Start: ollama serve  (or open Ollama.app)" >&2
  exit 1
fi
echo -e "  ${GREEN}Ollama API: OK${NC} (${OLLAMA_BASE_URL})"

PULL_MODELS=(
  qwen2.5:0.5b
  sam860/LFM2:1.2b
  qwen2.5:1.5b
)

step "Pull recommended models"
for m in "${PULL_MODELS[@]}"; do
  if model_installed "$m"; then
    echo -e "  ${GREEN}${m} — present${NC}"
    continue
  fi
  echo "  Pulling ${m} ..."
  ollama pull "$m"
done

step "Smoke test (OpenAI /v1/chat/completions)"
SMOKE_MODEL="${SMOKE_MODEL:-sam860/LFM2:1.2b}"
RESP="$(curl -sf --max-time 120 "${OLLAMA_BASE_URL}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${SMOKE_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK in one word.\"}],\"max_tokens\":8}")"
echo "  model: ${SMOKE_MODEL}"
echo "  response: $(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null || echo "$RESP" | head -c 120)"
echo -e "  ${GREEN}OpenAI API: OK${NC}"

if [[ "$SKIP_BENCHMARK" -eq 0 ]]; then
  BENCH="${REPO_ROOT}/scripts/bench_ollama_openai.sh"
  if [[ -x "$BENCH" ]]; then
    step "Quick benchmark"
    "$BENCH" -m "$SMOKE_MODEL" --latency-samples 3 --throughput-requests 5 --max-tokens 32 || true
  else
    echo "  SKIP: bench script not executable ($BENCH)"
  fi
fi

echo ""
echo -e "${GREEN}Setup complete.${NC}"
echo "  Bench:    ./scripts/bench_ollama_openai.sh -m sam860/LFM2:1.2b"
echo "  Docs:     vllm/overlays/macos-local/README.md"
echo "  kind CPU: kubectl apply -k vllm/overlays/kind/cpu/  (optional, slow)"
