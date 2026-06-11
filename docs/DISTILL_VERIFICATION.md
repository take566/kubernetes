# vLLM Distillation × ELK 動作確認記録

最終更新: 2026-06-11

## 接続先

| クラスタ | 結果 | 根拠 |
|----------|------|------|
| **kubeadm-prod** | 未接続 | `~/.kube/config-kubeadm` なし。`kubeadm-connect.ps1 -Action status` で `kubeadm-prod` context 不存在 |
| **SSH 192.168.0.131** | 失敗 | `Permission denied (publickey)`（ansible inventory の候補） |
| **kind-dev** | 接続成功 | `kubectl cluster-info` OK、本検証は kind で実施 |

手動で kubeadm に繋ぐ手順: [kubeadm-connect.md](kubeadm-connect.md)

## kind-dev 検証ステップ

| ステップ | 結果 | 証拠 |
|----------|------|------|
| ELK stack | PASS | `elasticsearch` / `logstash` / `kibana` Running（namespace `elk-stack`） |
| ES データストリーム | PASS | `logs-vllm-distill` count 初期 **1**（mock） |
| distill-collector pip 修正 | PASS | イメージ `distill-collector:3.11-aiohttp`（`vllm/components/distill/Dockerfile`）を kind に load。pip ネットワークエラー解消 |
| Teacher（GPU vLLM） | FAIL → 代替 | `vllm/vllm-openai:latest` は CUDA ビルドのため CPU 推論不可（`Failed to infer device type`） |
| Teacher（kind stub） | PASS | `teacher-stub-patch` で OpenAI 互換 HTTP stub（`vllm-d4fd5fdc6-gg5wh` Ready 1/1） |
| Collector → Logstash → ES | PASS | ES count **2**。非 mock `request_id`: `c621823b-76df-4c61-87c2-e83f9d30ada7`、`cluster: kind` |
| Export Job | PASS | `vllm-distill-export-verify-135115` → `Exported 1 rows` → PVC `distill-export-20260611.jsonl` 1 行 |

### Teacher 構成（kind）

- **種別**: CPU OpenAI 互換 stub（実 vLLM 推論ではない）
- **モデル名（設定）**: `Qwen/Qwen2.5-0.5B-Instruct`
- **本番 GPU Teacher**: `vllm/overlays/kubeadm` + `nvidia.com/gpu`（要 kubeadm 接続）

## kind でのデプロイ手順（distill 含む）

```bash
# WSL / Docker
cd /mnt/d/work/kubernetes
docker build -t distill-collector:3.11-aiohttp -f vllm/components/distill/Dockerfile vllm/components/distill
./.bin/kind.exe load docker-image distill-collector:3.11-aiohttp --name dev

kubectl config use-context kind-dev
kubectl kustomize vllm/overlays/kind --load-restrictor LoadRestrictionsNone | kubectl apply -f -
kubectl kustomize vllm/overlays/kind/distill --load-restrictor LoadRestrictionsNone | kubectl apply -f -
```

## GPU のみ（kubeadm 接続後）

1. `scp` で `admin.conf` → `config-kubeadm`、merge（`scripts/kubeadm-connect.ps1`）
2. `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'`
3. `kubectl apply -k elk-stack/overlays/kubeadm/`
4. `kubectl apply -k vllm/overlays/kubeadm/` + `vllm/overlays/kubeadm/distill/`
5. Teacher Ready 後、collector ログと ES 増分、export JSONL を再確認

## ユーザーが手動で必要なこと

- kubeadm control-plane への SSH 鍵と `admin.conf` の取得
- GPU ノードでの NVIDIA Device Plugin
- kind 以外で distill-collector イメージをレジストリに push するか、各ノードへ `kind load` 相当の配布
