# vLLM ベンチマーク結果ログ

実測値は GPU クラスタまたは [vllm-model-benchmark workflow](../../.github/workflows/vllm-model-benchmark.yaml) で取得します。

## チューニングプロファイル（v0 — 理論ベース）

Qwen2.5 公式コンテキスト（1.5B: 最大 32k）と単一 GPU 8–16 GiB Pod 前提で、以下を overlay に反映済みです。

### kubeadm / NVIDIA (`overlays/kubeadm/model-patch.yaml`)

| フラグ | 値 | 根拠 |
|--------|-----|------|
| `--gpu-memory-utilization` | 0.92 | KV キャッシュ余裕を確保しつつスループット確保 |
| `--max-num-seqs` | 256 | 1.5B では 8GB+ VRAM で現実的な同時接続数 |
| `--max-model-len` | 8192 | 32k 全開は VRAM 逼迫のため中間値 |
| `--max-num-batched-tokens` | 8192 | chunked prefill と整合 |
| `--enable-chunked-prefill` | on | 長コンテキスト時の TTFT 改善 |
| `--enable-prefix-caching` | on | 同一プレフィックス再利用 |

### kubeadm / AMD (`overlays/kubeadm/amd/model-patch.yaml`)

| フラグ | 値 | 根拠 |
|--------|-----|------|
| `--gpu-memory-utilization` | 0.88 | ROCm allocator の断片化マージン |
| `--max-num-seqs` | 128 | MI210 等での安定性優先 |
| `--max-num-batched-tokens` | 4096 | AMD 向けにバッチトークン抑制 |

### 再チューニング手順（実測後）

1. `compare_models.sh` または CI workflow で JSON を取得
2. p99 が SLA 超過 → `--max-num-seqs` を 25% ずつ下げる
3. OOM → `--gpu-memory-utilization` を 0.05 下げる、または `--max-model-len` を 4096 に
4. スループット不足 → `--max-num-seqs` を上げる（OOM しない範囲）
5. 変更を `model-patch.yaml` にコミットし、本表を更新

## 期待レンジ（参考 — 実測で上書き）

| モデル | GPU 目安 | p50 (ms) | output tok/s | 備考 |
|--------|----------|----------|--------------|------|
| facebook/opt-125m | 任意 | <100 | 100+ | スモークのみ |
| Qwen2.5-0.5B-Instruct | T4 16GB | 80–200 | 80–150 | kind デフォルト |
| Qwen2.5-1.5B-Instruct | T4 16GB | 120–350 | 50–120 | kubeadm デフォルト |
| Qwen2.5-1.5B-Instruct | A10 24GB | 80–250 | 100–200 | 本番想定 |

## Ollama ローカル実測（Windows + RX 5700 8GB）

K8s vLLM が未接続のときは `scripts/compare_models_ollama.ps1` で HuggingFace 候補を Ollama タグにマップして計測します（`vllm/benchmark/ollama-model-map.json`）。

### スモーク（手動・2026-06-11）

**環境:** Ollama (Windows), AMD Radeon RX 5700 8GB, HTTP `/api/generate` via `scripts/ollama-bench.ps1`  
**備考:** gemma4 / qwen3.6 は遅いが OOM なし。vLLM/K8s ベンチ前のスモーク比較用。

| モデル | status | total_time_s | tokens_per_s | notes |
|--------|--------|--------------|--------------|-------|
| sam860/LFM2:1.2b | OK | 4.21 | 37.38 | eval_count=143 |
| qwen2.5:1.5b | OK | 11.23 | 28.43 | eval_count=256 |
| qwen2.5:3b | OK | 14.09 | 16.27 | eval_count=114 |
| gemma4:rx5700 | OK | 54.51 | 9.45 | eval_count=256; slow, no OOM |
| qwen3.6:rx5700 | OK | 97.25 | 10.02 | eval_count=256; slow, no OOM |

JSON: [../benchmark/results/ollama-rx5700-2026-06-11.json](../benchmark/results/ollama-rx5700-2026-06-11.json)

### Extended compare set（`COMPARE_SET=extended` · 2026-06-11）

**パイプライン:** `scripts/compare_models_ollama.ps1` → `vllm/benchmark/results/ollama-compare-<timestamp>.json`  
**CI:** [.github/workflows/vllm-ollama-benchmark.yaml](../../.github/workflows/vllm-ollama-benchmark.yaml)（マップ検証は ubuntu-latest、実測は self-hosted Windows + Ollama）  
**JSON:** [../benchmark/results/ollama-compare-2026-06-11T092251.json](../benchmark/results/ollama-compare-2026-06-11T092251.json)

| HuggingFace ID | Ollama tag | status | total_time_s | tokens_per_s | 備考 |
|----------------|------------|--------|--------------|--------------|------|
| LiquidAI/LFM2.5-350M | sam860/LFM2:350m | OK | 3.15 | 68.95 | extended |
| LiquidAI/LFM2.5-1.2B-Instruct | sam860/LFM2:1.2b | OK | 4.49 | 31.34 | extended |
| Qwen/Qwen3.6-35B-A3B | qwen3.6:rx5700 | OK | 86.65 | 10.43 | slow, no OOM |
| google/gemma-4-E2B-it | gemma4:rx5700 | OK | 60.15 | 8.41 | approximate tag |
| google/gemma-4-E4B-it | gemma4:rx5700 | OK | 60.15 | 8.41 | same tag as E2B; single bench run |

> **Note:** k8s vLLM 実測（p50/p99/tok/s）は引き続き _pending_ — [vLLM Model Benchmark](../../.github/workflows/vllm-model-benchmark.yaml) + GPU クラスタが必要。

## 実測ログ（Kubernetes / vLLM）

| 日付 | 環境 | モデル | p50_ms | p99_ms | tok/s | 実行者 | JSON |
|------|------|--------|--------|--------|-------|--------|------|
| _pending_ | k8s-self-hosted | Qwen2.5-1.5B | — | — | — | CI workflow | artifact |
| _pending_ | k8s-self-hosted | LFM2.5-1.2B-Instruct | — | — | — | CI extended | artifact |
| _pending_ | k8s-self-hosted | Qwen3.6-35B-A3B | — | — | — | CI extended | artifact |
| _pending_ | k8s-self-hosted | gemma-4-E4B-it | — | — | — | CI extended | artifact |

拡張候補の詳細: [MODEL_CANDIDATES_EXTENDED.md](MODEL_CANDIDATES_EXTENDED.md)

実測後、上表に行を追加し `vllm/overlays/*/model-patch.yaml` のフラグ変更理由を記載してください。
