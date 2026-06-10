# vLLM × kind ローカル開発 overlay

旧 `hostPath` + `storageClassName: standard` から、kind クラスタの **local-path** 動的プロビジョニングへ切り替えます。

> **GPU 非対応**  
> kind は Docker 内で動作するため **NVIDIA/AMD GPU を利用できません**。本 overlay はマニフェスト検証・Argo CD sync テスト・非 GPU スモーク用です。本番推論は [kubeadm overlay](../kubeadm/README.md) を使用してください。

## デプロイ

```bash
# 前提: kind/scripts/create-cluster.sh 実行済み（local-path addon 適用済み）
kubectl apply -k vllm/overlays/kind/           # NVIDIA 推論 manifest（GPU Pending になり得る）
kubectl apply -k vllm/overlays/kind/amd/       # AMD manifest（同上 — CI/kustomize 検証用）
kubectl apply -k vllm/overlays/kind/finetune/  # Finetune Job manifest
```

## 旧 hostPath からのデータ移行

1. 旧 hostPath 環境 上でモデルキャッシュをエクスポート（非推奨環境）  
   `旧 hostPath 環境 ssh -- 'sudo tar -C /data/vllm -czf - .' > vllm-cache.tgz`
2. kind 上で PVC バインド後、デバッグ Pod 等で `/data` に展開  
   または `kind/kind-config.yaml` の `extraMounts` でホスト `/data/vllm` をマウント

## Argo CD

手動 sync の Application: `argocd/apps/vllm-kind-app.yaml`  
（automated sync なし — GPU なし kind 向け）

## kubeadm overlay との関係

| overlay | 用途 |
|---------|------|
| `vllm/overlays/kind/` | ローカル dev / CI（GPU なし） |
| `vllm/overlays/kubeadm/` | 本番 kubeadm クラスタ（GPU あり） |

PVC 定義は同一（`storageClassName: local-path`）。ラベル `app.kubernetes.io/cluster` のみ `kind` / `kubeadm` で区別します。
