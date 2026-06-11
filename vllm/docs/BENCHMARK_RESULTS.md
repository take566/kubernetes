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

## Windows AMD RX 5700 (Ollama) · 2026-06-11

**環境:** Windows ネイティブ Ollama, AMD Radeon RX 5700 8GB (gfx1010)  
**経路:** WSL ROCm は **gfx1010 非対応**のため GPU 推論は **Ollama が主経路**（vLLM/WSL ROCm は使わない）。詳細: [overlays/windows-local/README.md](../overlays/windows-local/README.md)

### セットアップ・計測スクリプト

| スクリプト | 用途 |
|-----------|------|
| [`scripts/setup-ollama-rx5700.ps1`](../../scripts/setup-ollama-rx5700.ps1) | モデル pull + `:rx5700` Modelfile 作成 |
| [`scripts/compare_models_ollama.ps1`](../../scripts/compare_models_ollama.ps1) | HF 候補 → Ollama タグ比較（`/api/generate`） |
| [`scripts/bench_ollama_openai.ps1`](../../scripts/bench_ollama_openai.ps1) | OpenAI 互換 API ベンチ（`bench_vllm.py` 互換） |

マップ定義: [`vllm/benchmark/ollama-model-map.json`](../benchmark/ollama-model-map.json)

### スループット比較（`compare_models_ollama.ps1`）

プロンプト: _"Explain Kubernetes GPU scheduling in two short sentences."_ · `num_predict=256` · `/api/generate`

| HuggingFace ID | Ollama tag | tokens/s | status | 備考 |
|----------------|------------|----------|--------|------|
| facebook/opt-125m | — | — | SKIP | マップ未登録 |
| Qwen/Qwen2.5-0.5B-Instruct | `qwen2.5:0.5b` | 65.71 | OK | default set |
| Qwen/Qwen2.5-1.5B-Instruct | `qwen2.5:1.5b` | 32.26 | OK | default set |
| LiquidAI/LFM2.5-350M | `sam860/LFM2:350m` | 83.54 | OK | extended set |
| LiquidAI/LFM2.5-1.2B-Instruct | `sam860/LFM2:1.2b` | 40.05 | OK | extended set |
| Qwen/Qwen3.6-35B-A3B | `qwen3.6:rx5700` | 12.02 | OK | slow, no OOM |
| google/gemma-4-E2B-it | `gemma4:rx5700` | 10.39 | OK | E2B/E4B 同一タグ |
| google/gemma-4-E4B-it | `gemma4:rx5700` | 10.39 | OK | E2B/E4B 同一タグ（1 回計測を共有） |

> **Note:** `google/gemma-4-E2B-it` と `google/gemma-4-E4B-it` はどちらも `gemma4:rx5700` タグを参照するため、上表の数値は同一ベンチ実行の結果です。

**JSON（default set）:** [../benchmark/results/ollama-compare-2026-06-11T101916.json](../benchmark/results/ollama-compare-2026-06-11T101916.json)  
**JSON（extended set）:** [../benchmark/results/ollama-compare-2026-06-11T101936.json](../benchmark/results/ollama-compare-2026-06-11T101936.json)  
**CI:** [.github/workflows/vllm-ollama-benchmark.yaml](../../.github/workflows/vllm-ollama-benchmark.yaml)（マップ検証は ubuntu-latest、実測は self-hosted Windows + Ollama）

### OpenAI API ベンチ（`bench_ollama_openai.ps1`）

エンドポイント: `http://127.0.0.1:11434/v1/chat/completions`（Ollama OpenAI 互換）

```powershell
.\scripts\bench_ollama_openai.ps1 -HfId Qwen/Qwen2.5-1.5B-Instruct
```

| Ollama tag | p50 (ms) | p99 (ms) | output tok/s | concurrency | JSON |
|------------|----------|----------|--------------|-------------|------|
| `qwen2.5:0.5b` | 584.71 | 585.47 | 54.36 | 4 | [bench-ollama-openai-qwen2.5_0.5b-2026-06-11T101437.json](../benchmark/results/bench-ollama-openai-qwen2.5_0.5b-2026-06-11T101437.json) |
| `qwen2.5:1.5b` | 1270.76 | 1352.08 | 28.79 | 4 | [bench-ollama-openai-qwen2.5_1.5b-2026-06-11T101858.json](../benchmark/results/bench-ollama-openai-qwen2.5_1.5b-2026-06-11T101858.json) |
| `sam860/LFM2:1.2b` | 1846.49 | 92517.27 | 37.87 | 4 | [bench-ollama-openai-sam860_LFM2_1.2b-2026-06-11T101935.json](../benchmark/results/bench-ollama-openai-sam860_LFM2_1.2b-2026-06-11T101935.json) |

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
