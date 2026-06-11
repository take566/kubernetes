# vLLM × kubeadm 移行メモ

旧 `hostPath` + `storageClassName: standard` から、kubeadm クラスタの **local-path** 動的プロビジョニングへ切り替えます。

## デプロイ

```bash
# 前提: kubeadm/addons/ で local-path を適用済み
kubectl apply -k vllm/overlays/kubeadm/           # NVIDIA 推論
kubectl apply -k vllm/overlays/kubeadm/amd/       # AMD 推論
kubectl apply -k vllm/overlays/kubeadm/finetune/  # AMD 学習 Job
```

## 旧 hostPath からのデータ移行

1. 旧 hostPath 環境 上でモデルキャッシュをエクスポート  
   `旧 hostPath 環境 ssh -- 'sudo tar -C /data/vllm -czf - .' > vllm-cache.tgz`
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

## ストレージ選択（local-path vs Longhorn）

| 項目 | local-path（既定） | Longhorn |
|------|-------------------|----------|
| 導入 | `apply-addons.sh` 同梱 | `apply-addons.sh --with-longhorn` |
| ノード要件 | 単一ノード検証可 | **3+ worker 推奨**（レプリカ） |
| アクセス | RWO、ノード拘束 | RWO / RWX、レプリカ付き |
| default SC | はい | `--with-longhorn` で昇格 |
| vLLM overlay | そのまま | `longhorn-storage-patch.yaml` を有効化 |

### Longhorn 有効化手順

```bash
# 1. Longhorn 導入（default SC を longhorn に昇格）
sudo kubeadm/addons/apply-addons.sh --with-longhorn

# 2. vLLM overlay でストレージパッチを有効化
#    vllm/overlays/kubeadm/kustomization.yaml の longhorn-storage-patch.yaml のコメントを外す
kubectl apply -k vllm/overlays/kubeadm/

# AMD / finetune も Longhorn を使う場合は各 overlay の PVC を同様に longhorn へ変更
```

Longhorn はマニフェスト上 default SC にならないようパッチ済みです。`--with-longhorn` 実行時に `longhorn` を default に昇格し、`local-path` の default 注釈を外します。
