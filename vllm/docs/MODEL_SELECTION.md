# vLLM 推論モデル選定

## 目的

`facebook/opt-125m` はスモークテスト用の極小モデルです。本番（kubeadm）とローカル（kind）で、VRAM・品質・運用性のバランスが取れたモデルへ移行します。

## 候補モデル（検証マトリクス）

| モデル | パラメータ | 推定 VRAM | HF ゲート | 日本語 | 用途 |
|--------|-----------|-----------|-----------|--------|------|
| `facebook/opt-125m` | 125M | ~0.5 GiB | なし | 弱い | 旧デフォルト（スモークのみ） |
| `Qwen/Qwen2.5-0.5B-Instruct` | 0.5B | ~1 GiB | なし | 良好 | **kind / CI スモーク** |
| `Qwen/Qwen2.5-1.5B-Instruct` | 1.5B | ~3 GiB | なし | 優秀 | **kubeadm 本番（採用）** |
| `meta-llama/Llama-3.2-1B-Instruct` | 1B | ~2 GiB | あり | 可 | 学習スタックと整合（要 HF_TOKEN） |
| `meta-llama/Llama-3.2-3B-Instruct` | 3B | ~6 GiB | あり | 可 | 品質↑、VRAM 逼迫の可能性 |
| `microsoft/Phi-3-mini-4k-instruct` | 3.8B | ~7 GiB | なし | 可 | 8 GiB GPU では余裕が少ない |

### 拡張候補（LFM / Qwen3.6 / Gemma4）

次世代モデルの検証マトリクスは [MODEL_CANDIDATES_EXTENDED.md](MODEL_CANDIDATES_EXTENDED.md) を参照。

| ファミリ | 代表モデル | 1 GPU 適合 |
|---------|-----------|------------|
| LFM2.5 | `LiquidAI/LFM2.5-1.2B-Instruct` | ◎ |
| Qwen3.6 | `Qwen/Qwen3.6-35B-A3B` | △（24GB+ GPU） |
| Gemma4 | `google/gemma-4-E4B-it` | △（text-only + 24GB+ 推奨） |

### クラスタ前提（`vllm/base/vllm-deployment.yaml`）

- GPU: `nvidia.com/gpu: 1` / `amd.com/gpu: 1`
- Pod memory: request 8 GiB / limit 16 GiB
- モデルキャッシュ PVC: 50 GiB

## 選定結果

| 環境 | 採用モデル | 理由 |
|------|-----------|------|
| **kubeadm（NVIDIA / AMD）** | `Qwen/Qwen2.5-1.5B-Instruct` | ゲートなし・日本語品質・1 GPU で安定・vLLM 公式サポート |
| **kind（検証）** | `Qwen/Qwen2.5-0.5B-Instruct` | ダウンロード/起動が速く、instruct 品質を維持 |

学習（finetune）も推論と同じ Qwen 系に統一しました。

| 環境 | BASE_MODEL |
|------|------------|
| kubeadm/finetune | `Qwen/Qwen2.5-1.5B-Instruct` |
| kind/finetune | `Qwen/Qwen2.5-0.5B-Instruct`（スモーク） |

LoRA 出力を推論に載せる場合は `VLLM_MODEL` をアダプタ付きローカルパスへ切り替えるか、`--enable-lora` を `VLLM_EXTRA_ARGS` に追加してください。

## ベンチマーク手順（候補比較）

```bash
# vLLM デプロイ済み・GPU ノードで実行
kubectl apply -k vllm/benchmark/
kubectl -n vllm exec -it deploy/vllm -- true 2>/dev/null || echo "ensure vllm deployment exists"

# 候補を順にデプロイ→計測（対話式）
./vllm/benchmark/scripts/compare_models.sh

# 単発ベンチ（現在デプロイ中のモデル）
kubectl -n vllm delete job vllm-benchmark --ignore-not-found
kubectl apply -k vllm/benchmark/
kubectl -n vllm logs -f job/vllm-benchmark
```

比較結果は `/tmp/vllm-bench/compare-<timestamp>/`（クラスタ内 Job）またはローカル実行時の `./vllm-bench-results/` に JSON で保存されます。

## チューニング（採用モデル向け）

overlay の `model-patch.yaml` に反映済み。詳細と実測ログは [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) を参照。

主な追加フラグ（v0）:

- `--enable-chunked-prefill` — 長コンテキストの TTFT 改善
- `--max-num-batched-tokens` — VRAM とスループットのバランス

### GPU 実測（CI）

セルフホスト runner 登録後:

```bash
# GitHub Actions → vLLM Model Benchmark → Run workflow
```

またはクラスタ上で `./vllm/benchmark/scripts/compare_models.sh`

ベンチ後に `max-num-seqs` と `--gpu-memory-utilization` を [benchmark/README.md](../benchmark/README.md) の手順で再調整してください。
