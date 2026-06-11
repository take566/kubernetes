#!/usr/bin/env python3
"""
vLLM OpenAI-compatible API benchmark: latency (p50/p99) and throughput (tokens/s).

Designed to run from a K8s Job or any Linux host with network access to the vLLM Service.
Outputs JSON to stdout for capture via kubectl logs or CI artifacts.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from dataclasses import asdict, dataclass
from typing import Any

try:
    import aiohttp
except ImportError:
    print("ERROR: aiohttp required. pip install aiohttp", file=sys.stderr)
    sys.exit(1)


@dataclass
class LatencyResult:
    samples_ms: list[float]
    p50_ms: float
    p99_ms: float
    mean_ms: float
    count: int


@dataclass
class ThroughputResult:
    duration_s: float
    total_requests: int
    successful_requests: int
    total_output_tokens: int
    requests_per_second: float
    output_tokens_per_second: float
    concurrency: int


@dataclass
class BenchmarkReport:
    base_url: str
    model: str
    timestamp: str
    warmup_requests: int
    latency: LatencyResult | None
    throughput: ThroughputResult | None
    config: dict[str, Any]


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    k = (len(ordered) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(ordered) - 1)
    if f == c:
        return ordered[f]
    return ordered[f] + (ordered[c] - ordered[f]) * (k - f)


def _disable_thinking_payload(model: str) -> dict[str, Any]:
    """Extra API fields for Qwen3.6 / thinking models (fair latency benchmarks)."""
    flag = os.environ.get("BENCH_DISABLE_THINKING", "").lower()
    auto = "Qwen3.6" in model or "qwen3.6" in model.lower()
    if flag not in ("1", "true", "yes") and not auto:
        return {}
    kwargs = {"enable_thinking": False}
    # vLLM OpenAI-compatible API accepts chat_template_kwargs via extra_body
    return {"extra_body": {"chat_template_kwargs": kwargs}}


def _api_url(base_url: str, path: str) -> str:
    root = base_url.rstrip("/")
    if root.endswith("/v1"):
        return f"{root}/{path}"
    return f"{root}/v1/{path}"


def _resolve_api_mode(model: str, explicit: str | None) -> str:
    if explicit in ("chat", "completions"):
        return explicit
    # Base / legacy models without instruct chat templates
    lower = model.lower()
    if any(
        token in lower
        for token in ("opt-", "gpt2", "pythia", "tinyllama", "llama-2-7b")
    ) and "instruct" not in lower:
        return "completions"
    return "chat"


async def inference_request(
    session: aiohttp.ClientSession,
    base_url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    timeout_s: float,
    api_mode: str,
) -> tuple[float, int]:
    """Return (latency_ms, output_tokens)."""
    if api_mode == "completions":
        url = _api_url(base_url, "completions")
        payload: dict[str, Any] = {
            "model": model,
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": 0.0,
            "stream": False,
        }
    else:
        url = _api_url(base_url, "chat/completions")
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0.0,
            "stream": False,
        }
        payload.update(_disable_thinking_payload(model))
    start = time.perf_counter()
    async with session.post(
        url,
        json=payload,
        timeout=aiohttp.ClientTimeout(total=timeout_s),
    ) as resp:
        body = await resp.json()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {body}")
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    usage = body.get("usage") or {}
    out_tokens = int(usage.get("completion_tokens") or 0)
    return elapsed_ms, out_tokens


async def wait_for_health(base_url: str, timeout_s: float = 300.0) -> None:
    deadline = time.monotonic() + timeout_s
    root = base_url.rstrip("/")
    # Ollama OpenAI shim: /v1 → /api/tags; vLLM: /health
    if root.endswith("/v1"):
        probe_urls = [f"{root[:-3]}/api/tags"]
    else:
        probe_urls = [f"{root}/health", f"{root}/api/tags"]
    async with aiohttp.ClientSession() as session:
        while time.monotonic() < deadline:
            for url in probe_urls:
                try:
                    async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                        if resp.status == 200:
                            return
                except (aiohttp.ClientError, asyncio.TimeoutError):
                    pass
            await asyncio.sleep(5)
    raise TimeoutError(
        f"API readiness check failed for {base_url} (tried {probe_urls}) within {timeout_s}s"
    )


async def run_warmup(
    base_url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    count: int,
    timeout_s: float,
    api_mode: str,
) -> None:
    async with aiohttp.ClientSession() as session:
        for _ in range(count):
            await inference_request(
                session, base_url, model, prompt, max_tokens, timeout_s, api_mode
            )


async def run_latency_benchmark(
    base_url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    samples: int,
    timeout_s: float,
    api_mode: str,
) -> LatencyResult:
    latencies: list[float] = []
    async with aiohttp.ClientSession() as session:
        for _ in range(samples):
            ms, _ = await inference_request(
                session, base_url, model, prompt, max_tokens, timeout_s, api_mode
            )
            latencies.append(ms)
    return LatencyResult(
        samples_ms=latencies,
        p50_ms=percentile(latencies, 50),
        p99_ms=percentile(latencies, 99),
        mean_ms=statistics.mean(latencies) if latencies else 0.0,
        count=len(latencies),
    )


async def run_throughput_benchmark(
    base_url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    concurrency: int,
    total_requests: int,
    timeout_s: float,
    api_mode: str,
) -> ThroughputResult:
    sem = asyncio.Semaphore(concurrency)
    results: list[tuple[bool, int]] = []

    async with aiohttp.ClientSession() as session:

        async def one_request() -> None:
            async with sem:
                try:
                    _, out_tokens = await inference_request(
                        session, base_url, model, prompt, max_tokens, timeout_s, api_mode
                    )
                    results.append((True, out_tokens))
                except Exception:
                    results.append((False, 0))

        start = time.perf_counter()
        await asyncio.gather(*[one_request() for _ in range(total_requests)])
        duration = time.perf_counter() - start

    ok = [r for r in results if r[0]]
    total_out = sum(t for _, t in ok)
    return ThroughputResult(
        duration_s=duration,
        total_requests=total_requests,
        successful_requests=len(ok),
        total_output_tokens=total_out,
        requests_per_second=len(ok) / duration if duration > 0 else 0.0,
        output_tokens_per_second=total_out / duration if duration > 0 else 0.0,
        concurrency=concurrency,
    )


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    return float(raw) if raw else default


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark vLLM OpenAI API")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("VLLM_BASE_URL", "http://vllm.vllm.svc.cluster.local:8000"),
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("VLLM_MODEL", "facebook/opt-125m"),
    )
    parser.add_argument(
        "--prompt",
        default=os.environ.get(
            "BENCH_PROMPT",
            "Write a short paragraph about Kubernetes GPU scheduling.",
        ),
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=env_int("BENCH_MAX_TOKENS", 64),
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=env_int("BENCH_WARMUP", 3),
    )
    parser.add_argument(
        "--latency-samples",
        type=int,
        default=env_int("BENCH_LATENCY_SAMPLES", 20),
    )
    parser.add_argument(
        "--throughput-requests",
        type=int,
        default=env_int("BENCH_THROUGHPUT_REQUESTS", 50),
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=env_int("BENCH_CONCURRENCY", 4),
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=env_float("BENCH_TIMEOUT_S", 120.0),
    )
    parser.add_argument(
        "--skip-latency",
        action="store_true",
        default=os.environ.get("BENCH_SKIP_LATENCY", "").lower() in ("1", "true", "yes"),
    )
    parser.add_argument(
        "--skip-throughput",
        action="store_true",
        default=os.environ.get("BENCH_SKIP_THROUGHPUT", "").lower() in ("1", "true", "yes"),
    )
    parser.add_argument(
        "--health-timeout",
        type=float,
        default=env_float("BENCH_HEALTH_TIMEOUT_S", 300.0),
    )
    parser.add_argument(
        "--skip-health",
        action="store_true",
        default=os.environ.get("BENCH_SKIP_HEALTH", "").lower() in ("1", "true", "yes"),
        help="Skip readiness probe (Ollama local smoke)",
    )
    parser.add_argument(
        "--api",
        choices=("chat", "completions", "auto"),
        default=os.environ.get("BENCH_API", "auto"),
        help="OpenAI API endpoint: chat/completions or completions (base models)",
    )
    args = parser.parse_args()
    api_mode = _resolve_api_mode(args.model, None if args.api == "auto" else args.api)

    if not args.skip_health:
        asyncio.run(wait_for_health(args.base_url, args.health_timeout))
    asyncio.run(
        run_warmup(
            args.base_url,
            args.model,
            args.prompt,
            args.max_tokens,
            args.warmup,
            args.timeout,
            api_mode,
        )
    )

    latency_result = None
    throughput_result = None

    if not args.skip_latency:
        latency_result = asyncio.run(
            run_latency_benchmark(
                args.base_url,
                args.model,
                args.prompt,
                args.max_tokens,
                args.latency_samples,
                args.timeout,
                api_mode,
            )
        )

    if not args.skip_throughput:
        throughput_result = asyncio.run(
            run_throughput_benchmark(
                args.base_url,
                args.model,
                args.prompt,
                args.max_tokens,
                args.concurrency,
                args.throughput_requests,
                args.timeout,
                api_mode,
            )
        )

    report = BenchmarkReport(
        base_url=args.base_url,
        model=args.model,
        timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        warmup_requests=args.warmup,
        latency=latency_result,
        throughput=throughput_result,
        config={
            "max_tokens": args.max_tokens,
            "latency_samples": args.latency_samples,
            "throughput_requests": args.throughput_requests,
            "concurrency": args.concurrency,
        },
    )

    # Compact JSON without full raw latency list in default output
    out: dict[str, Any] = {
        "base_url": report.base_url,
        "model": report.model,
        "timestamp": report.timestamp,
        "warmup_requests": report.warmup_requests,
        "config": {**report.config, "api_mode": api_mode},
    }
    if report.latency:
        out["latency"] = {
            "p50_ms": round(report.latency.p50_ms, 2),
            "p99_ms": round(report.latency.p99_ms, 2),
            "mean_ms": round(report.latency.mean_ms, 2),
            "count": report.latency.count,
        }
    if report.throughput:
        out["throughput"] = {
            k: round(v, 4) if isinstance(v, float) else v
            for k, v in asdict(report.throughput).items()
        }

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
