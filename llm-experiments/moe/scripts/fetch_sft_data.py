#!/usr/bin/env python3
"""Regenerate data/sft_train.jsonl + data/sft_heldout.jsonl.

Source: kunishou/oasst1-chat-44k-ja (Apache-2.0; a Japanese translation of
OpenAssistant/oasst1, itself Apache-2.0). Rows are read through the Hugging
Face datasets-server /rows API, so nothing but the rows actually used is
downloaded. Only single-turn (human -> gpt) conversations short enough for
seq 1024 are kept. The selection is deterministic: rows are taken in dataset
order, so re-running gives the same files as long as the dataset revision does
not change.

Output rows: {"messages": [{"role": "user", ...}, {"role": "assistant", ...}]}
(the chat format both mlx_lm.lora and train_lora_cuda.sh understand).

Usage: python3 scripts/fetch_sft_data.py [--train 300] [--heldout 50]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

DATASET = "kunishou/oasst1-chat-44k-ja"
ROWS_API = "https://datasets-server.huggingface.co/rows"
PAGE = 100


def fetch_page(offset: int) -> list[dict]:
    query = urllib.parse.urlencode(
        {"dataset": DATASET, "config": "default", "split": "train", "offset": offset, "length": PAGE}
    )
    for attempt in range(5):
        try:
            with urllib.request.urlopen(f"{ROWS_API}?{query}", timeout=60) as resp:
                return [r["row"] for r in json.load(resp)["rows"]]
        except Exception as exc:  # network hiccup / 429
            print(f"[WARNING] offset {offset} attempt {attempt + 1}: {exc}", file=sys.stderr)
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"could not fetch offset {offset}")


def convert(row: dict, max_prompt: int, max_answer: int) -> dict | None:
    conv = row.get("conversations") or []
    if len(conv) != 2 or conv[0].get("from") != "human" or conv[1].get("from") != "gpt":
        return None
    prompt, answer = conv[0]["value"].strip(), conv[1]["value"].strip()
    if not prompt or not answer or len(prompt) > max_prompt or len(answer) > max_answer:
        return None
    return {"messages": [{"role": "user", "content": prompt}, {"role": "assistant", "content": answer}]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", type=int, default=300)
    ap.add_argument("--heldout", type=int, default=50)
    ap.add_argument("--max-prompt-chars", type=int, default=300)
    ap.add_argument("--max-answer-chars", type=int, default=600)
    ap.add_argument("--out-dir", default=str(Path(__file__).resolve().parent.parent / "data"))
    args = ap.parse_args()

    need = args.train + args.heldout
    kept: list[dict] = []
    offset = 0
    while len(kept) < need:
        rows = fetch_page(offset)
        if not rows:
            break
        for row in rows:
            item = convert(row, args.max_prompt_chars, args.max_answer_chars)
            if item:
                kept.append(item)
        offset += PAGE
    if len(kept) < need:
        print(f"[ERROR] only {len(kept)} usable rows", file=sys.stderr)
        return 1

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, part in (("sft_train.jsonl", kept[: args.train]), ("sft_heldout.jsonl", kept[args.train : need])):
        with open(out / name, "w", encoding="utf-8", newline="\n") as fh:
            for item in part:
                fh.write(json.dumps(item, ensure_ascii=False) + "\n")
        print(f"[OK] {out / name}: {len(part)} rows ({(out / name).stat().st_size} bytes)")
    print(f"[INFO] scanned {offset} source rows of {DATASET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
