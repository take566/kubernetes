#!/usr/bin/env python3
"""LoRA fine-tuning for AMD ROCm (HIP) using HuggingFace TRL + PEFT.

Canonical copy also lives at vllm/scripts/train_lora.py — keep both in sync.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def env_bool(name: str, default: bool) -> bool:
    val = os.getenv(name, str(default)).lower()
    return val in ("1", "true", "yes", "on")


def env_int(name: str, default: int) -> int:
    return int(os.getenv(name, str(default)))


def env_float(name: str, default: float) -> float:
    return float(os.getenv(name, str(default)))


def main() -> int:
    import torch
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments
    from trl import SFTTrainer

    if not torch.cuda.is_available():
        print("ERROR: No ROCm/HIP GPU visible (torch.cuda.is_available() is False).", file=sys.stderr)
        return 1

    print(f"ROCm device: {torch.cuda.get_device_name(0)}")
    print(f"Device count: {torch.cuda.device_count()}")

    base_model = os.environ["BASE_MODEL"]
    dataset_path = os.environ.get("DATASET_PATH", "/data/dataset")
    output_dir = os.environ.get("OUTPUT_DIR", "/data/output")
    hf_home = os.environ.get("HF_HOME", "/data/huggingface")

    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(hf_home, exist_ok=True)

    use_bf16 = env_bool("USE_BF16", True)
    use_fp16 = env_bool("USE_FP16", False) and not use_bf16
    use_4bit = env_bool("USE_4BIT", False)
    attn_impl = os.getenv("ATTN_IMPLEMENTATION", "sdpa")
    use_compile = env_bool("TORCH_COMPILE", False)

    lora_config = LoraConfig(
        r=env_int("LORA_R", 16),
        lora_alpha=env_int("LORA_ALPHA", 32),
        lora_dropout=env_float("LORA_DROPOUT", 0.05),
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=os.getenv(
            "LORA_TARGET_MODULES",
            "q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj",
        ).split(","),
    )

    model_kwargs: dict = {
        "trust_remote_code": env_bool("TRUST_REMOTE_CODE", False),
        "attn_implementation": attn_impl,
    }
    if use_4bit:
        from transformers import BitsAndBytesConfig

        model_kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_compute_dtype=torch.bfloat16 if use_bf16 else torch.float16,
            bnb_4bit_use_double_quant=True,
            bnb_4bit_quant_type="nf4",
        )
        model_kwargs["device_map"] = "auto"
    else:
        model_kwargs["torch_dtype"] = torch.bfloat16 if use_bf16 else torch.float16

    tokenizer = AutoTokenizer.from_pretrained(base_model, trust_remote_code=model_kwargs["trust_remote_code"])
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(base_model, **model_kwargs)
    if use_4bit:
        model = prepare_model_for_kbit_training(model)
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    if use_compile and hasattr(torch, "compile"):
        print("Enabling torch.compile (cluster-specific; disable if startup fails)")
        model = torch.compile(model)

    dataset = _load_dataset(dataset_path)

    training_args = TrainingArguments(
        output_dir=output_dir,
        num_train_epochs=env_float("NUM_EPOCHS", 1.0),
        per_device_train_batch_size=env_int("PER_DEVICE_BATCH_SIZE", 2),
        gradient_accumulation_steps=env_int("GRADIENT_ACCUMULATION_STEPS", 8),
        learning_rate=env_float("LEARNING_RATE", 2e-4),
        warmup_ratio=env_float("WARMUP_RATIO", 0.03),
        lr_scheduler_type=os.getenv("LR_SCHEDULER", "cosine"),
        logging_steps=env_int("LOGGING_STEPS", 10),
        save_steps=env_int("SAVE_STEPS", 200),
        save_total_limit=env_int("SAVE_TOTAL_LIMIT", 2),
        bf16=use_bf16,
        fp16=use_fp16,
        gradient_checkpointing=env_bool("GRADIENT_CHECKPOINTING", True),
        dataloader_num_workers=env_int("DATALOADER_NUM_WORKERS", 4),
        dataloader_pin_memory=env_bool("DATALOADER_PIN_MEMORY", True),
        max_grad_norm=env_float("MAX_GRAD_NORM", 1.0),
        report_to=os.getenv("REPORT_TO", "none"),
        remove_unused_columns=False,
    )

    max_seq_length = env_int("MAX_SEQ_LENGTH", 2048)

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        processing_class=tokenizer,
        dataset_text_field=os.getenv("DATASET_TEXT_FIELD", "text"),
        max_seq_length=max_seq_length,
        packing=env_bool("PACKING", False),
    )

    trainer.train()
    trainer.save_model(output_dir)
    tokenizer.save_pretrained(output_dir)

    meta = {
        "base_model": base_model,
        "output_dir": output_dir,
        "lora_r": lora_config.r,
        "lora_alpha": lora_config.lora_alpha,
        "max_seq_length": max_seq_length,
        "bf16": use_bf16,
        "attn_implementation": attn_impl,
    }
    Path(output_dir, "training_meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"Training complete. Adapter saved to {output_dir}")
    return 0


def _load_dataset(dataset_path: str):
    from datasets import load_dataset

    path = Path(dataset_path)
    if not path.exists():
        raise FileNotFoundError(
            f"Dataset path not found: {dataset_path}. "
            "Mount JSONL/JSON/Parquet under /data/dataset or set DATASET_PATH."
        )

    if path.is_file():
        suffix = path.suffix.lower()
        if suffix in (".jsonl", ".json"):
            return load_dataset("json", data_files=str(path), split="train")
        if suffix == ".parquet":
            return load_dataset("parquet", data_files=str(path), split="train")
        raise ValueError(f"Unsupported dataset file type: {suffix}")

    jsonl = path / "train.jsonl"
    if jsonl.exists():
        return load_dataset("json", data_files=str(jsonl), split="train")

    return load_dataset(str(path), split="train")


if __name__ == "__main__":
    raise SystemExit(main())
