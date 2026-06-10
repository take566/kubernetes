# vLLM OpenAI-Compatible API Server

Kubernetes 上で [vLLM](https://docs.vllm.ai/) の OpenAI 互換 API サーバーと、AMD ROCm 向け LoRA ファインチューニング Job を動かすためのマニフェストです。

## 前提条件

| 項目 | 説明 |
|------|------|
| **GPU ノード（推論・NVIDIA）** | NVIDIA GPU（`nvidia.com/gpu`） |
| **GPU ノード（推論・AMD / 学習）** | ROCm 対応 AMD GPU（`amd.com/gpu`） |
| **Device Plugin** | NVIDIA: [k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) / AMD: [ROCm k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin) または [AMD GPU Operator](https://instinct.docs.amd.com/projects/gpu-operator/) |
| **ストレージ** | モデルキャッシュ・学習データ・チェックポイント用 PV |
| **モデル** | 推論デフォルト: `facebook/opt-125m`。学習デフォルト: `meta-llama/Llama-3.2-1B-Instruct`（要 HF トークンの場合あり） |
| **Hugging Face トークン** | ゲート付きモデル利用時は `vllm-secret.example.yaml` をコピーして Secret を作成 |

### GPU リソース名（AMD）

AMD GPU Device Plugin は通常 **`amd.com/gpu`** を allocatable リソースとして公開します（`single` 命名戦略）。GPU パーティション利用時は `amd.com/cpx_nps4` など混在命名になる場合があります（[AMD Device Plugin 設定](https://instinct.docs.amd.com/projects/k8s-device-plugin/en/latest/user-guide/configuration.html)）。

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,AMD_GPU:.status.capacity.'amd\.com/gpu'
```

Node Labeller 導入時は `amd.com/gpu.present`、`amd.com/gpu.vram` などのラベルで `nodeSelector` できます。

---

## デプロイ

### 推論: NVIDIA（デフォルト）

```bash
kubectl apply -k vllm/
```

### 推論: AMD ROCm

公式 ROCm イメージ `vllm/vllm-openai-rocm` と `amd.com/gpu` リソースを使う独立 Kustomize スタックです。

```bash
kubectl apply -k vllm/amd/
```

### ファインチューニング: AMD ROCm（LoRA）

推論（Deployment）とは **別 Job** として実行します。vLLM 本体は推論専用のため、学習は **ROCm PyTorch + HuggingFace TRL + PEFT** スタックを採用しています。

```bash
# 1. Secret（任意）
cp vllm/vllm-secret.example.yaml vllm/vllm-secret.yaml
# HF_TOKEN を編集
kubectl apply -f vllm/vllm-secret.yaml

# 2. ホストパス準備（hostPath PV 利用時）
minikube ssh -- 'sudo mkdir -p /data/vllm/finetune/{dataset,output,huggingface} && sudo chmod -R 777 /data/vllm/finetune'

# 3. 学習データを dataset PVC に配置（例: train.jsonl）
#    各レコードに "text" フィールド（DATASET_TEXT_FIELD で変更可）

# 4. ハイパーパラメータ編集（任意）
#    vllm/finetune/finetune-configmap.yaml

# 5. Job 投入（namespace は vllm/ と共有 — 未作成なら先に apply -k vllm/ または namespace.yaml）
kubectl apply -f vllm/namespace.yaml
kubectl apply -k vllm/finetune/
```

再実行時は Job 名を変更するか、既存 Job を削除してください。

```bash
kubectl -n vllm delete job vllm-finetune
kubectl apply -k vllm/finetune/
```

### 個別 apply（推論）

```bash
kubectl apply -f vllm/namespace.yaml
kubectl apply -f vllm/vllm-configmap.yaml
kubectl apply -f vllm/vllm-pv.yaml
kubectl apply -f vllm/vllm-deployment.yaml
kubectl apply -f vllm/vllm-service.yaml
```

---

## AMD ファインチューニング

### アーキテクチャ上の選択理由

| 候補 | 採否 | 理由 |
|------|------|------|
| vLLM 内蔵学習 | 不採用 | vLLM は推論サーバーが主目的 |
| Unsloth | 不採用 | NVIDIA 中心で ROCm サポートが限定的 |
| Axolotl | 次点 | 高機能だが YAML/依存が重く K8s Job では起動が遅い |
| **TRL + PEFT (LoRA)** | **採用** | ROCm PyTorch 公式イメージで動作、bf16 LoRA が MI 系で安定、マニフェストがシンプル |

### データセット形式

`/data/dataset`（PVC `vllm-finetune-dataset`）に以下いずれか:

- `train.jsonl` — 1 行 1 JSON、`{"text": "..."}` 形式
- `*.json` / `*.parquet` 単一ファイル
- HuggingFace datasets 形式のディレクトリ

例:

```json
{"text": "User: こんにちは\nAssistant: こんにちは！"}
```

### 監視

```bash
kubectl -n vllm get jobs,pods -l app=vllm-finetune
kubectl -n vllm logs -f job/vllm-finetune
```

### 学習結果を推論に使う

1. 出力 PVC（`vllm-finetune-output`）に LoRA アダプタが保存されます（`/data/output`）。
2. ベースモデル + アダプタをマージするか、vLLM の `--enable-lora` 等でアダプタパスを指定（vLLM / ROCm バージョンに依存）。
3. 推論用 `vllm-configmap.yaml` の `VLLM_MODEL` をローカルパス（共有 PVC）に変更。

```bash
# 出力確認（デバッグ Pod 例）
kubectl -n vllm run ft-debug --rm -it --restart=Never \
  --image=busybox --overrides='{"spec":{"containers":[{"name":"ft-debug","image":"busybox","command":["ls","-la","/out"],"volumeMounts":[{"name":"o","mountPath":"/out"}]}],"volumes":[{"name":"o","persistentVolumeClaim":{"claimName":"vllm-finetune-output"}}]}}'
```

### AMD 向けパフォーマンス設定（`finetune-configmap.yaml`）

| 設定 | デフォルト | 説明 |
|------|------------|------|
| `USE_BF16` | `true` | MI200/MI300 では bf16 を推奨 |
| `ATTN_IMPLEMENTATION` | `sdpa` | ROCm 向け PyTorch SDPA（flash-attn ビルド不要） |
| `GRADIENT_CHECKPOINTING` | `true` | VRAM 節約 |
| `PER_DEVICE_BATCH_SIZE` | `2` | GPU VRAM に応じて調整 |
| `GRADIENT_ACCUMULATION_STEPS` | `8` | 実効バッチ = 2×8 = 16 |
| `DATALOADER_NUM_WORKERS` | `4` | CPU コア数に合わせて調整 |
| `TORCH_COMPILE` | `false` | ROCm / モデルによっては不安定。有効化は要検証 |
| `USE_4BIT` | `false` | QLoRA。bitsandbytes ROCm は環境依存のためデフォルト off |
| `PYTORCH_HIP_ALLOC_CONF` | Job env | `expandable_segments:True` で断片化軽減 |

**クラスタ固有のチューニングが必要な項目:** ROCm ドライバ版、GPU 型番（MI210/MI300/Radeon）、Device Plugin の `mixed` 命名、イメージタグ（`rocm/pytorch` をホスト ROCm に合わせる）、`HSA_OVERRIDE_GFX_VERSION`（一部 Radeon）。

初回 Job 起動時は `pip install` により **数分** かかります。本番では依存を焼き込んだカスタムイメージ化を推奨します。

---

## 動作確認（推論）

### Pod 状態

```bash
kubectl -n vllm get pods -w
kubectl -n vllm describe pod -l app=vllm
kubectl -n vllm logs -f deploy/vllm
```

### サービス確認

```bash
kubectl -n vllm get svc
```

| 用途 | エンドポイント |
|------|----------------|
| クラスタ内 | `http://vllm.vllm.svc.cluster.local:8000` |
| NodePort | `http://<node-ip>:30800` |
| Port Forward | `kubectl -n vllm port-forward svc/vllm 8000:8000` → `http://localhost:8000` |

### OpenAI 互換 API の例

```bash
curl -s http://localhost:8000/v1/models | jq .

curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }' | jq .
```

---

## パフォーマンスベンチマーク（`perf`）

[vllm/benchmark/](benchmark/) で **Linux `perf`** と API 負荷テストを実行します。

```bash
# 1. ベースライン（チューニング前の ConfigMap のまま計測する場合は先にスナップショット）
kubectl apply -k vllm/benchmark/
kubectl -n vllm wait --for=condition=complete job/vllm-benchmark --timeout=15m
kubectl -n vllm logs job/vllm-benchmark | tee baseline.json

# 2. サーバ側 perf（vLLM と同一 GPU ノードに nodeSelector を設定）
kubectl apply -f vllm/benchmark/benchmark-perf-job.yaml
kubectl -n vllm logs job/vllm-benchmark-perf
```

詳細: [benchmark/README.md](benchmark/README.md)

---

## 設定変更（推論）

`vllm/vllm-configmap.yaml` / `vllm/amd/vllm-configmap.yaml`:

| キー | 説明 |
|------|------|
| `VLLM_MODEL` | Hugging Face モデル ID またはローカルパス |
| `VLLM_EXTRA_ARGS` | 追加 CLI 引数（パフォーマンスチューニング済みデフォルトあり） |
| `HF_HOME` | モデルキャッシュ（PVC と一致） |

### パフォーマンスチューニング（`VLLM_EXTRA_ARGS`）

ベンチマーク結果を見ながら調整してください。デフォルト値は `vllm/benchmark/` の手順で検証を想定しています。

| フラグ | NVIDIA デフォルト | AMD デフォルト | 説明 |
|--------|-------------------|----------------|------|
| `--gpu-memory-utilization` | 0.92 | 0.90 | KV キャッシュ用 VRAM 割合 |
| `--max-num-seqs` | 256 | 128 | 同時シーケンス上限 |
| `--max-model-len` | 4096 | 4096 | 最大コンテキスト長 |
| `--enable-prefix-caching` | on | on | プレフィックスキャッシュ |
| `--disable-log-requests` | on | on | リクエストログ無効化 |

AMD Deployment 追加 env: `PYTORCH_HIP_ALLOC_CONF`, `HIP_VISIBLE_DEVICES`, `VLLM_LOGGING_LEVEL=WARNING`

マルチ GPU 時は `--tensor-parallel-size <N>` を `VLLM_EXTRA_ARGS` に追加。

```bash
kubectl apply -k vllm/amd/   # AMD 推論
kubectl -n vllm rollout restart deployment/vllm
```

GPU ノードに taint がある場合は Deployment / Job 内の `tolerations` / `nodeSelector` のコメントを解除してください。

---

## トラブルシューティング

### Pod / Job が Pending

```bash
kubectl -n vllm describe pod -l app=vllm
kubectl -n vllm describe pod -l app=vllm-finetune
```

- `Insufficient nvidia.com/gpu` → NVIDIA overlay / Device Plugin を確認
- `Insufficient amd.com/gpu` → AMD Device Plugin / GPU Operator を確認
- PVC が Bound にならない → `hostPath` または `storageClassName` を環境に合わせて修正

### 学習 Job: GPU 未検出

- `torch.cuda.is_available()` が False → ノードの ROCm ドライバ、`amd.com/gpu` 割当、イメージの ROCm 版を確認
- MI 系以外の GPU では `HSA_OVERRIDE_GFX_VERSION` が必要な場合あり

### OOM

- `PER_DEVICE_BATCH_SIZE` を下げる、`MAX_SEQ_LENGTH` を短く、`GRADIENT_CHECKPOINTING=true` を維持
- 推論: より小さいモデル、`--gpu-memory-utilization` 調整

---

## ファイル構成

```
vllm/
├── namespace.yaml
├── vllm-configmap.yaml
├── vllm-pv.yaml
├── vllm-deployment.yaml          # NVIDIA 推論（デフォルト）
├── vllm-service.yaml
├── vllm-secret.example.yaml
├── kustomization.yaml            # NVIDIA 推論
├── scripts/
│   └── train_lora.py             # AMD 学習スクリプト
├── finetune/
│   ├── kustomization.yaml
│   ├── finetune-configmap.yaml   # 学習ハイパーパラメータ
│   ├── finetune-entrypoint-configmap.yaml
│   ├── finetune-pv.yaml          # dataset / output / hf-cache PVC
│   └── finetune-job.yaml         # amd.com/gpu Job
├── amd/                          # AMD ROCm 推論スタック
│   ├── kustomization.yaml
│   ├── vllm-deployment.yaml      # vllm-openai-rocm + amd.com/gpu
│   └── ...
├── benchmark/                    # perf + API ベンチマーク Job
│   ├── README.md
│   ├── benchmark-job.yaml
│   ├── benchmark-perf-job.yaml
│   └── scripts/
├── .gitignore
└── README.md
```

## 参考

- [vLLM Documentation](https://docs.vllm.ai/)
- [vLLM Docker (ROCm)](https://docs.vllm.ai/en/stable/deployment/docker/)
- [AMD GPU Device Plugin](https://instinct.docs.amd.com/projects/k8s-device-plugin/en/latest/)
- [ROCm PyTorch Docker](https://hub.docker.com/r/rocm/pytorch)
- [HuggingFace TRL](https://huggingface.co/docs/trl)
- [PEFT LoRA](https://huggingface.co/docs/peft)
