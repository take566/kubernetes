# vLLM Performance Benchmarking (`perf` + API load test)

このディレクトリは **Linux `perf`**（性能カウンタ）と **OpenAI 互換 API 負荷テスト** を組み合わせ、vLLM 推論のベースライン計測とチューニング検証を行うためのワークフローです。

リポジトリ内に別名の `perf` ツールは存在しないため、本セットアップでは **カーネル同梱の `perf stat` / `perf record`** を指します。

## 構成

| ファイル | 役割 |
|----------|------|
| `scripts/bench_vllm.py` | レイテンシ (p50/p99)・スループット (tokens/s) 計測 |
| `scripts/run_benchmark.sh` | ベンチ実行 + 任意で `perf stat` でラップ |
| `scripts/perf_stat_server.sh` | vLLM サーバプロセスへの `perf stat` / `perf record` |
| `benchmark-configmap.yaml` | ベンチパラメータ |
| `benchmark-job.yaml` | クラスタ内から vLLM Service へ負荷をかける Job |
| `model-candidates.yaml` | 比較候補モデル一覧（JSON） |
| `scripts/compare_models.sh` | 候補を順にデプロイしてベンチマーク比較 |
| `benchmark-perf-job.yaml` | GPU ノード上でサーバ側 `perf`（privileged / hostPID） |

## 前提

1. vLLM 推論が稼働していること（`kubectl apply -k vllm/overlays/kubeadm/` または `vllm/overlays/kubeadm/amd/`）
2. ベンチ Job は **GPU 不要**（CPU のみのクライアント）
3. サーバ側 `perf` は **vLLM と同一 GPU ノード** にスケジュールする必要あり

## クイックスタート（クラスタ内）

### 1. ベースライン計測（チューニング前）

```bash
# vLLM デプロイ済みであること
kubectl apply -k vllm/benchmark/

kubectl -n vllm wait --for=condition=complete job/vllm-benchmark --timeout=15m
kubectl -n vllm logs job/vllm-benchmark
```

出力例（JSON）:

```json
{
  "latency": { "p50_ms": 120.5, "p99_ms": 450.2, "mean_ms": 145.0, "count": 20 },
  "throughput": {
    "output_tokens_per_second": 85.3,
    "requests_per_second": 1.2,
    "concurrency": 4
  }
}
```

結果を保存:

```bash
kubectl -n vllm logs job/vllm-benchmark > baseline-before.json
```

### 2. チューニング後の再計測

`vllm-configmap.yaml` の `VLLM_EXTRA_ARGS` を更新 → `rollout restart` → 同じ Job を再実行:

```bash
kubectl -n vllm delete job vllm-benchmark --ignore-not-found
kubectl apply -k vllm/benchmark/
kubectl -n vllm logs -f job/vllm-benchmark > baseline-after.json
```

### 3. 複数モデル比較（選定用）

```bash
chmod +x vllm/benchmark/scripts/compare_models.sh

# デフォルト: opt-125m → Qwen2.5-0.5B → Qwen2.5-1.5B
./vllm/benchmark/scripts/compare_models.sh

# 拡張候補（LFM + Qwen3.6 + Gemma4）
COMPARE_SET=extended ./vllm/benchmark/scripts/compare_models.sh

# 候補を指定（model-profiles.json の extra_args を自動適用）
MODELS="LiquidAI/LFM2.5-1.2B-Instruct google/gemma-4-E4B-it" \
  ./vllm/benchmark/scripts/compare_models.sh
```

プロファイル定義: `model-profiles.json` · ドキュメント: [../docs/MODEL_CANDIDATES_EXTENDED.md](../docs/MODEL_CANDIDATES_EXTENDED.md)

結果は `./vllm-bench-results/compare-<timestamp>/` に JSON 保存されます。選定ドキュメント: [../docs/MODEL_SELECTION.md](../docs/MODEL_SELECTION.md)

### ローカル Ollama / Windows ベンチ

`bench_ollama_openai.ps1` や `compare_models_ollama.ps1` の生出力は `vllm/benchmark/results/*.json` に保存しますが、**git にはコミットしません**（`.gitignore` 対象）。代表メトリクスは [../docs/BENCHMARK_RESULTS.md](../docs/BENCHMARK_RESULTS.md) の表に追記してください。

### CI（セルフホスト runner）

GPU 付きクラスタに ARC runner がある場合:

1. GitHub → Actions → **vLLM Model Benchmark** → Run workflow
2. 成果物 `vllm-benchmark-<run_id>` から JSON を取得（ローカル保存可、`results/` は gitignore）
3. [../docs/BENCHMARK_RESULTS.md](../docs/BENCHMARK_RESULTS.md) の実測ログ表にインラインで追記（JSON リンクは不要）

### 4. 並列度スイープ（バッチサイズ相当）

`benchmark-configmap.yaml` の `BENCH_CONCURRENCY` を `2` → `4` → `8` と変更し、スループットと p99 のトレードオフを記録します。

## Linux `perf` の使い方

### A. クライアント側（ベンチ Job 内）

`benchmark-configmap.yaml`:

```yaml
PERF_ENABLE: "true"
```

ベンチマークプロセス自体の CPU カウンタを取得します（GPU カーネルは主にサーバ側で計測）。

### B. サーバ側（vLLM プロセス）

vLLM Pod のノード名を確認:

```bash
NODE=$(kubectl -n vllm get pod -l app=vllm -o jsonpath='{.items[0].spec.nodeName}')
echo "Schedule perf Job on: $NODE"
```

`benchmark-perf-job.yaml` の `nodeSelector.kubernetes.io/hostname` のコメントを解除して適用:

```bash
# 編集後
kubectl apply -f vllm/benchmark/benchmark-perf-job.yaml
kubectl -n vllm logs job/vllm-benchmark-perf
```

`PERF_MODE=record` にすると `perf.data` と `perf.script` が生成されます。

### C. Flamegraph（ワークステーション）

[Brendan Gregg FlameGraph](https://github.com/brendangregg/FlameGraph) をインストールした Linux/macOS 上で:

```bash
kubectl -n vllm cp <perf-pod>:/tmp/vllm-perf/perf.script.<timestamp>.txt ./perf.script.txt
stackcollapse-perf.pl perf.script.txt | flamegraph.pl > vllm-flame.svg
```

ボトルネックの目安:

- Python/GIL 待ちが多い → `--max-num-seqs` 調整、ログ無効化
- `hip` / `cuda` カーネルが少ない → GPU 利用率不足、`--gpu-memory-utilization` やバッチ増
- `memcpy` / PCIe 多い → モデルサイズ・`--max-model-len` 見直し

## AMD GPU ノードでの手動実行

Port-forward または NodePort 経由:

```bash
kubectl -n vllm port-forward svc/vllm 8000:8000 &
export VLLM_BASE_URL=http://127.0.0.1:8000
export VLLM_MODEL=Qwen/Qwen2.5-1.5B-Instruct

pip install aiohttp
python3 vllm/benchmark/scripts/bench_vllm.py

# perf 付き（linux-tools インストール済みノード）
PERF_ENABLE=true ./vllm/benchmark/scripts/run_benchmark.sh
```

サーバ側 perf（GPU ノードに SSH できる場合）:

```bash
PID=$(pgrep -f 'vllm.entrypoints.openai.api_server' | head -1)
sudo perf stat -d -p "$PID" -- sleep 30
```

## チューニングノブ（ConfigMap `VLLM_EXTRA_ARGS`）

| フラグ | NVIDIA 目安 | AMD ROCm 目安 | 効果 |
|--------|-------------|---------------|------|
| `--gpu-memory-utilization` | 0.90–0.95 | 0.85–0.92 | KV キャッシュ容量・同時 seq 数 |
| `--max-num-seqs` | 128–512 | 64–128 | 同時リクエスト上限 |
| `--max-model-len` | モデルに合わせる | 4096 から開始 | メモリとレイテンシ |
| `--enable-prefix-caching` | on | on | 共有プレフィックスで再計算削減 |
| `--disable-log-requests` | on | on | I/O オーバーヘッド削減 |
| `--tensor-parallel-size` | GPU 数 | GPU 数 | マルチ GPU 時のみ |

AMD 追加 env（Deployment）:

| 変数 | 値 | 効果 |
|------|-----|------|
| `PYTORCH_HIP_ALLOC_CONF` | `expandable_segments:True` | HIP メモリ断片化軽減 |
| `HIP_VISIBLE_DEVICES` | `0` | デバイス固定（マルチ GPU 時） |

## 期待される改善（参考値）

モデル・GPU により異なります。`Qwen/Qwen2.5-1.5B-Instruct`（kubeadm デフォルト）の目安:

| 変更 | 期待 |
|------|------|
| `--disable-log-requests` | p99 数 % 改善 |
| `--enable-prefix-caching` | 同一プレフィックス負荷で tokens/s +10–30% |
| `--max-num-seqs` 最適化 | スループット最大化、過大で p99 悪化 |
| AMD `--gpu-memory-utilization` 0.92 | OOM 手前まで KV 確保 |

**必ずベースライン JSON と比較してから本番値に反映してください。**

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| Job が `Connection refused` | vLLM readiness 待ち。`BENCH_HEALTH_TIMEOUT_S` を増やす |
| `perf: command not found` | `linux-perf` / `linux-tools-generic` をイメージに追加済みか確認 |
| サーバ perf が PID 未検出 | `nodeSelector` で vLLM と同一ノードに配置 |
| `Insufficient amd.com/gpu` | ベンチ Job は GPU 不要。誤って GPU 要求していないか確認 |

## 再実行

```bash
kubectl -n vllm delete job vllm-benchmark vllm-benchmark-perf --ignore-not-found
kubectl apply -k vllm/benchmark/
```
