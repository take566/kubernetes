# vLLM OpenAI-Compatible API Server

Kubernetes 上で [vLLM](https://docs.vllm.ai/) の OpenAI 互換 API サーバーと、AMD ROCm 向け LoRA ファインチューニング Job を動かすためのマニフェストです。

## クラスタ環境（推奨）

| 環境 | デプロイ path | Argo CD Application |
|------|---------------|---------------------|
| **kubeadm**（本番） | `vllm/overlays/kubeadm` | `vllm-kubeadm`（auto sync） |
| **kind**（ローカル） | `vllm/overlays/kind` | `vllm-kind`（manual sync） |

ルート `vllm/base/` は Kustomize **base**（PV なし）です。本番・Argo CD では必ず **overlay** を使ってください。`kubectl apply -k vllm/` や `vllm/amd/` / `vllm/finetune/` は **削除済み** です。

> **警告: kind + AMD RX 5700 環境では `overlays/kind/amd` を適用しないこと。** WSL では `amd.com/gpu` が割当不可のため Pod が**永久 Pending** になります（実際に 16 時間 Pending が発生）。推論 API は `overlays/kind/windows-ollama-external` + register スクリプトを使用してください — 詳細: [components/windows-ollama-external/README.md](components/windows-ollama-external/README.md) / [docs/RX5700_WSL_GPU.md](../docs/RX5700_WSL_GPU.md)。
> 適用してしまった場合: `kubectl -n vllm scale deploy/vllm --replicas=0`

```bash
# kubeadm（local-path PVC）
kubectl apply -k vllm/overlays/kubeadm/           # NVIDIA 推論
kubectl apply -k vllm/overlays/kubeadm/amd/       # AMD 推論
kubectl apply -k vllm/overlays/kubeadm/finetune/  # AMD 学習 Job
```

詳細: [overlays/kubeadm/README.md](overlays/kubeadm/README.md) · [kubeadm/README.md](../kubeadm/README.md)

---

| 項目 | 説明 |
|------|------|
| **GPU ノード（推論・NVIDIA）** | NVIDIA GPU（`nvidia.com/gpu`） |
| **GPU ノード（推論・AMD / 学習）** | ROCm 対応 AMD GPU（`amd.com/gpu`） |
| **Device Plugin** | NVIDIA: [k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) / AMD: [ROCm k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin) または [AMD GPU Operator](https://instinct.docs.amd.com/projects/gpu-operator/) |
| **ストレージ** | モデルキャッシュ・学習データ・チェックポイント用 PV |
| **モデル** | 推論・学習とも Qwen2.5 系（kubeadm: 1.5B / kind: 0.5B）— [docs/MODEL_SELECTION.md](docs/MODEL_SELECTION.md) |
| **Hugging Face トークン** | ゲート付きモデル利用時は `vllm-secret.example.yaml` をコピーして Secret を作成 |

### GPU リソース名（AMD）

AMD GPU Device Plugin は通常 **`amd.com/gpu`** を allocatable リソースとして公開します（`single` 命名戦略）。GPU パーティション利用時は `amd.com/cpx_nps4` など混在命名になる場合があります（[AMD Device Plugin 設定](https://instinct.docs.amd.com/projects/k8s-device-plugin/en/latest/user-guide/configuration.html)）。

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,AMD_GPU:.status.capacity.'amd\.com/gpu'
```

Node Labeller 導入時は `amd.com/gpu.present`、`amd.com/gpu.vram` などのラベルで `nodeSelector` できます。

---

## デプロイ

> **本番 / kubeadm:** 上記 overlay を使用。`kubectl apply -k vllm/base/` 単体では PVC がなくデプロイ不可です（overlay 必須）。

### 推論: NVIDIA（kubeadm overlay — 推奨）

```bash
kubectl apply -k vllm/overlays/kubeadm/
```

### 推論: AMD ROCm（kubeadm overlay — 推奨）

公式 ROCm イメージ `vllm/vllm-openai-rocm` と `amd.com/gpu` リソースを使う Kustomize コンポーネント + overlay です。

```bash
kubectl apply -k vllm/overlays/kubeadm/amd/
```

### ファインチューニング: AMD ROCm（LoRA）

推論（Deployment）とは **別 Job** として実行します。vLLM 本体は推論専用のため、学習は **ROCm PyTorch + HuggingFace TRL + PEFT** スタックを採用しています。

```bash
# 1. Secret（任意）
cp vllm/base/vllm-secret.example.yaml vllm/vllm-secret.yaml
# HF_TOKEN を編集
kubectl apply -f vllm/vllm-secret.yaml

# 2. kubeadm overlay（local-path PVC — 推奨）
kubectl apply -k vllm/overlays/kubeadm/finetune/
```

再実行時は Job 名を変更するか、既存 Job を削除してください。

```bash
kubectl -n vllm delete job vllm-finetune
kubectl apply -k vllm/overlays/kubeadm/finetune/
```

### 個別 apply（推論）

```bash
kubectl apply -f vllm/base/namespace.yaml
kubectl apply -f vllm/base/vllm-configmap.yaml
kubectl apply -f vllm/overlays/kubeadm/vllm-pvc.yaml
kubectl apply -f vllm/base/vllm-deployment.yaml
kubectl apply -f vllm/base/vllm-service.yaml
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
Assistant: こんにちは！"}
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
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }' | jq .
```

---

## モデル選定

overlay ごとに `VLLM_MODEL` をパッチしています（`vllm/overlays/*/model-patch.yaml`）。

| 環境 | モデル | 用途 |
|------|--------|------|
| kubeadm / kubeadm/amd | `Qwen/Qwen2.5-1.5B-Instruct` | 本番推論（日本語・ゲートなし） |
| kind / kind/amd | `Qwen/Qwen2.5-0.5B-Instruct` | ローカル/CI スモーク |

候補比較と選定根拠: [docs/MODEL_SELECTION.md](docs/MODEL_SELECTION.md)

```bash
# 複数候補を順にデプロイしてベンチマーク比較（GPU クラスタ上）
chmod +x vllm/benchmark/scripts/compare_models.sh
./vllm/benchmark/scripts/compare_models.sh
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

`vllm/base/vllm-configmap.yaml` / `vllm/components/amd/vllm-configmap.yaml`:

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
| `--max-model-len` | 8192（kubeadm overlay） | 8192（kubeadm/amd） | 最大コンテキスト長 |
| `--max-num-batched-tokens` | 8192 | 4096 | バッチあたりトークン上限 |
| `--enable-prefix-caching` | on | on | プレフィックスキャッシュ |
| `--enable-chunked-prefill` | on | on | 長コンテキスト TTFT 改善 |
| `--disable-log-requests` | on | on | リクエストログ無効化 |

AMD Deployment 追加 env: `PYTORCH_HIP_ALLOC_CONF`, `HIP_VISIBLE_DEVICES`, `VLLM_LOGGING_LEVEL=WARNING`

マルチ GPU 時は `--tensor-parallel-size <N>` を `VLLM_EXTRA_ARGS` に追加。

```bash
kubectl apply -k vllm/overlays/kubeadm/amd/   # AMD 推論
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
├── base/                         # NVIDIA 推論 base（PV なし — overlay 必須）
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── vllm-configmap.yaml
│   ├── vllm-deployment.yaml
│   ├── vllm-service.yaml
│   └── vllm-secret.example.yaml
├── components/
│   ├── amd/                      # AMD ROCm 推論（overlay で PVC 合成）
│   │   ├── kustomization.yaml
│   │   ├── vllm-configmap.yaml
│   │   └── vllm-deployment.yaml
│   └── finetune/                 # AMD LoRA 学習 Job
│       ├── kustomization.yaml
│       ├── finetune-configmap.yaml
│       ├── finetune-entrypoint-configmap.yaml
│       ├── finetune-job.yaml
│       └── scripts/train_lora.py
├── overlays/
│   ├── kubeadm/                  # 本番: local-path PVC
│   │   ├── amd/
│   │   └── finetune/
│   └── kind/                     # ローカル dev / CI
│       ├── amd/
│       └── finetune/
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
