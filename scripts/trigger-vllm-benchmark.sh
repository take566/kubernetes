#!/bin/bash
# Trigger vLLM model benchmark workflow on self-hosted runners.
#
# Usage:
#   ./scripts/trigger-vllm-benchmark.sh [compare_set]
#   ./scripts/trigger-vllm-benchmark.sh extended
#   COMPARE_SET=all ./scripts/trigger-vllm-benchmark.sh
#
# compare_set: default | extended | all  (default: default)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE_SET="${1:-${COMPARE_SET:-default}}"

case "${COMPARE_SET}" in
  default|extended|all) ;;
  *)
    echo "Invalid compare_set: ${COMPARE_SET} (use default, extended, or all)" >&2
    exit 1
    ;;
esac

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI is not installed" >&2
  exit 1
fi

cd "${REPO_ROOT}"

echo "=== Trigger vLLM Model Benchmark ==="
echo "  compare_set: ${COMPARE_SET}"
echo ""

gh auth status

echo ""
echo "Running: gh workflow run vllm-model-benchmark.yaml -f compare_set=${COMPARE_SET}"
gh workflow run vllm-model-benchmark.yaml -f "compare_set=${COMPARE_SET}"

echo ""
echo "Watch run:"
echo "  gh run list --workflow=vllm-model-benchmark.yaml --limit 1"
echo "  gh run watch"
