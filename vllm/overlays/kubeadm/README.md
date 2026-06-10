# vLLM × kubeadm 移行メモ

minikube の `hostPath` + `storageClassName: standard` から、kubeadm クラスタの **local-path** 動的プロビジョニングへ切り替えます。

## デプロイ

```bash
# 前提: kubeadm/addons/ で local-path を適用済み
kubectl apply -k vllm/overlays/kubeadm/           # NVIDIA 推論
kubectl apply -k vllm/overlays/kubeadm/amd/       # AMD 推論
kubectl apply -k vllm/overlays/kubeadm/finetune/  # AMD 学習 Job
```

## minikube からのデータ移行

1. minikube 上でモデルキャッシュをエクスポート  
   `minikube ssh -- 'sudo tar -C /data/vllm -czf - .' > vllm-cache.tgz`
2. kubeadm GPU/ストレージノードで local-path の実パスを確認（Pod 起動後）  
   `kubectl -n vllm get pvc vllm-model-cache -o jsonpath='{.spec.volumeName}'`
3. 該当ノード上の `/opt/local-path-provisioner/...` に展開（環境によりパスは異なる）

## Argo CD

| Application | Path | Sync |
|-------------|------|------|
| `vllm-kubeadm` | `vllm/overlays/kubeadm` | automated |
| `vllm-amd` | `vllm/overlays/kubeadm/amd` | manual |
| `vllm-finetune` | `vllm/overlays/kubeadm/finetune` | manual |
| `vllm-benchmark` | `vllm/benchmark` | manual |

`vllm-app`（root `vllm/`）は削除済み。詳細: [argocd/apps/DEPRECATED.md](../../argocd/apps/DEPRECATED.md)

## Longhorn 利用時

本番でノードを跨ぐ RWO が必要な場合は [Longhorn](https://longhorn.io/) を導入し、各 PVC の `storageClassName` を `longhorn` に変更してください。
