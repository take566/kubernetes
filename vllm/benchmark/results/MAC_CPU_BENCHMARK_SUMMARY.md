# Mac vLLM / CPU ベンチマーク要約 (2026-06-11)

## 環境

| 項目 | 値 |
|------|-----|
| プラットフォーム | macOS 26.5.1 / **arm64** / 24 GiB RAM |
| kind / kubectl | **未インストール** → K8s overlay は未使用 |
| Docker | 利用可 (`openeuler/vllm-cpu:0.20.1-oe2403sp3` ローカル済み) |
| Ollama | 利用可 (`http://127.0.0.1:11434/v1`) — Metal 推論 |

## 計測条件（統一）

- スクリプト: `vllm/benchmark/scripts/bench_vllm.py`
- `max_tokens=64`, `latency_samples=10`, `throughput_requests=20`, `concurrency=4`（Ollama）/ `2`（vLLM CPU Docker、スクリプト既定）
- プロンプト: Kubernetes GPU scheduling（`bench_ollama_openai.sh` / `bench_vllm_macos_cpu.sh` 既定）

## 結果一覧

### A. Ollama OpenAI 互換 API（Mac 主推論経路・Metal）

| モデル (Ollama) | HF 対応 | p50 (ms) | p99 (ms) | 出力 tok/s | req/s | 結果 JSON |
|-----------------|---------|----------|----------|------------|-------|-----------|
| `qwen2.5:0.5b` | Qwen2.5-0.5B-Instruct | 534.7 | 546.7 | **138.4** | 2.16 | `bench-ollama-openai-qwen2.5_0.5b-2026-06-11T115514.json` |
| `sam860/LFM2:1.2b` | LFM2.5-1.2B-Instruct | 752.8 | 756.7 | 91.1 | 1.42 | `bench-ollama-openai-sam860_LFM2_1.2b-2026-06-11T115605.json` |

### B. vLLM CPU（Docker / kind 相当・`openeuler/vllm-cpu`）

| モデル (HF) | tier | p50 (ms) | p99 (ms) | 出力 tok/s | req/s | 結果 JSON |
|-------------|------|----------|----------|------------|-------|-----------|
| `facebook/opt-125m` | smoke | **430.2** | 451.2 | **279.0** | 4.36 | `bench-vllm-cpu-facebook_opt-125m-2026-06-11T085243Z.json` |
| `Qwen/Qwen2.5-0.5B-Instruct` | kind（推奨） | 1562.7 | 1621.3 | 71.1 | 1.11 | `bench-vllm-cpu-Qwen__Qwen2.5-0.5B-Instruct-2026-06-11T084903Z.json` |

> **注:** `opt-125m` は completions API、`Qwen2.5-0.5B` は chat API。いずれも vLLM OpenAI 互換エンドポイント経由。

## 推奨

| 目的 | 推奨 | 理由 |
|------|------|------|
| **Mac 上の日常開発・ベンチ** | Ollama + `qwen2.5:0.5b` | 同一 `bench_vllm.py` で **約 2×** の出力 tok/s（対 vLLM CPU Qwen 0.5B）、レイテンシも低い |
| **品質と速度のバランス（Metal）** | Ollama + `sam860/LFM2:1.2b` | 1.2B クラスで安定した p99、十分なスループット |
| **vLLM 本体の CPU 検証（Mac / kind 代替）** | Docker + `Qwen/Qwen2.5-0.5B-Instruct` | `model-candidates.yaml` の `SELECTED_KIND` と一致、Instruct 品質 |
| **vLLM CPU スモークのみ** | Docker + `facebook/opt-125m` | 最小モデルで最速 tok/s（品質は検証用） |

**総合:** Mac では **実運用・比較ベンチは Ollama（層1）**、**マニフェスト／vLLM 挙動の確認は `bench_vllm_macos_cpu.sh`（層3・Docker）** が最短経路。kind 導入後は `vllm/overlays/kind/cpu/` で同じ HF ID を再現可能。

## 再現手順

```bash
# 前提: Ollama 起動済み
cd /path/to/kubernetes

# Ollama（推奨）
BENCH_MAX_TOKENS=64 BENCH_LATENCY_SAMPLES=10 BENCH_THROUGHPUT_REQUESTS=20 \
  ./scripts/bench_ollama_openai.sh -m qwen2.5:0.5b

BENCH_MAX_TOKENS=64 BENCH_LATENCY_SAMPLES=10 BENCH_THROUGHPUT_REQUESTS=20 \
  ./scripts/bench_ollama_openai.sh -m sam860/LFM2:1.2b

# vLLM CPU（kind なし Mac）
MODELS="Qwen/Qwen2.5-0.5B-Instruct facebook/opt-125m" \
  ./scripts/bench_vllm_macos_cpu.sh
```

結果は `vllm/benchmark/results/` に JSON 出力。

## ブロッカー / 制限

- **kind / kubectl なし:** `vllm/overlays/kind/cpu/` は未実行。Docker 経路で代替済み。
- vLLM CPU は Ollama Metal より遅い（想定どおり）。本番 GPU クラスタ（kubeadm overlay）の数値とは非比較。
