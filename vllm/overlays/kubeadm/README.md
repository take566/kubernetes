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

`argocd/apps/vllm-app.yaml` の `path` を `vllm/overlays/kubeadm` に変更するか、環境用 Application を追加してください。

## Longhorn 利用時

本番でノードを跨ぐ RWO が必要な場合は [Longhorn](https://longhorn.io/) を導入し、各 PVC の `storageClassName` を `longhorn` に変更してください。
