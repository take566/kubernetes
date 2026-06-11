#!/usr/bin/env python3
"""Export filtered vLLM distillation docs from Elasticsearch to finetune JSONL."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    return float(raw) if raw else default


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    return int(raw) if raw else default


def es_request(
    base_url: str,
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
    timeout_s: float = 60.0,
) -> dict[str, Any]:
    url = f"{base_url.rstrip('/')}/{path.lstrip('/')}"
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
        raise RuntimeError(f"ES {method} {path} -> HTTP {exc.code}: {detail}") from exc


def wait_for_es(base_url: str, attempts: int = 30, sleep_s: float = 5.0) -> None:
    import time

    for i in range(attempts):
        try:
            es_request(base_url, "GET", "/_cluster/health", timeout_s=10.0)
            return
        except Exception as exc:
            if i == attempts - 1:
                raise RuntimeError(f"Elasticsearch not ready at {base_url}: {exc}") from exc
            time.sleep(sleep_s)


def build_text(messages: list[dict[str, Any]], completion: str, template: str) -> str:
    user_parts: list[str] = []
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        if str(msg.get("role", "")).lower() == "user":
            user_parts.append(str(msg.get("content", "")))
    user_text = "\n".join(user_parts).strip()
    if not user_text:
        user_text = str(messages[-1].get("content", "")) if messages else ""
    return template.format(user=user_text, completion=completion.strip())


def scroll_search(
    base_url: str,
    index: str,
    min_quality: float,
    batch_size: int,
    scroll_ttl: str,
) -> tuple[list[dict[str, Any]], str | None]:
    query = {
        "size": batch_size,
        "query": {
            "bool": {
                "filter": [
                    {"range": {"distill.quality.score": {"gte": min_quality}}},
                    {"term": {"distill.exported": False}},
                ],
                "must_not": [{"term": {"distill.quality.flags": "refusal"}}],
            }
        },
        "_source": ["distill.messages", "distill.completion", "distill.request_id"],
    }
    first = es_request(
        base_url,
        "POST",
        f"/{urllib.parse.quote(index, safe='*,')}/_search?scroll={urllib.parse.quote(scroll_ttl)}",
        query,
    )
    scroll_id = first.get("_scroll_id")
    hits = first.get("hits", {}).get("hits", [])
    docs: list[dict[str, Any]] = []
    for hit in hits:
        src = hit.get("_source", {})
        distill = src.get("distill", {})
        docs.append(
            {
                "_id": hit.get("_id"),
                "_index": hit.get("_index"),
                "request_id": distill.get("request_id"),
                "messages": distill.get("messages") or [],
                "completion": distill.get("completion") or "",
            }
        )
    return docs, scroll_id


def scroll_next(base_url: str, scroll_id: str, scroll_ttl: str) -> tuple[list[dict[str, Any]], str | None]:
    body = {"scroll": scroll_ttl, "scroll_id": scroll_id}
    page = es_request(base_url, "POST", "/_search/scroll", body)
    scroll_id = page.get("_scroll_id")
    hits = page.get("hits", {}).get("hits", [])
    docs: list[dict[str, Any]] = []
    for hit in hits:
        src = hit.get("_source", {})
        distill = src.get("distill", {})
        docs.append(
            {
                "_id": hit.get("_id"),
                "_index": hit.get("_index"),
                "request_id": distill.get("request_id"),
                "messages": distill.get("messages") or [],
                "completion": distill.get("completion") or "",
            }
        )
    return docs, scroll_id


def clear_scroll(base_url: str, scroll_id: str | None) -> None:
    if not scroll_id:
        return
    try:
        es_request(base_url, "DELETE", "/_search/scroll", {"scroll_id": [scroll_id]})
    except Exception:
        pass


def mark_exported(base_url: str, docs: list[dict[str, Any]]) -> None:
    if not docs:
        return
    lines: list[str] = []
    for doc in docs:
        meta = {"update": {"_index": doc["_index"], "_id": doc["_id"]}}
        body = {"doc": {"distill": {"exported": True}}}
        lines.append(json.dumps(meta, separators=(",", ":")))
        lines.append(json.dumps(body, separators=(",", ":")))
    payload = "\n".join(lines) + "\n"
    url = f"{base_url.rstrip('/')}/_bulk"
    req = urllib.request.Request(
        url,
        data=payload.encode("utf-8"),
        headers={"Content-Type": "application/x-ndjson"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120.0) as resp:
        result = json.loads(resp.read().decode("utf-8"))
    if result.get("errors"):
        raise RuntimeError(f"Bulk update failed: {json.dumps(result)[:500]}")


def main() -> int:
    es_url = os.environ.get("ES_URL", "http://elasticsearch.elk-stack.svc.cluster.local:9200")
    es_index = os.environ.get("ES_INDEX", "logs-vllm-distill")
    min_quality = env_float("MIN_QUALITY", 0.7)
    batch_size = env_int("BATCH_SIZE", 100)
    scroll_ttl = os.environ.get("SCROLL_TTL", "2m")
    output_dir = os.environ.get("OUTPUT_DIR", "/data/dataset")
    chat_template = os.environ.get(
        "CHAT_TEMPLATE",
        "<|im_start|>user\n{user}\n\n<|im_start|>assistant\n{completion}\n",
    )
    mark_exported_flag = os.environ.get("MARK_EXPORTED", "true").lower() in ("1", "true", "yes")

    wait_for_es(es_url)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    output_path = os.path.join(output_dir, f"distill-export-{stamp}.jsonl")
    os.makedirs(output_dir, exist_ok=True)

    exported = 0
    scroll_id: str | None = None
    try:
        docs, scroll_id = scroll_search(es_url, es_index, min_quality, batch_size, scroll_ttl)
        with open(output_path, "w", encoding="utf-8") as out:
            while docs:
                batch_written: list[dict[str, Any]] = []
                for doc in docs:
                    completion = str(doc.get("completion", "")).strip()
                    if len(completion) < 8:
                        continue
                    text = build_text(doc.get("messages") or [], completion, chat_template)
                    out.write(json.dumps({"text": text}, ensure_ascii=False) + "\n")
                    batch_written.append(doc)
                    exported += 1
                if mark_exported_flag and batch_written:
                    mark_exported(es_url, batch_written)
                docs, scroll_id = scroll_next(es_url, scroll_id or "", scroll_ttl) if scroll_id else ([], None)
                if not docs:
                    break
    finally:
        clear_scroll(es_url, scroll_id)

    print(f"Exported {exported} rows to {output_path}")
    return 0 if exported >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
