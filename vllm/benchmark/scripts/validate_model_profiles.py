#!/usr/bin/env python3
"""Validate vllm/benchmark/model-profiles.json structure."""
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_KEYS = {"id", "family", "tier", "est_vram_gib", "gated", "extra_args"}
ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "model-profiles.json"


def main() -> int:
    if not PROFILES.exists():
        print(f"ERROR: missing {PROFILES}", file=sys.stderr)
        return 1

    data = json.loads(PROFILES.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not data:
        print("ERROR: model-profiles.json must be a non-empty array", file=sys.stderr)
        return 1

    seen: set[str] = set()
    errors = 0
    for i, profile in enumerate(data):
        missing = REQUIRED_KEYS - set(profile)
        if missing:
            print(f"ERROR: profile[{i}] missing keys: {sorted(missing)}", file=sys.stderr)
            errors += 1
            continue
        mid = profile["id"]
        if mid in seen:
            print(f"ERROR: duplicate model id: {mid}", file=sys.stderr)
            errors += 1
        seen.add(mid)
        if not isinstance(profile["est_vram_gib"], (int, float)) or profile["est_vram_gib"] <= 0:
            print(f"ERROR: {mid} est_vram_gib must be positive number", file=sys.stderr)
            errors += 1

    if errors:
        print(f"FAILED: {errors} profile error(s)", file=sys.stderr)
        return 1

    print(f"OK: validated {len(data)} model profiles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
