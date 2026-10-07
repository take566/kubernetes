#!/usr/bin/env bash
# llmfit survey: dump hardware + fit tables as JSON and extract the MoE rows.
#
# Usage:
#   ./scripts/llmfit_survey.sh                     # profiles chosen by OS
#   LLMFIT_PROFILES="vram1g:--memory=1G vram4g:--memory=4G" ./scripts/llmfit_survey.sh
#   LLMFIT_RUNTIME=llama.cpp ./scripts/llmfit_survey.sh   # runtime filter for the MoE extract
#
# llmfit v1.1.16 has no --force-runtime flag; every row carries a "runtime"
# field (llama.cpp / vLLM / MLX / bitnet.cpp), so the runtime is filtered with
# jq instead. --memory/--ram/--cpu-cores are GLOBAL flags and must come BEFORE
# the subcommand ("llmfit --memory=1G fit --json"), otherwise clap rejects them.
#
# Output (gitignored): results/llmfit-<host>-system.json,
#   results/llmfit-<host>-fit-<profile>.json, results/llmfit-<host>-moe-<profile>.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${MOE_DIR}/results}"
LLMFIT="${LLMFIT:-$(command -v llmfit || echo "${HOME}/.local/bin/llmfit")}"
HOST_LABEL="${HOST_LABEL:-$(hostname -s 2>/dev/null || hostname)}"
TOP_N="${TOP_N:-25}"

if [[ ! -x "$LLMFIT" ]]; then
  echo "[ERROR] llmfit not found (set LLMFIT=/path/to/llmfit)" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "[ERROR] jq is required" >&2; exit 1; }

case "$(uname -s)" in
  Darwin)
    # Unified memory: llmfit autodetects RAM == VRAM; no override needed.
    DEFAULT_PROFILES="auto:"
    DEFAULT_RUNTIME="${LLMFIT_RUNTIME:-}"
    ;;
  *)
    # deploy-note: GTX 1650 4GB, ~1GB free while production vLLM runs.
    # Commas inside a profile are turned into spaces (several flags per profile).
    # vram0g approximates the CPU-only Ollama runs outside the window (llmfit still labels it CPU+GPU).
    DEFAULT_PROFILES="vram0g:--memory=0G,--ram=19G,--cpu-cores=8 vram1g:--memory=1G,--ram=19G,--cpu-cores=8 vram4g:--memory=4G,--ram=19G,--cpu-cores=8"
    DEFAULT_RUNTIME="${LLMFIT_RUNTIME:-llama.cpp}"
    ;;
esac
PROFILES="${LLMFIT_PROFILES:-$DEFAULT_PROFILES}"
RUNTIME_FILTER="${DEFAULT_RUNTIME}"

mkdir -p "$RESULTS_DIR"
echo "[INFO] llmfit: $("$LLMFIT" --version)"
"$LLMFIT" system --json --no-dashboard > "${RESULTS_DIR}/llmfit-${HOST_LABEL}-system.json"
echo "[OK] ${RESULTS_DIR}/llmfit-${HOST_LABEL}-system.json"

for prof in $PROFILES; do
  name="${prof%%:*}"
  flags_csv="${prof#*:}"
  read -r -a flags <<< "${flags_csv//,/ }"
  fit_json="${RESULTS_DIR}/llmfit-${HOST_LABEL}-fit-${name}.json"
  moe_json="${RESULTS_DIR}/llmfit-${HOST_LABEL}-moe-${name}.json"

  # ${flags[@]+...}: empty array under set -u on macOS bash 3.2 ("auto:" profile).
  "$LLMFIT" ${flags[@]+"${flags[@]}"} fit --json --no-dashboard > "$fit_json"
  echo "[OK] ${fit_json} ($(jq '.models | length' "$fit_json") models)"

  # MoE rows that fit (anything but "Too Tight"), optionally one runtime only,
  # ranked by llmfit's own score. ollama_name is kept so the pull tag is known.
  jq --arg rt "$RUNTIME_FILTER" '
    {
      system: .system,
      runtime_filter: $rt,
      moe: [ .models[]
             | select(.is_moe == true and .fit_level != "Too Tight")
             | select($rt == "" or ((.runtime // "") | ascii_downcase) == ($rt | ascii_downcase))
             | { name, ollama_name, fit_level, run_mode, runtime, best_quant,
                 params_b, estimated_tps, memory_required_gb, moe_offloaded_gb,
                 disk_size_gb, score, license } ]
           | sort_by(-.score)
    }' "$fit_json" > "$moe_json"
  echo "[OK] ${moe_json} ($(jq '.moe | length' "$moe_json") MoE rows)"

  echo "--- top ${TOP_N} MoE (${name}) | with an Ollama tag ---"
  jq -r '.moe[] | select(.ollama_name != null)
         | [.name, .ollama_name, .fit_level, .run_mode, .best_quant, .estimated_tps] | @tsv' "$moe_json" \
    | head -n "$TOP_N" | column -t -s $'\t' || true
  echo "--- top ${TOP_N} MoE (${name}) | all ---"
  jq -r '.moe[] | [.name, (.ollama_name // "-"), .fit_level, .run_mode, .best_quant, .estimated_tps] | @tsv' "$moe_json" \
    | head -n "$TOP_N" | column -t -s $'\t' || true
done
