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

## 実測ログ

| 日付 | 環境 | モデル | p50_ms | p99_ms | tok/s | 実行者 | JSON |
|------|------|--------|--------|--------|-------|--------|------|
| _pending_ | k8s-self-hosted | Qwen2.5-1.5B | — | — | — | CI workflow | artifact |
| _pending_ | k8s-self-hosted | LFM2.5-1.2B-Instruct | — | — | — | CI extended | artifact |
| _pending_ | k8s-self-hosted | Qwen3.6-35B-A3B | — | — | — | CI extended | artifact |
| _pending_ | k8s-self-hosted | gemma-4-E4B-it | — | — | — | CI extended | artifact |

拡張候補の詳細: [MODEL_CANDIDATES_EXTENDED.md](MODEL_CANDIDATES_EXTENDED.md)

実測後、上表に行を追加し `vllm/overlays/*/model-patch.yaml` のフラグ変更理由を記載してください。
