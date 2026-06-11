#!/usr/bin/env python3
"""RAG-style Serena log analysis: ES search + Ollama embeddings + optional vLLM/Ollama chat."""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def http_json(
    url: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    timeout_s: float = 60.0,
) -> dict[str, Any]:
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {url}: {detail}") from exc


def tokenize(text: str) -> list[str]:
    return [t.lower() for t in re.findall(r"[a-zA-Z0-9_\u0080-\uFFFF]+", text) if len(t) > 1]


def keyword_score(query: str, chunk: str) -> float:
    q_tokens = set(tokenize(query))
    if not q_tokens:
        return 0.0
    c_tokens = set(tokenize(chunk))
    overlap = len(q_tokens & c_tokens)
    return overlap / len(q_tokens)


def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def ollama_embed(base_url: str, model: str, text: str) -> list[float] | None:
    url = f"{base_url.rstrip('/')}/api/embeddings"
    try:
        result = http_json(url, "POST", {"model": model, "prompt": text}, timeout_s=120.0)
        emb = result.get("embedding")
        if isinstance(emb, list) and emb:
            return [float(x) for x in emb]
    except Exception as exc:
        print(f"Warning: Ollama embedding failed ({exc}); falling back to keyword ranking.", file=sys.stderr)
    return None


def ollama_chat(base_url: str, model: str, system: str, user: str) -> str:
    url = f"{base_url.rstrip('/')}/api/chat"
    body = {
        "model": model,
        "stream": False,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "options": {"temperature": 0.2},
    }
    result = http_json(url, "POST", body, timeout_s=180.0)
    msg = result.get("message") or {}
    return str(msg.get("content", "")).strip()


def vllm_chat(base_url: str, model: str, system: str, user: str) -> str:
    url = f"{base_url.rstrip('/')}/v1/chat/completions"
    body = {
        "model": model,
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    result = http_json(url, "POST", body, timeout_s=180.0)
    choices = result.get("choices") or []
    if not choices:
        return ""
    return str((choices[0].get("message") or {}).get("content", "")).strip()


def build_chunk(hit: dict[str, Any]) -> dict[str, Any]:
    src = hit.get("_source", {})
    log = src.get("log") or {}
    serena = src.get("serena") or {}
    level = str(log.get("level") or "INFO")
    logger = str(serena.get("logger") or "")
    message = str(src.get("message") or "")
    session_id = str(serena.get("session_id") or "unknown")
    ts = str(src.get("@timestamp") or "")
    text = f"[{level}] {logger}: {message}".strip()
    return {
        "id": hit.get("_id"),
        "session_id": session_id,
        "timestamp": ts,
        "level": level,
        "text": text,
    }


def search_logs(es_url: str, index: str, query: str, size: int = 50) -> list[dict[str, Any]]:
    q_tokens = tokenize(query)
    should: list[dict[str, Any]] = [
        {"match": {"message": {"query": query, "boost": 2.0}}},
        {"match": {"serena.logger": {"query": query}}},
    ]
    for tok in q_tokens[:8]:
        should.append({"match": {"message": tok}})

    body = {
        "size": size,
        "sort": [{"@timestamp": {"order": "desc"}}],
        "query": {
            "bool": {
                "filter": [
                    {"term": {"event.kind": "serena.log"}},
                    {"terms": {"log.level": ["ERROR", "WARNING"]}},
                ],
                "should": should,
                "minimum_should_match": 1 if q_tokens else 0,
            }
        },
        "_source": ["@timestamp", "log.level", "serena.logger", "serena.session_id", "message"],
    }
    path = f"/{urllib.parse.quote(index, safe='*,')}/_search"
    result = http_json(f"{es_url.rstrip('/')}{path}", "POST", body)
    hits = result.get("hits", {}).get("hits", [])
    return [build_chunk(h) for h in hits]


def rank_chunks(
    query: str,
    chunks: list[dict[str, Any]],
    ollama_url: str,
    embed_model: str,
) -> list[dict[str, Any]]:
    query_vec = ollama_embed(ollama_url, embed_model, query)
    scored: list[tuple[float, dict[str, Any]]] = []
    for chunk in chunks:
        kw = keyword_score(query, chunk["text"])
        if query_vec is not None:
            chunk_vec = ollama_embed(ollama_url, embed_model, chunk["text"])
            sim = cosine(query_vec, chunk_vec) if chunk_vec else 0.0
            score = 0.6 * sim + 0.4 * kw
        else:
            score = kw
        scored.append((score, chunk))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [{**c, "score": s} for s, c in scored]


def format_context(top_chunks: list[dict[str, Any]], max_chars: int = 12000) -> str:
    lines: list[str] = []
    used = 0
    for i, chunk in enumerate(top_chunks, start=1):
        block = (
            f"[{i}] session_id={chunk['session_id']} "
            f"level={chunk['level']} time={chunk['timestamp']}\n"
            f"{chunk['text']}\n"
        )
        if used + len(block) > max_chars:
            break
        lines.append(block)
        used += len(block)
    return "\n".join(lines)


def generate_summary(
    query: str,
    context: str,
    ollama_url: str,
    ollama_model: str,
    vllm_url: str | None,
    vllm_model: str,
) -> str:
    system = (
        "You are a Serena MCP log analyst. Summarize based ONLY on the provided log excerpts. "
        "Cite evidence using serena.session_id values from the context. "
        "If the logs do not support a conclusion, say '不明'. Do not invent causes."
    )
    user = f"Question:\n{query}\n\nLog excerpts:\n{context}\n\nProvide a concise summary with session_id citations."
    if vllm_url:
        try:
            return vllm_chat(vllm_url, vllm_model, system, user)
        except Exception as exc:
            print(f"Warning: vLLM chat failed ({exc}); falling back to Ollama.", file=sys.stderr)
    return ollama_chat(ollama_url, ollama_model, system, user)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Serena log RAG query (ES + Ollama embeddings + chat)")
    p.add_argument("--es-url", default="http://localhost:9200", help="Elasticsearch base URL")
    p.add_argument("--index", default="logs-serena", help="Elasticsearch index name")
    p.add_argument("--ollama", default="http://localhost:11434", help="Ollama base URL")
    p.add_argument("--embed-model", default="nomic-embed-text", help="Ollama embedding model")
    p.add_argument("--ollama-model", default="qwen2.5:1.5b", help="Ollama chat fallback model")
    p.add_argument("--vllm", default=None, help="Optional vLLM OpenAI-compatible base URL")
    p.add_argument("--vllm-model", default="Qwen/Qwen2.5-1.5B-Instruct", help="vLLM model name")
    p.add_argument("--top-k", type=int, default=8, help="Top chunks for context")
    p.add_argument("--search-size", type=int, default=50, help="Initial ES result size")
    p.add_argument("--query", required=True, help="Natural language question")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    chunks = search_logs(args.es_url, args.index, args.query, size=args.search_size)
    if not chunks:
        print("No matching ERROR/WARNING Serena logs found.")
        return 1

    ranked = rank_chunks(args.query, chunks, args.ollama, args.embed_model)
    top = [c for c in ranked if c.get("score", 0) > 0][: args.top_k]
    if not top:
        top = ranked[: args.top_k]

    context = format_context(top)
    summary = generate_summary(
        args.query,
        context,
        args.ollama,
        args.ollama_model,
        args.vllm,
        args.vllm_model,
    )

    print("=== Top log chunks ===")
    for i, chunk in enumerate(top, start=1):
        print(f"{i}. session_id={chunk['session_id']} score={chunk.get('score', 0):.3f} [{chunk['level']}]")
        print(f"   {chunk['text'][:200]}{'…' if len(chunk['text']) > 200 else ''}")

    print("\n=== Summary ===")
    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
