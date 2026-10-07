# vLLM ベンチマーク結果ログ

実測値は GPU クラスタまたは [vllm-model-benchmark workflow](../../.github/workflows/vllm-model-benchmark.yaml) で取得します。

## ローカル JSON 保管方針

`vllm/benchmark/results/*.json` は **gitignore 対象**（ローカル作業用の生データ）です。リポジトリに残すのは本ドキュメントの表のみです。

| 項目 | 方針 |
|------|------|
| 生 JSON の保存先 | `vllm/benchmark/results/`（ローカル・未コミット） |
| リポジトリに残すもの | 本ファイルのインライン表（代表メトリクス） |
| CI 成果物 | `vllm/benchmark/results/ci-artifacts/`（同様に gitignore） |
| 新規計測後 | JSON をローカル保存 → 本表を更新 → JSON はコミットしない |

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

#### default set（2026-06-11T01:19:21Z）

| HuggingFace ID | Ollama tag | tokens/s | total (s) | status | 備考 |
|----------------|------------|----------|-----------|--------|------|
| facebook/opt-125m | — | — | — | SKIP | マップ未登録 |
| Qwen/Qwen2.5-0.5B-Instruct | `qwen2.5:0.5b` | 65.71 | 1.66 | OK | eval_count=22 |
| Qwen/Qwen2.5-1.5B-Instruct | `qwen2.5:1.5b` | 32.26 | 3.39 | OK | eval_count=49 |

#### extended set（2026-06-11T01:22:09Z — 初回）

| HuggingFace ID | Ollama tag | tokens/s | total (s) | status | 備考 |
|----------------|------------|----------|-----------|--------|------|
| LiquidAI/LFM2.5-350M | `sam860/LFM2:350m` | 83.54 | 4.43 | OK | eval_count=81 |
| LiquidAI/LFM2.5-1.2B-Instruct | `sam860/LFM2:1.2b` | 40.05 | 4.34 | OK | eval_count=65 |
| Qwen/Qwen3.6-35B-A3B | `qwen3.6:rx5700` | 12.02 | 85.75 | OK | slow, no OOM |
| google/gemma-4-E2B-it | `gemma4:rx5700` | 10.39 | 57.83 | OK | E2B/E4B 同一タグ |
| google/gemma-4-E4B-it | `gemma4:rx5700` | 10.39 | 57.83 | OK | 1 回計測を共有 |

#### extended set（2026-06-11T00:25:26Z — 再計測）

| HuggingFace ID | Ollama tag | tokens/s | total (s) | status | 備考 |
|----------------|------------|----------|-----------|--------|------|
| LiquidAI/LFM2.5-350M | `sam860/LFM2:350m` | 68.95 | 3.15 | OK | eval_count=94 |
| LiquidAI/LFM2.5-1.2B-Instruct | `sam860/LFM2:1.2b` | 31.34 | 4.49 | OK | eval_count=57 |
| Qwen/Qwen3.6-35B-A3B | `qwen3.6:rx5700` | 10.43 | 86.65 | OK | eval_count=256 |
| google/gemma-4-E2B-it | `gemma4:rx5700` | 8.41 | 60.15 | OK | E2B/E4B 同一タグ |
| google/gemma-4-E4B-it | `gemma4:rx5700` | 8.41 | 60.15 | OK | 1 回計測を共有 |

> **Note:** `google/gemma-4-E2B-it` と `google/gemma-4-E4B-it` はどちらも `gemma4:rx5700` タグを参照するため、上表の数値は同一ベンチ実行の結果です。

#### スモーク（`qwen2.5:0.5b` · 2026-06-11）

| Ollama tag | tokens/s | total (s) | 備考 |
|------------|----------|-----------|------|
| `qwen2.5:0.5b` | 18.13 | 2.79 | eval_count=8（超短応答・参考値のみ） |

**CI:** [.github/workflows/vllm-ollama-benchmark.yaml](../../.github/workflows/vllm-ollama-benchmark.yaml)（マップ検証は ubuntu-latest、実測は self-hosted Windows + Ollama）

### マルチモデル簡易ベンチ（`ollama-rx5700` スイープ · 2026-06-11）

単発 `/api/generate`、プロンプト・`num_predict` はスクリプト既定。

| Ollama tag | tokens/s | total (s) | status | 備考 |
|------------|----------|-----------|--------|------|
| `sam860/LFM2:1.2b` | 37.38 | 4.21 | OK | eval_count=143 |
| `qwen2.5:1.5b` | 28.43 | 11.23 | OK | eval_count=256 |
| `qwen2.5:3b` | 16.27 | 14.09 | OK | eval_count=114 |
| `gemma4:rx5700` | 9.45 | 54.51 | OK | eval_count=256 |
| `qwen3.6:rx5700` | 10.02 | 97.25 | OK | eval_count=256 |

### OpenAI API ベンチ（`bench_ollama_openai.ps1`）

エンドポイント: `http://127.0.0.1:11434/v1/chat/completions`（Ollama OpenAI 互換）

```powershell
.\scripts\bench_ollama_openai.ps1 -HfId Qwen/Qwen2.5-1.5B-Instruct
```

#### 標準タグ（初回スモーク · 2026-06-11）

| Ollama tag | p50 (ms) | p99 (ms) | output tok/s | concurrency | max_tokens | 備考 |
|------------|----------|----------|--------------|-------------|------------|------|
| `qwen2.5:0.5b` | 584.71 | 585.47 | 54.36 | 4 | 24 | samples=3 |
| `qwen2.5:1.5b` | 1270.76 | 1352.08 | 28.79 | 4 | 32 | samples=3 |
| `qwen2.5:1.5b` | 1220.45 | 1316.06 | 27.86 | 4 | 32 | 再計測 08:23Z |
| `sam860/LFM2:1.2b` | 1846.49 | 92517.27 | 37.87 | 4 | 64 | p99 外れ値あり |

#### `:rx5700` Modelfile タグ（`qwen2.5:0.5b-rx5700`）

| 計測時刻 (UTC) | p50 (ms) | p99 (ms) | output tok/s | concurrency | max_tokens | req |
|----------------|----------|----------|--------------|-------------|------------|-----|
| 05:47:20 | 719.49 | 724.89 | 55.43 | 4 | 32 | 3 |
| 07:52:14 | 754.43 | 765.52 | 56.65 | 4 | 32 | 5 |
| 08:50:28 | 1173.72 | 1193.70 | 60.04 | 4 | 64 | 20 |
| 09:00:33 | 1274.31 | 1381.16 | 58.23 | 4 | 64 | 20 |
| 10:29:51 | 1394.27 | 1516.58 | 56.61 | 4 | 64 | 20 |

> **Note:** `:rx5700` タグは Modelfile チューニング後のモデル。`max_tokens=64` フルランでは p50 が ~1.2–1.4 s と上がるが、スループットは ~56–60 tok/s で安定。

#### LFM2 長文生成（単発 `/api/generate` · 2026-06-11T00:14:12Z）

OpenAI ベンチ形式ではなく、長応答の単発計測（`sam860/LFM2:1.2b`）。

| 項目 | 値 |
|------|-----|
| eval_count | 111 tokens |
| eval_duration | 2.89 s |
| total_duration | 3.21 s |
| **eval tok/s** | **38.4** |
| done_reason | stop |

> **Note:** k8s vLLM 実測（p50/p99/tok/s）は引き続き _pending_ — [vLLM Model Benchmark](../../.github/workflows/vllm-model-benchmark.yaml) + GPU クラスタが必要。

## macOS Apple Silicon (vLLM CPU Docker) · 2026-06-11

**環境:** Mac arm64, Docker Desktop, `openeuler/vllm-cpu:0.20.1-oe2403sp3`  
**経路:** kind/kubectl 未導入のため Docker 直起動（[`scripts/bench_vllm_macos_cpu.sh`](../../scripts/bench_vllm_macos_cpu.sh)）  
**比較 JSON:** [../benchmark/results/vllm-cpu-macos-compare-2026-06-11.json](../benchmark/results/vllm-cpu-macos-compare-2026-06-11.json)

プロンプト: _"Write a short paragraph about Kubernetes GPU scheduling."_ · `max_tokens=64` · `concurrency=2`

| モデル | p50 (ms) | p99 (ms) | output tok/s | req/s | status | 備考 |
|--------|----------|----------|--------------|-------|--------|------|
| facebook/opt-125m | 430.25 | 451.2 | 279.04 | 4.36 | OK | completions API（chat template なし） |
| Qwen/Qwen2.5-0.5B-Instruct | 1562.69 | 1621.26 | 71.12 | 1.11 | OK | **Mac vLLM CPU 推奨**（instruct / kind デフォルト） |
| LiquidAI/LFM2.5-350M | — | — | — | — | TIMEOUT | 2400s 以内に health 未達（HF ダウンロード + CPU ロード） |
| Qwen/Qwen2.5-1.5B-Instruct | — | — | — | — | TIMEOUT | 同上 |

**推奨:** `Qwen/Qwen2.5-0.5B-Instruct` — instruct 対応で唯一安定起動。opt-125m は 3.9× 高速だが base モデルのみ。

**再現:**

```bash
docker pull openeuler/vllm-cpu:0.20.1-oe2403sp3
./scripts/bench_vllm_macos_cpu.sh
# 単体: MODELS="Qwen/Qwen2.5-0.5B-Instruct" ./scripts/bench_vllm_macos_cpu.sh
```

## deploy-note GTX1650 · MoE (llmfit) · 2026-10-07 (vLLM稼働中: GPU空き~1GB)

**環境:** deploy-note (i7-12650H, WSL 8 vCPU / 19 GB, GTX 1650 4GB)。Windows ネイティブ Ollama 0.35.1 (`localhost:11434`)、**CPU 専用**（`PARAMETER num_gpu 0` の `-cpu` タグ）。本番 vLLM が VRAM ~3 GB を保持しており（WSL nvidia-smi で空き 885 MiB）、Windows 側からはその使用分が見えない（空き 3.2 GiB と誤認）ため、窓の外では GPU オフロードしない。  
**選定:** [llmfit](https://github.com/AlexsJones/llmfit) v1.1.16 の MoE 行（`is_moe`）から、公式・Ollama で入手可・Windows 側の空き RAM (4.5–6 GB) に収まるもの。詳細: [llm-experiments/moe/results-summary/llmfit-deploy-note.md](../../llm-experiments/moe/results-summary/llmfit-deploy-note.md)  
**計測:** [`llm-experiments/moe/scripts/bench_ollama.sh`](../../llm-experiments/moe/scripts/bench_ollama.sh)（→ `scripts/bench_ollama_openai.sh` → `bench_vllm.py`）、品質は [`eval_quality.py`](../../llm-experiments/moe/scripts/eval_quality.py)（30 問、temperature 0）

プロンプト: _"Write a short paragraph about Kubernetes GPU scheduling."_ · `max_tokens=64` · latency 10 samples · throughput 12 req / concurrency 2 · decode tok/s は単発 `/api/generate` (`num_predict=128`)

| Ollama tag | HF モデル (総/活性) | llmfit 予測 tok/s (0G / 1G / 4G) | 実測 decode tok/s | output tok/s (c=2) | p50 (ms) | p99 (ms) | QA 正答 | 備考 |
|------------|------|------|------|------|------|------|------|------|
| `granite3.1-moe:3b-cpu` | granite-3.1-3b-a800m-instruct (3.3B/0.8B) | 44.5 / 56.7 / 75.4 | **45.9** | 45.4 | 1454.39 | 1496.16 | 27/30 (90.0%) [初回 25/30] | Q4_K_M 2.0 GB、prompt 2491 tok/s |
| `granite4:tiny-h-cpu` | granite-4.0-h-tiny (6.9B/1B, Mamba-2 hybrid) | 36.5 / 46.5 / 61.1 | **25.5** | 24.4 | 2682.78 | 2786.51 | 29/30 (96.7%) [初回 29/30] | Q4_K_M 4.2 GB、prompt 415 tok/s |
| `granite3-moe:1b` / `granite3.1-moe:1b` | granite-3.x-1b-a400m (1.3B/0.4B) | 91.7 / 150.1 / 144.9 | — | — | — | — | — | **LOAD FAIL**: Ollama 0.35.1 llama-server `ggml-impl.h:330: fatal error` (0xc0000409)、CPU/GPU とも |

LoRA ベースモデルの基準値（transformers、CPU bf16、`eval_quality.py --hf-model`）:

| モデル | QA 正答 | held-out loss (sft_heldout 50 行) | 備考 |
|--------|---------|------|------|
| ibm-granite/granite-3.1-1b-a400m-instruct | 17/30 (56.7%) [初回 17/30] | 1.8966 | LoRA 前（transformers の CPU greedy は再実行でも同一応答）。窓内の GPU fp16 で再計測して before/after を比較する |

> **QA 採点:** 数値の答えは NFKC 後のテキストで桁境界一致（`(?<!\d)96(?!\d)`、桁区切りカンマは除去）、それ以外は正規化部分一致。表の値はこの採点での再実行（v2）。初回の応答を新しい採点で採点し直しても変化なし（25 / 29 / 17）。granite3.1-moe の 25→27 は Ollama CPU 推論の実行間ゆらぎ（temperature 0 でも応答が変わる: ja-02 / in-06 が正解に、ja-06 は誤答の内容が変化）なので、±2 問程度の差は有意とみなさない。

> **Note:** llmfit の 0G 予測は Q8_0 前提（実測は Q4_K_M）、1G/4G は MoE エキスパートの VRAM/RAM 分割前提。granite3.1-moe はほぼ予測どおり、granite4 (hybrid) は予測の約 7 割。gpt-oss:20b (13.8 GB) / qwen3:30b-a3b (~18 GB) は llmfit 上 4G で Good だが Windows 側 Ollama の空き RAM に収まらないため未計測。vLLM 窓（GPU 全開放）での再計測と LoRA は後続。

## 実測ログ（Kubernetes / vLLM）

| 日付 | 環境 | モデル | p50_ms | p99_ms | tok/s | 実行者 | 備考 |
|------|------|--------|--------|--------|-------|--------|------|
| _pending_ | k8s-self-hosted | Qwen2.5-1.5B | — | — | — | CI workflow | artifact |
| _pending_ | k8s-self-hosted | LFM2.5-1.2B-Instruct | — | — | — | CI extended | artifact |
| _pending_ | k8s-self-hosted | Qwen3.6-35B-A3B | — | — | — | CI extended | artifact |
| _pending_ | k8s-self-hosted | gemma-4-E4B-it | — | — | — | CI extended | artifact |

拡張候補の詳細: [MODEL_CANDIDATES_EXTENDED.md](MODEL_CANDIDATES_EXTENDED.md)

実測後、上表に行を追加し `vllm/overlays/*/model-patch.yaml` のフラグ変更理由を記載してください。
