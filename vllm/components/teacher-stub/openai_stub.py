#!/usr/bin/env python3
"""Minimal OpenAI-compatible stub for kind distill E2E (no GPU)."""
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    model = os.environ.get("VLLM_MODEL", "stub/teacher")

    def log_message(self, fmt: str, *args) -> None:
        return

    def _json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path in ("/health", "/v1/models"):
            self._json(200, {"status": "ok"})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/v1/chat/completions":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return
        messages = req.get("messages") or []
        user = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                user = str(m.get("content", ""))
                break
        text = f"[kind-stub] Echo: {user[:200]}" if user else "[kind-stub] Hello from teacher stub."
        self._json(
            200,
            {
                "id": "chatcmpl-stub",
                "object": "chat.completion",
                "model": self.model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": text},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
            },
        )


def main() -> None:
    host = os.environ.get("VLLM_HOST", "0.0.0.0")
    port = int(os.environ.get("VLLM_PORT", "8000"))
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
