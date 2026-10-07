#!/usr/bin/env bash
# LoRA fine-tune of a small MoE on the GTX 1650 (deploy-note), CUDA + fp16.
#
#   ./scripts/train_lora_cuda.sh            # refuses unless >= 3 GiB VRAM is free
#
# Drives the repo's own vllm/components/finetune/scripts/train_lora.py (TRL SFT
# + PEFT) through run_train_lora.py, which adapts its SFTTrainer kwargs to the
# current TRL. Production vLLM holds ~3 GiB of the 4 GiB card, so this only
# runs inside the vLLM window (scripts/vllm_window.sh start). The free-VRAM
# check reads nvidia-smi, NOT torch.cuda.mem_get_info(): under WSL the latter
# was measured reporting 3294 MiB free while nvidia-smi showed 885 MiB free
# with vLLM resident.
#
# Env overrides: BASE_MODEL, LORA_R, LORA_ALPHA, MAX_SEQ_LENGTH, NUM_EPOCHS,
#   PER_DEVICE_BATCH_SIZE, GRADIENT_ACCUMULATION_STEPS, USE_4BIT (nf4 fallback
#   on OOM), MIN_FREE_VRAM_MIB, OUTPUT_DIR, LLM_EXP_VENV.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MOE_DIR}/../.." && pwd)"
VENV="${LLM_EXP_VENV:-${HOME}/llm-exp/.venv}"
MIN_FREE_VRAM_MIB="${MIN_FREE_VRAM_MIB:-3072}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

export BASE_MODEL="${BASE_MODEL:-ibm-granite/granite-3.1-1b-a400m-instruct}"
export DATASET_PATH="${DATASET_PATH:-${MOE_DIR}/data/sft_train.jsonl}"
export OUTPUT_DIR="${OUTPUT_DIR:-${MOE_DIR}/adapters/granite-1b-a400m-cuda-${TS}}"
export TRAIN_LORA_PY="${REPO_ROOT}/vllm/components/finetune/scripts/train_lora.py"
# Turing (sm_75) has no bf16: fp16 mixed precision.
export USE_BF16=false USE_FP16=true
export USE_4BIT="${USE_4BIT:-false}"
export LORA_R="${LORA_R:-8}" LORA_ALPHA="${LORA_ALPHA:-16}" LORA_DROPOUT="${LORA_DROPOUT:-0.05}"
# Attention projections only: GraniteMoe experts live in block_sparse_moe.input_linear/output_linear.
export LORA_TARGET_MODULES="${LORA_TARGET_MODULES:-q_proj,k_proj,v_proj,o_proj}"
export NUM_EPOCHS="${NUM_EPOCHS:-1}" MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-1024}"
export PER_DEVICE_BATCH_SIZE="${PER_DEVICE_BATCH_SIZE:-1}" GRADIENT_ACCUMULATION_STEPS="${GRADIENT_ACCUMULATION_STEPS:-8}"
export LEARNING_RATE="${LEARNING_RATE:-2e-4}" LOGGING_STEPS="${LOGGING_STEPS:-5}" SAVE_STEPS="${SAVE_STEPS:-10000}"
export DATALOADER_NUM_WORKERS="${DATALOADER_NUM_WORKERS:-0}" GRADIENT_CHECKPOINTING="${GRADIENT_CHECKPOINTING:-true}"
export ATTN_IMPLEMENTATION="${ATTN_IMPLEMENTATION:-sdpa}" REPORT_TO=none
export HF_HOME="${HF_HOME:-${HOME}/.cache/huggingface}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

[[ -x "${VENV}/bin/python" ]] || { echo "[ERROR] venv missing: ${VENV} (see README)" >&2; exit 1; }
[[ -f "$TRAIN_LORA_PY" ]] || { echo "[ERROR] not found: ${TRAIN_LORA_PY}" >&2; exit 1; }
[[ -f "$DATASET_PATH" ]] || { echo "[ERROR] dataset not found: ${DATASET_PATH}" >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo "[ERROR] nvidia-smi not found" >&2; exit 1; }

free_mib="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')"
if [[ -z "$free_mib" || "$free_mib" -lt "$MIN_FREE_VRAM_MIB" ]]; then
  echo "[ERROR] only ${free_mib:-?} MiB VRAM free (need >= ${MIN_FREE_VRAM_MIB}). Production vLLM is probably" >&2
  echo "        still resident - open the window first: scripts/vllm_window.sh start. Refusing to start." >&2
  exit 3
fi
echo "[OK] ${free_mib} MiB VRAM free (>= ${MIN_FREE_VRAM_MIB})"

mkdir -p "$OUTPUT_DIR"
# Sample VRAM use every 2 s so the peak includes the CUDA context, not just torch tensors.
vram_log="${OUTPUT_DIR}/vram.csv"
nvidia-smi --query-gpu=timestamp,memory.used --format=csv,noheader,nounits -l 2 > "$vram_log" 2>/dev/null &
smi_pid=$!
trap 'kill "$smi_pid" 2>/dev/null || true' EXIT

echo "[INFO] base=${BASE_MODEL} r=${LORA_R} targets=${LORA_TARGET_MODULES} seq=${MAX_SEQ_LENGTH} epochs=${NUM_EPOCHS} 4bit=${USE_4BIT}"
set +e
"${VENV}/bin/python" "${SCRIPT_DIR}/run_train_lora.py" 2>&1 | tee "${OUTPUT_DIR}/train.log"
rc=${PIPESTATUS[0]}
set -e
kill "$smi_pid" 2>/dev/null || true
peak="$(awk -F', ' '{ if ($2+0 > m) m = $2+0 } END { print m+0 }' "$vram_log")"
echo "[INFO] peak nvidia-smi memory.used during run: ${peak} MiB (whole GPU)"
echo "{\"peak_nvidia_smi_used_mib\": ${peak}, \"exit_code\": ${rc}}" > "${OUTPUT_DIR}/vram_peak.json"
if [[ "$rc" -ne 0 ]]; then
  echo "[ERROR] training failed (exit ${rc}); on CUDA OOM retry with USE_4BIT=true" >&2
  exit "$rc"
fi
echo "[OK] adapter: ${OUTPUT_DIR}"
echo "Next: eval before/after (inside the window):"
echo "  ${VENV}/bin/python ${SCRIPT_DIR}/eval_quality.py --hf-model ${BASE_MODEL} --heldout ${MOE_DIR}/data/sft_heldout.jsonl --label before"
echo "  ${VENV}/bin/python ${SCRIPT_DIR}/eval_quality.py --hf-model ${BASE_MODEL} --adapter ${OUTPUT_DIR} --heldout ${MOE_DIR}/data/sft_heldout.jsonl --label after"
