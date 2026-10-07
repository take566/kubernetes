#!/usr/bin/env python3
"""Run vllm/components/finetune/scripts/train_lora.py unchanged on a current TRL.

train_lora.py passes dataset_text_field / max_seq_length / packing straight to
SFTTrainer(). TRL >= 0.12 moved those to SFTConfig (max_seq_length is now
max_length) and TRL 1.x rejects them as unknown kwargs, so the production
script cannot be imported as-is with the TRL that also supports GraniteMoe. This
launcher patches SFTTrainer.__init__ to move the three kwargs into an SFTConfig
built from the TrainingArguments, then executes train_lora.py via runpy. The
production script and its ConfigMap stay untouched.

It also:
  * renders {"messages": [...]} rows to a {"text": ...} file with the base
    model's chat template (train_lora.py trains on a plain text field), and
  * prints train wall time, peak torch-allocated VRAM and tokens/s at exit.

Env: same as train_lora.py (BASE_MODEL, DATASET_PATH, OUTPUT_DIR, ...) plus
     TRAIN_LORA_PY (path to train_lora.py).
"""
from __future__ import annotations

import json
import os
import runpy
import sys
import time
from pathlib import Path


def render_messages_dataset() -> None:
    src = Path(os.environ["DATASET_PATH"])
    if not src.is_file() or src.suffix != ".jsonl":
        return
    rows = [json.loads(line) for line in src.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not rows or "messages" not in rows[0] or "text" in rows[0]:
        return
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(os.environ["BASE_MODEL"])
    out = Path(os.environ["OUTPUT_DIR"]) / "train_text.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    n_tokens = 0
    with open(out, "w", encoding="utf-8") as fh:
        for row in rows:
            text = tok.apply_chat_template(row["messages"], tokenize=False)
            n_tokens += len(tok(text, add_special_tokens=False).input_ids)
            fh.write(json.dumps({"text": text}, ensure_ascii=False) + "\n")
    os.environ["DATASET_PATH"] = str(out)
    os.environ.setdefault("DATASET_TEXT_FIELD", "text")
    os.environ["_RUN_TRAIN_TOKENS"] = str(n_tokens)
    print(f"[INFO] rendered {len(rows)} chat rows -> {out} ({n_tokens} tokens)")


def patch_sft_trainer() -> None:
    import inspect

    import trl
    from trl import SFTConfig, SFTTrainer

    params = inspect.signature(SFTTrainer.__init__).parameters
    if "dataset_text_field" in params:
        return  # old TRL: nothing to do
    original = SFTTrainer.__init__

    def __init__(self, *args, **kwargs):
        moved = {}
        if "dataset_text_field" in kwargs:
            moved["dataset_text_field"] = kwargs.pop("dataset_text_field")
        if "max_seq_length" in kwargs:
            moved["max_length"] = kwargs.pop("max_seq_length")
        if "packing" in kwargs:
            moved["packing"] = kwargs.pop("packing")
        targs = kwargs.get("args")
        if targs is not None and not isinstance(targs, SFTConfig):
            cfg = {k: v for k, v in targs.to_dict().items() if k in SFTConfig.__dataclass_fields__}
            # to_dict() renders some fields for logging; drop the ones SFTConfig rebuilds itself
            for key in ("logging_dir",):
                cfg.pop(key, None)
            cfg.update(moved)
            kwargs["args"] = SFTConfig(**cfg)
        elif targs is not None:
            for k, v in moved.items():
                setattr(targs, k, v)
        original(self, *args, **kwargs)

    SFTTrainer.__init__ = __init__
    print(f"[INFO] TRL {trl.__version__}: SFTTrainer kwargs shim active (dataset_text_field/max_seq_length/packing -> SFTConfig)")


def patch_training_arguments() -> None:
    """transformers 5.x dropped warmup_ratio (warmup_steps takes a float < 1 as a ratio)."""
    import transformers

    original = transformers.TrainingArguments
    fields = original.__dataclass_fields__
    if "warmup_ratio" in fields:
        return

    def training_arguments(**kwargs):
        ratio = kwargs.pop("warmup_ratio", None)
        if ratio is not None and "warmup_steps" not in kwargs:
            kwargs["warmup_steps"] = float(ratio)
        dropped = [k for k in kwargs if k not in fields]
        for k in dropped:
            kwargs.pop(k)
        if dropped:
            print(f"[WARNING] TrainingArguments: dropped kwargs unknown to transformers {transformers.__version__}: {dropped}")
        return original(**kwargs)

    transformers.TrainingArguments = training_arguments
    print(f"[INFO] transformers {transformers.__version__}: warmup_ratio -> warmup_steps shim active")


def main() -> int:
    script = os.environ.get("TRAIN_LORA_PY")
    if not script or not Path(script).is_file():
        print("[ERROR] TRAIN_LORA_PY must point at train_lora.py", file=sys.stderr)
        return 1
    render_messages_dataset()
    patch_training_arguments()
    patch_sft_trainer()

    import torch

    if torch.cuda.is_available():
        torch.cuda.reset_peak_memory_stats()
    t0 = time.perf_counter()
    rc = 0
    try:
        sys.argv = [script]
        runpy.run_path(script, run_name="__main__")
    except SystemExit as exc:
        rc = int(exc.code or 0)
    elapsed = time.perf_counter() - t0
    stats = {"train_wall_s": round(elapsed, 1), "exit_code": rc}
    if torch.cuda.is_available():
        stats["peak_vram_allocated_mib"] = round(torch.cuda.max_memory_allocated() / 2**20, 1)
        stats["peak_vram_reserved_mib"] = round(torch.cuda.max_memory_reserved() / 2**20, 1)
    tokens = int(os.environ.get("_RUN_TRAIN_TOKENS", "0"))
    epochs = float(os.environ.get("NUM_EPOCHS", "1"))
    if tokens and elapsed > 0:
        stats["train_tokens"] = int(tokens * epochs)
        stats["train_tokens_per_s"] = round(tokens * epochs / elapsed, 1)
    print("[TRAIN_STATS] " + json.dumps(stats))
    out_dir = os.environ.get("OUTPUT_DIR")
    if out_dir:
        Path(out_dir, "train_stats.json").write_text(json.dumps(stats, indent=2), encoding="utf-8")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
