#!/usr/bin/env python3
"""Serena 形式のイベントを Logstash TCP (json codec) に送るシード生成（e2e 用、標準ライブラリのみ）。

kind 内の toolbox Pod から stdin 経由で実行する想定:
  kubectl exec -i e2e-toolbox -- python - --session S --info 1 --pii 1 < seed-serena-events.py

種類:
  --info N       通常の serena イベント（INFO）
  --error N      ERROR レベルの serena イベント
  --pii N        Windows パスとメールアドレスを含む serena イベント（PII マスク確認用）
  --sensitive N  api_key= を含む serena イベント（sensitive_pattern 確認用）
  --plain N      serena ではないイベント（logstash-* に入る想定）
  --unmapped N   logs-serena の strict マッピングに無いフィールド付き（意図的な HTTP 400 用）
全イベントの serena.session_id（plain は labels.session_id）に --session を入れる。
"""

import argparse
import json
import socket
from datetime import datetime, timedelta, timezone


def serena_event(session: str, i: int, level: str, message: str) -> dict:
    ts = datetime.now(timezone.utc) + timedelta(milliseconds=i)
    return {
        "@timestamp": ts.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "event": {"kind": "serena.log"},
        "serena": {
            "stream": "mcp.file",
            "session_id": session,
            "project": "kubernetes",
            "host": "e2e-host",
            "logger": "serena.agent",
            "function": "e2e_seed",
            "line": 100 + i,
        },
        "log": {"level": level, "thread": "MainThread"},
        "message": message,
        "host": {"os": {"type": "windows"}},
    }


def build(args: argparse.Namespace) -> list[dict]:
    s, events, i = args.session, [], 0
    for _ in range(args.info):
        events.append(serena_event(s, i, "INFO", f"e2e info event {i}: Active tools (25): find_symbol, replace_symbol"))
        i += 1
    for _ in range(args.error):
        events.append(serena_event(s, i, "ERROR", f"e2e error event {i}: tool execution failed with TimeoutError"))
        i += 1
    for _ in range(args.pii):
        events.append(serena_event(
            s, i, "INFO",
            # ユーザー名は 's' 始まり（旧パターン [^\\s] は 's' で止まり、マスクされなかった）
            f"e2e pii event {i}: opened C:\\Users\\sam.smith\\project\\main.py for sam.smith@example.com"))
        i += 1
    for _ in range(args.sensitive):
        events.append(serena_event(s, i, "INFO", f"e2e sensitive event {i}: request api_key=sk-test-0000 rejected"))
        i += 1
    for _ in range(args.unmapped):
        ev = serena_event(s, i, "INFO", f"e2e unmapped event {i}: should be rejected by strict mapping")
        ev["e2e_unmapped_field"] = "x"
        events.append(ev)
        i += 1
    for _ in range(args.plain):
        events.append({
            "@timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "labels": {"session_id": s},
            "message": f"e2e plain (non-serena) event {i}",
        })
        i += 1
    return events


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--session", required=True)
    p.add_argument("--host", default="logstash.elk-stack.svc")
    p.add_argument("--port", type=int, default=5000)
    for k in ("info", "error", "pii", "sensitive", "plain", "unmapped"):
        p.add_argument(f"--{k}", type=int, default=0)
    args = p.parse_args()
    events = build(args)
    payload = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in events).encode("utf-8")
    with socket.create_connection((args.host, args.port), timeout=15) as sock:
        sock.sendall(payload)
    print(json.dumps({"session": args.session, "sent": len(events)}))


if __name__ == "__main__":
    main()
