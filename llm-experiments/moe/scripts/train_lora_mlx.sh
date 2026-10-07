#!/usr/bin/env bash
# LoRA fine-tune of the same MoE on Apple Silicon (tmf-m3) with mlx_lm.lora,
# settings matched to train_lora_cuda.sh so the two machines are comparable:
# r=8 (alpha 16 -> scale 2.0), q/k/v/o only, 1 epoch over data/sft_train.jsonl,
# seq 1024, lr 2e-4, batch 1 x grad-accum 8.
#
#   ./scripts/train_lora_mlx.sh            # held-out loss before, train, loss after, fuse
#
# Needs: mlx-lm (e.g. `uv tool install mlx-lm`), Apple Silicon.
# Env: BASE_MODEL, LORA_R, LORA_ALPHA, MAX_SEQ_LENGTH, LEARNING_RATE, GRAD_ACCUM,
#      OUT_DIR, SKIP_FUSE=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

BASE_MODEL="${BASE_MODEL:-ibm-granite/granite-3.1-1b-a400m-instruct}"
LORA_R="${LORA_R:-8}"
LORA_ALPHA="${LORA_ALPHA:-16}"
MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-1024}"
LEARNING_RATE="${LEARNING_RATE:-2e-4}"
GRAD_ACCUM="${GRAD_ACCUM:-8}"
OUT_DIR="${OUT_DIR:-${MOE_DIR}/adapters/granite-1b-a400m-mlx-${TS}}"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || { echo "[ERROR] Apple Silicon only" >&2; exit 1; }
LORA_BIN="$(command -v mlx_lm.lora || true)"
FUSE_BIN="$(command -v mlx_lm.fuse || true)"
[[ -n "$LORA_BIN" ]] || { echo "[ERROR] mlx_lm.lora not on PATH (uv tool install mlx-lm)" >&2; exit 1; }

mkdir -p "${OUT_DIR}/data"
# mlx_lm.lora wants <dir>/{train,valid,test}.jsonl; chat rows ({"messages": ...}) are native.
cp "${MOE_DIR}/data/sft_train.jsonl" "${OUT_DIR}/data/train.jsonl"
cp "${MOE_DIR}/data/sft_heldout.jsonl" "${OUT_DIR}/data/valid.jsonl"
cp "${MOE_DIR}/data/sft_heldout.jsonl" "${OUT_DIR}/data/test.jsonl"
rows="$(wc -l < "${OUT_DIR}/data/train.jsonl" | tr -d ' ')"
iters="${ITERS:-$rows}"   # batch 1 -> one epoch == one iteration per row

scale="$(awk -v a="$LORA_ALPHA" -v r="$LORA_R" 'BEGIN { printf "%.4f", a / r }')"
cat > "${OUT_DIR}/lora_config.yaml" <<EOF
fine_tune_type: lora
num_layers: -1
lora_parameters:
  rank: ${LORA_R}
  scale: ${scale}
  dropout: 0.05
  keys: ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj"]
grad_accumulation_steps: ${GRAD_ACCUM}
EOF

echo "[INFO] base=${BASE_MODEL} r=${LORA_R} scale=${scale} seq=${MAX_SEQ_LENGTH} iters=${iters} out=${OUT_DIR}"

echo "=== held-out loss BEFORE (base model) ==="
"$LORA_BIN" --model "$BASE_MODEL" --data "${OUT_DIR}/data" --test \
  --max-seq-length "$MAX_SEQ_LENGTH" --batch-size 1 2>&1 | tee "${OUT_DIR}/test_before.log"

echo "=== train ==="
start=$(date +%s)
"$LORA_BIN" --model "$BASE_MODEL" --train --data "${OUT_DIR}/data" -c "${OUT_DIR}/lora_config.yaml" \
  --iters "$iters" --batch-size 1 --learning-rate "$LEARNING_RATE" \
  --max-seq-length "$MAX_SEQ_LENGTH" --steps-per-report 10 --steps-per-eval "$iters" \
  --adapter-path "${OUT_DIR}/adapter" 2>&1 | tee "${OUT_DIR}/train.log"
echo "{\"train_wall_s\": $(( $(date +%s) - start )), \"iters\": ${iters}}" > "${OUT_DIR}/train_stats.json"
# mlx_lm.lora reports "Peak mem" and "Tokens/sec" per report line in train.log.
grep -E "Peak mem|Tokens/sec" "${OUT_DIR}/train.log" | tail -1 || true

echo "=== held-out loss AFTER (adapter) ==="
"$LORA_BIN" --model "$BASE_MODEL" --adapter-path "${OUT_DIR}/adapter" --data "${OUT_DIR}/data" --test \
  --max-seq-length "$MAX_SEQ_LENGTH" --batch-size 1 2>&1 | tee "${OUT_DIR}/test_after.log"

if [[ "${SKIP_FUSE:-0}" != "1" && -n "$FUSE_BIN" ]]; then
  "$FUSE_BIN" --model "$BASE_MODEL" --adapter-path "${OUT_DIR}/adapter" --save-path "${OUT_DIR}/fused"
  echo "[OK] fused model: ${OUT_DIR}/fused"
fi

cat <<EOF
[OK] adapter: ${OUT_DIR}/adapter
QA before/after through mlx_lm.server (OpenAI-compatible):
  mlx_lm.server --model ${BASE_MODEL} --port 8090 &      # before
  python3 ${SCRIPT_DIR}/eval_quality.py --base-url http://127.0.0.1:8090/v1 --model ${BASE_MODEL} --label before
  mlx_lm.server --model ${OUT_DIR}/fused --port 8091 &   # after
  python3 ${SCRIPT_DIR}/eval_quality.py --base-url http://127.0.0.1:8091/v1 --model ${OUT_DIR}/fused --label after
EOF
