#!/usr/bin/env python3
"""Fixed-set QA accuracy for a chat model (data/eval_qa.jsonl, 30 items).

Two backends:
  * OpenAI-compatible server (Ollama /v1, vLLM, mlx_lm.server):
        eval_quality.py --base-url http://127.0.0.1:11434/v1 --model granite3.1-moe:3b
  * Local Hugging Face model through transformers generate (LoRA before/after):
        eval_quality.py --hf-model ibm-granite/granite-3.1-1b-a400m-instruct [--adapter DIR]
    --heldout data/sft_heldout.jsonl additionally reports the mean token loss
    on the assistant turns of the held-out SFT rows (HF mode only).

Grading: temperature 0, the reply and every accepted answer are NFKC-normalised,
lower-cased and stripped of whitespace/punctuation; an item is correct when any
accepted answer is a substring of the reply. Prints one JSON line per item and a
summary line, and writes everything to --output when given.

The OpenAI mode needs only the standard library.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import unicodedata
import urllib.request
from pathlib import Path

DEFAULT_QA = Path(__file__).resolve().parent.parent / "data" / "eval_qa.jsonl"
SYSTEM_PROMPT = (
    "You are a concise assistant. Answer with only the answer itself, no explanation. "
    "質問が日本語なら日本語で、答えだけを短く返してください。"
)
_STRIP = re.compile(r"[\s\W_]+", re.UNICODE)


def normalise(text: str) -> str:
    return _STRIP.sub("", unicodedata.normalize("NFKC", text).lower())


def is_correct(reply: str, answers: list[str]) -> bool:
    norm = normalise(reply)
    return any(normalise(a) and normalise(a) in norm for a in answers)


def load_jsonl(path: str | Path) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


# --------------------------------------------------------------------------- OpenAI


def openai_chat(base_url: str, model: str, question: str, max_tokens: int, timeout: float) -> str:
    root = base_url.rstrip("/")
    url = f"{root}/chat/completions" if root.endswith("/v1") else f"{root}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": question}],
        "temperature": 0.0,
        "max_tokens": max_tokens,
        "stream": False,
    }
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.load(resp)
    return (body["choices"][0]["message"].get("content") or "").strip()


# --------------------------------------------------------------------------- HF


class HFRunner:
    def __init__(self, model_id: str, adapter: str | None, dtype: str, device: str):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self.torch = torch
        torch_dtype = {"fp16": torch.float16, "bf16": torch.bfloat16, "fp32": torch.float32}[dtype]
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        if device == "cpu" and torch_dtype == torch.float16:
            torch_dtype = torch.float32  # fp16 matmul on CPU is slow / unsupported
        self.device = device
        self.tok = AutoTokenizer.from_pretrained(adapter or model_id)
        if self.tok.pad_token is None:
            self.tok.pad_token = self.tok.eos_token
        try:  # transformers >= 4.56 / 5.x name the argument "dtype"
            model = AutoModelForCausalLM.from_pretrained(model_id, dtype=torch_dtype)
        except TypeError:
            model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=torch_dtype)
        if adapter:
            from peft import PeftModel

            model = PeftModel.from_pretrained(model, adapter)
            model = model.merge_and_unload()
        self.model = model.to(device).eval()

    def _ids(self, messages: list[dict], add_generation_prompt: bool):
        # Render to text first: apply_chat_template(tokenize=True) changed its
        # return type (tensor vs BatchEncoding) across transformers releases.
        text = self.tok.apply_chat_template(
            messages, add_generation_prompt=add_generation_prompt, tokenize=False
        )
        return self.tok(text, return_tensors="pt", add_special_tokens=False).input_ids.to(self.device)

    def chat(self, question: str, max_tokens: int) -> str:
        ids = self._ids(
            [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": question}], True
        )
        with self.torch.no_grad():
            out = self.model.generate(
                ids,
                attention_mask=self.torch.ones_like(ids),
                max_new_tokens=max_tokens,
                do_sample=False,
                pad_token_id=self.tok.pad_token_id,
            )
        return self.tok.decode(out[0, ids.shape[1] :], skip_special_tokens=True).strip()

    def heldout_loss(self, rows: list[dict], max_len: int) -> float:
        """Mean token NLL over the assistant turn only (prompt tokens masked)."""
        total, count = 0.0, 0
        for row in rows:
            msgs = row["messages"]
            prompt_ids = self._ids(msgs[:-1], True)
            full_ids = self._ids(msgs, False)[:, :max_len]
            labels = full_ids.clone()
            labels[:, : min(prompt_ids.shape[1], labels.shape[1])] = -100
            n = int((labels != -100).sum())
            if n == 0:
                continue
            with self.torch.no_grad():
                loss = self.model(full_ids, labels=labels).loss
            total += float(loss) * n
            count += n
        return total / count if count else float("nan")


# --------------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qa", default=str(DEFAULT_QA))
    ap.add_argument("--base-url", default="http://127.0.0.1:11434/v1")
    ap.add_argument("--model", help="model name for the OpenAI-compatible server")
    ap.add_argument("--hf-model", help="Hugging Face model id/path (transformers mode)")
    ap.add_argument("--adapter", help="PEFT LoRA adapter dir to merge onto --hf-model")
    ap.add_argument("--dtype", choices=("fp16", "bf16", "fp32"), default="fp16")
    ap.add_argument("--device", default="auto", help="auto | cuda | cpu")
    ap.add_argument("--heldout", help="SFT jsonl to compute held-out loss on (HF mode)")
    ap.add_argument("--heldout-max-len", type=int, default=1024)
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--label", default="", help="free-form label stored in the output")
    ap.add_argument("--output", help="write the full result JSON here")
    args = ap.parse_args()

    if bool(args.model) == bool(args.hf_model):
        ap.error("give exactly one of --model (OpenAI server) or --hf-model (transformers)")

    qa = load_jsonl(args.qa)
    runner = None
    if args.hf_model:
        runner = HFRunner(args.hf_model, args.adapter, args.dtype, args.device)

    items = []
    t0 = time.perf_counter()
    for row in qa:
        start = time.perf_counter()
        try:
            if runner:
                reply = runner.chat(row["question"], args.max_tokens)
            else:
                reply = openai_chat(args.base_url, args.model, row["question"], args.max_tokens, args.timeout)
            error = None
        except Exception as exc:  # keep going; an error counts as wrong
            reply, error = "", f"{type(exc).__name__}: {exc}"
        item = {
            "id": row["id"],
            "category": row.get("category"),
            "correct": (error is None) and is_correct(reply, row["answers"]),
            "reply": reply,
            "answers": row["answers"],
            "latency_s": round(time.perf_counter() - start, 3),
        }
        if error:
            item["error"] = error
        items.append(item)
        print(json.dumps(item, ensure_ascii=False), flush=True)

    correct = sum(i["correct"] for i in items)
    by_cat: dict[str, list[int]] = {}
    for i in items:
        by_cat.setdefault(i["category"] or "-", [0, 0])
        by_cat[i["category"] or "-"][0] += int(i["correct"])
        by_cat[i["category"] or "-"][1] += 1
    summary = {
        "label": args.label,
        "backend": "hf" if runner else "openai",
        "model": args.hf_model or args.model,
        "adapter": args.adapter,
        "base_url": None if runner else args.base_url,
        "correct": correct,
        "total": len(items),
        "accuracy": round(correct / len(items), 4) if items else 0.0,
        "by_category": {k: f"{v[0]}/{v[1]}" for k, v in sorted(by_cat.items())},
        "errors": sum(1 for i in items if "error" in i),
        "wall_s": round(time.perf_counter() - t0, 1),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if runner and args.heldout:
        summary["heldout_loss"] = round(runner.heldout_loss(load_jsonl(args.heldout), args.heldout_max_len), 4)
    print(json.dumps({"summary": summary}, ensure_ascii=False))
    print(f"[RESULT] accuracy {correct}/{len(items)} = {summary['accuracy']:.1%}", file=sys.stderr)

    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(
            json.dumps({"summary": summary, "items": items}, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return 0 if summary["errors"] < len(items) else 2


if __name__ == "__main__":
    raise SystemExit(main())
