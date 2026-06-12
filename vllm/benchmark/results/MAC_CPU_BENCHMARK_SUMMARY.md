# Mac vLLM / CPU ベンチマーク要約 (2026-06-11 UTC)

## 環境

| 項目 | 値 |
|------|-----|
| プラットフォーム | macOS 26.5.1 / **arm64** / 24 GiB RAM |
| kind / kubectl | 未インストール → `vllm/overlays/kind/cpu/` は未適用（HF ID は `model-candidates.yaml` と整合） |
| Docker | 利用可 (`openeuler/vllm-cpu:0.20.1-oe2403sp3`, **linux/arm64**) |
| Ollama | 利用可 (`http://127.0.0.1:11434/v1`) — **Metal 推論（フォールバック／比較用）** |

## 計測条件（統一）

- スクリプト: `vllm/benchmark/scripts/bench_vllm.py`
- `max_tokens=64`, `latency_samples=10`, `throughput_requests=20`
- プロンプト: Kubernetes GPU scheduling（`bench_ollama_openai.sh` / `bench_vllm_macos_cpu.sh` 既定）
- vLLM CPU: `concurrency=2`（`bench_vllm_macos_cpu.sh` 既定）
- Ollama: `concurrency=4`（`bench_ollama_openai.sh` 既定）

## 今回の実行結果

### A. vLLM CPU（Docker — 本命経路）

| モデル (HF) | p50 (ms) | p99 (ms) | 出力 tok/s | req/s | 結果 JSON |
|-------------|----------|----------|------------|-------|-----------|
| `facebook/opt-125m` | **419.7** | 486.8 | **286.3** | 4.47 | `bench-vllm-cpu-facebook_opt-125m-2026-06-11T213506Z.json` |

> **ポート注意:** ホスト `:8000` が SSH 転送と競合したため、今回は `VLLM_HOST_PORT=8001` で計測。

### B. Ollama OpenAI 互換 API（**フォールバック / Metal 比較** — ラベル: `ollama-openai-metal`）

| モデル (Ollama) | p50 (ms) | p99 (ms) | 出力 tok/s | req/s | 結果 JSON |
|-----------------|----------|----------|------------|-------|-----------|
| `qwen2.5:0.5b` | 540.2 | 547.3 | 106.4 | 1.66 | `bench-ollama-openai-qwen2.5_0.5b-2026-06-11T210135.json` |
| `sam860/LFM2:1.2b` | 814.0 | 912.9 | 86.4 | 1.35 | `bench-ollama-openai-sam860_LFM2_1.2b-2026-06-11T212513.json` |

### 参考（同一リポ内・過去 vLLM CPU 実行）

| モデル (HF) | p50 (ms) | 出力 tok/s | 結果 JSON |
|-------------|----------|------------|-----------|
| `Qwen/Qwen2.5-0.5B-Instruct` | 1562.7 | 71.1 | `bench-vllm-cpu-Qwen__Qwen2.5-0.5B-Instruct-2026-06-11T084903Z.json` |


## Gemma / Qwen / LFM ファミリー比較 (2026-06-11 UTC)

ユーザー指定の **gema4 → gemma4**、**quen3.6 → Qwen 3.x**、**lfm → LFM** を Mac Ollama (Metal) で計測。パラメータ規模はファミリー間で異なる（公平な同一サイズ比較ではない）。

### ブロッカー・代替

| 意図 | 結果 |
|------|------|
| `qwen3.6` (Ollama) | **2026-06-12 解決:** `ollama pull qwen3.6` 成功（≈23 GB, 36B MoE Q4_K_M）。サブタグ `qwen3.6:8b` 等は manifest なし。`qwen3:8b` は別モデル（≈5.2 GB） |
| `gemma3:4b` / `gemma2:2b` | 未 pull（`gemma4:latest` は既存 8B Q4） |
| vLLM CPU Docker + Gemma/LFM | **未実施** — HF 上の Gemma4/LFM は vLLM CPU スモーク未検証；Qwen のみ `Qwen/Qwen2.5-0.5B-Instruct` 再計測 |

### Ollama (`bench_ollama_openai.sh`, concurrency=4)

| ファミリー | Ollama タグ | 規模 (参考) | p50 (ms) | p99 (ms) | 出力 tok/s | req/s | 結果 JSON |
|------------|-------------|-------------|----------|----------|------------|-------|-----------|
| **LFM** | `sam860/LFM2:1.2b` | ~1.2B | **779.0** | 784.0 | **75.8** | **1.18** | `bench-ollama-openai-sam860_LFM2_1.2b-2026-06-11T214640.json` |
| **Gemma** | `gemma4:latest` | 8B Q4_K_M | 2843.3 | 2872.5 | 22.2 | 0.35 | `bench-ollama-openai-gemma4_latest-2026-06-11T214716.json` |
| **Qwen** | `qwen3.5:9b` | 9B | 4544.4 | 4580.0 | 14.6 | 0.23 | `bench-ollama-openai-qwen3.5_9b-2026-06-11T214907.json` |
| **Qwen** | `qwen3.6` | 36B MoE (Q4) | 12017.1 | 34444.4 | 12.4 | 0.19 | `bench-ollama-openai-qwen3.6-2026-06-12T010933.json` |

> Ollama JSON は `.gitignore` 対象（`bench-ollama-openai-*.json`）。数値は上記ファイルから再現可能。

### vLLM CPU（Qwen のみ・参考）

| モデル (HF) | p50 (ms) | 出力 tok/s | req/s | 結果 JSON |
|-------------|----------|------------|-------|-----------|
| `Qwen/Qwen2.5-0.5B-Instruct` | 1560.5 | 75.0 | 1.17 | `bench-vllm-cpu-Qwen_Qwen2.5-0.5B-Instruct-2026-06-11T224804Z.json` |

### この 3 ファミリーでの Mac 推奨

**Ollama Metal では `sam860/LFM2:1.2b` が最速**（最低 p50・最高 tok/s）。Gemma4 8B・Qwen3.5 9B は同一ベンチ条件下で遅いが、モデルサイズが大きいため品質とのトレードオフ。`qwen3.6` は計測済み（36B MoE・最大 p50）；Mac 24GB ではロード/初回が重い。日常比較は `qwen3.5:9b` または `qwen2.5:0.5b` も検討。

```bash
./scripts/bench_ollama_openai.sh -m sam860/LFM2:1.2b
./scripts/bench_ollama_openai.sh -m gemma4:latest
./scripts/bench_ollama_openai.sh -m qwen3.5:9b
./scripts/bench_ollama_openai.sh -m qwen3.6
```

## 推奨

| 目的 | 推奨 | 理由 |
|------|------|------|
| **vLLM CPU 挙動の検証（Mac / kind 代替）** | Docker + `facebook/opt-125m` スモーク → `Qwen/Qwen2.5-0.5B-Instruct` | overlay 推奨 tier と一致；今回 opt-125m で **286 tok/s** |
| **Mac 上の高速イテレーション** | Ollama + `qwen2.5:0.5b`（Metal） | セットアップ最短；品質は Instruct 系 |
| **1.2B クラスの Metal 比較** | Ollama + `sam860/LFM2:1.2b` | p50 814 ms / 86 tok/s（vLLM CPU Qwen 0.5B より体感速いが、vLLM 直比較ではない） |

**総合:** Mac では **vLLM 検証 = `bench_vllm_macos_cpu.sh` + `VLLM_HOST_PORT=8001`（8000 競合時）**、**日常ベンチ = Ollama（明示的フォールバック）**。

## 再現

```bash
cd /Users/tmf/kubernetes

# vLLM CPU（8000 が塞がっている場合）
VLLM_HOST_PORT=8001 MODELS="facebook/opt-125m" ./scripts/bench_vllm_macos_cpu.sh

# Ollama（フォールバック / Metal）
./scripts/bench_ollama_openai.sh -m qwen2.5:0.5b
./scripts/bench_ollama_openai.sh -m sam860/LFM2:1.2b
```

