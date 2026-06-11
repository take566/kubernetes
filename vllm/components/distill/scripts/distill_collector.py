#!/usr/bin/env python3
"""
Distillation Collector — calls vLLM Teacher /v1/chat/completions and ships
normalized JSON events to Logstash TCP (port 5000).
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import signal
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from typing import Any

try:
    import aiohttp
except ImportError:
    print("ERROR: aiohttp required", file=sys.stderr)
    sys.exit(1)


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    return float(raw) if raw else default


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    return int(raw) if raw else default


def load_prompts(path: str) -> list[dict[str, Any]]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        raise ValueError(f"prompts file must be a JSON array: {path}")
    return data


def prompt_hash(messages: list[dict[str, str]]) -> str:
    payload = json.dumps(messages, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


class HealthHandler(BaseHTTPRequestHandler):
    healthy = False

    def log_message(self, _fmt: str, *_args: Any) -> None:
        return

    def do_GET(self) -> None:
        if self.path in ("/health", "/healthz", "/ready"):
            code = 200 if self.healthy else 503
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            body = {"status": "ok" if self.healthy else "starting"}
            self.wfile.write(json.dumps(body).encode())
            return
        self.send_response(404)
        self.end_headers()


def start_health_server(port: int) -> HTTPServer:
    server = HTTPServer(("0.0.0.0", port), HealthHandler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


async def wait_for_vllm(session: aiohttp.ClientSession, base_url: str, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    url = f"{base_url.rstrip('/')}/health"
    while time.monotonic() < deadline:
        try:
            async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status == 200:
                    return
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass
        await asyncio.sleep(5)
    raise TimeoutError(f"vLLM not healthy at {url} within {timeout_s}s")


async def call_teacher(
    session: aiohttp.ClientSession,
    base_url: str,
    model: str,
    messages: list[dict[str, str]],
    max_tokens: int,
    timeout_s: float,
) -> tuple[dict[str, Any], float]:
    url = f"{base_url.rstrip('/')}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.7,
    }
    started = time.perf_counter()
    async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=timeout_s)) as resp:
        body = await resp.json()
        latency_ms = (time.perf_counter() - started) * 1000.0
        if resp.status >= 400:
            raise RuntimeError(f"Teacher HTTP {resp.status}: {body}")
        return body, latency_ms


async def send_logstash(host: str, port: int, record: dict[str, Any], timeout_s: float) -> None:
    payload = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=timeout_s,
        )
    except asyncio.TimeoutError as exc:
        raise TimeoutError(f"Logstash TCP connect timeout {host}:{port}") from exc
    try:
        writer.write(payload)
        await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()
        del reader


def build_record(
    *,
    teacher_model: str,
    student_target: str,
    cluster: str,
    messages: list[dict[str, str]],
    completion: str,
    finish_reason: str,
    usage: dict[str, Any],
    latency_ms: float,
    namespace: str,
    pod: str,
) -> dict[str, Any]:
    return {
        "@timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "event": {"kind": "distill.sample"},
        "distill": {
            "request_id": str(uuid.uuid4()),
            "teacher_model": teacher_model,
            "student_target": student_target,
            "prompt_hash": prompt_hash(messages),
            "messages": messages,
            "completion": completion,
            "finish_reason": finish_reason,
            "usage": {
                "prompt_tokens": int(usage.get("prompt_tokens", 0)),
                "completion_tokens": int(usage.get("completion_tokens", 0)),
                "total_tokens": int(usage.get("total_tokens", 0)),
            },
            "latency_ms": round(latency_ms, 2),
            "cluster": cluster,
        },
        "kubernetes": {"namespace": namespace, "pod": pod},
    }


async def run_collector() -> None:
    base_url = os.environ.get("VLLM_BASE_URL", "http://vllm.vllm.svc.cluster.local:8000")
    teacher_model = os.environ["VLLM_MODEL"]
    student_target = os.environ.get("STUDENT_TARGET", "student-lora")
    logstash_host = os.environ.get("LOGSTASH_HOST", "logstash.elk-stack.svc.cluster.local")
    logstash_port = env_int("LOGSTASH_PORT", 5000)
    qps_limit = env_float("QPS_LIMIT", 1.0)
    sample_rate = env_float("SAMPLE_RATE", 1.0)
    interval_s = env_float("COLLECTOR_INTERVAL_S", 30.0)
    max_tokens = env_int("MAX_TOKENS", 256)
    timeout_s = env_float("REQUEST_TIMEOUT_S", 120.0)
    health_timeout_s = env_float("VLLM_HEALTH_TIMEOUT_S", 600.0)
    prompts_path = os.environ.get("PROMPTS_PATH", "/config/prompts.json")
    cluster = os.environ.get("CLUSTER", "kubeadm")
    namespace = os.environ.get("POD_NAMESPACE", "vllm")
    pod = os.environ.get("POD_NAME", "distill-collector")

    prompts = load_prompts(prompts_path)
    min_interval = 1.0 / max(qps_limit, 0.01)

    HealthHandler.healthy = False
    start_health_server(env_int("HEALTH_PORT", 8080))

    async with aiohttp.ClientSession() as session:
        await wait_for_vllm(session, base_url, health_timeout_s)
        HealthHandler.healthy = True
        print(f"Collector ready — teacher={base_url} logstash={logstash_host}:{logstash_port} qps={qps_limit}")

        idx = 0
        while True:
            item = prompts[idx % len(prompts)]
            idx += 1

            if sample_rate < 1.0:
                import random

                if random.random() > sample_rate:
                    await asyncio.sleep(min_interval)
                    continue

            role = item.get("role", "user")
            content = item["content"] if isinstance(item, dict) else str(item)
            messages = [{"role": role, "content": content}]

            try:
                body, latency_ms = await call_teacher(
                    session, base_url, teacher_model, messages, max_tokens, timeout_s
                )
                choice = (body.get("choices") or [{}])[0]
                message = choice.get("message") or {}
                record = build_record(
                    teacher_model=teacher_model,
                    student_target=student_target,
                    cluster=cluster,
                    messages=messages,
                    completion=str(message.get("content", "")),
                    finish_reason=str(choice.get("finish_reason", "unknown")),
                    usage=body.get("usage") or {},
                    latency_ms=latency_ms,
                    namespace=namespace,
                    pod=pod,
                )
                await send_logstash(logstash_host, logstash_port, record, timeout_s=10.0)
                print(f"sent request_id={record['distill']['request_id']} latency_ms={latency_ms:.1f}")
            except Exception as exc:
                print(f"ERROR: {exc}", file=sys.stderr)
                HealthHandler.healthy = False
                await asyncio.sleep(5)
                try:
                    await wait_for_vllm(session, base_url, 60.0)
                    HealthHandler.healthy = True
                except TimeoutError:
                    pass

            await asyncio.sleep(max(min_interval, interval_s))


def main() -> None:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, loop.stop)
        except (NotImplementedError, RuntimeError):
            signal.signal(sig, lambda *_: loop.stop())

    try:
        loop.run_until_complete(run_collector())
    except KeyboardInterrupt:
        pass
    finally:
        loop.close()


if __name__ == "__main__":
    main()
