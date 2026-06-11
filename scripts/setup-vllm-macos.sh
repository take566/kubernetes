#!/usr/bin/env bash
# macOS vLLM local setup orchestrator.
# Primary: Ollama (Metal). Optional: kind cluster + CPU vLLM overlay.
#
# Usage:
#   ./scripts/setup-vllm-macos.sh              # Ollama only (recommended)
#   ./scripts/setup-vllm-macos.sh --with-kind  # Ollama + kind/cpu overlay

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WITH_KIND=0
SKIP_BENCHMARK=0

for arg in "$@"; do
  case "$arg" in
    --with-kind) WITH_KIND=1 ;;
    --skip-benchmark) SKIP_BENCHMARK=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: setup-vllm-macos.sh [--with-kind] [--skip-benchmark]

  --with-kind       Create kind cluster and apply vllm/overlays/kind/cpu/
  --skip-benchmark  Skip bench after Ollama setup
EOF
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${CYAN}=== vLLM macOS Setup ===${NC}"

# Docker check (needed for kind path)
if ! docker info >/dev/null 2>&1; then
  echo -e "${YELLOW}WARN: Docker daemon not running (required only for --with-kind)${NC}"
fi

BENCH_ARGS=()
[[ "$SKIP_BENCHMARK" -eq 1 ]] && BENCH_ARGS+=(--skip-benchmark)

"${REPO_ROOT}/scripts/setup-ollama-macos.sh" "${BENCH_ARGS[@]}"

if [[ "$WITH_KIND" -eq 0 ]]; then
  echo ""
  echo -e "${GREEN}Ollama path ready.${NC} For kind CPU vLLM: $0 --with-kind"
  exit 0
fi

echo ""
echo -e "${CYAN}--- kind + CPU vLLM overlay (optional) ---${NC}"

for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}Error: ${tool} is required for --with-kind${NC}" >&2
    echo "  kind:   brew install kind" >&2
    echo "  kubectl: brew install kubectl" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo -e "${RED}Error: Docker daemon is not running${NC}" >&2
  exit 1
fi

CPU_IMAGE="${VLLM_CPU_IMAGE:-openeuler/vllm-cpu:0.20.1-oe2403sp3}"
echo "Pulling CPU image: ${CPU_IMAGE}"
docker pull "$CPU_IMAGE"

"${REPO_ROOT}/kind/scripts/create-cluster.sh"

export VLLM_CPU_IMAGE="$CPU_IMAGE"
"${REPO_ROOT}/kind/scripts/load-images.sh"

echo "Applying vllm/overlays/kind/cpu/"
kubectl apply -k "${REPO_ROOT}/vllm/overlays/kind/cpu/"

echo ""
echo -e "${GREEN}kind CPU vLLM deployed.${NC}"
echo "  watch:  kubectl -n vllm get pods -w"
echo "  pf:     kubectl -n vllm port-forward svc/vllm 8000:8000"
echo "  docs:   vllm/overlays/kind/cpu/README.md"
