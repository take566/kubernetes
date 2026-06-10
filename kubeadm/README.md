# kubeadm クラスタ Bootstrap

本ディレクトリは **Linux ノード上で kubeadm による本番向け Kubernetes クラスタ** を構築するためのスクリプトとアドオンです。

> **注意（Windows 開発環境）**  
> スクリプトは **Ubuntu/Debian の Linux ターゲットノード** 向けです。Windows 上では編集・レビューのみ行い、実行は control-plane / worker の Linux VM または物理サーバーで行ってください。

## ハードウェア / ネットワーク前提

| 項目 | 推奨 |
|------|------|
| control-plane | 2 CPU / 4Gi RAM 以上（本番は 3 ノード HA 推奨） |
| worker | ワークロードに応じて（vLLM GPU ノードは VRAM 要件を参照） |
| OS | Ubuntu 22.04/24.04 または Debian 12 |
| ディスク | etcd + コンテナイメージ用 40Gi 以上 |
| ネットワーク | 全ノード間 L3 到達、NAT なし推奨 |
| ポート | 6443 (API), 10250 (kubelet), 2379-2380 (etcd), Calico 179 等 |
| DNS/LB | `controlPlaneEndpoint` 用 VIP または DNS（例: `cp.example.com:6443`） |

デフォルト CIDR（`kubeadm-config.yaml` と一致）:

- Pod: `192.168.0.0/16`
- Service: `10.96.0.0/12`

## ディレクトリ構成

```
kubeadm/
├── README.md
├── kubeadm-config.yaml          # ClusterConfiguration / InitConfiguration
├── join-config.yaml.example     # ワーカー join テンプレート
├── scripts/
│   ├── common.sh
│   ├── 01-prerequisites.sh      # swap, sysctl, containerd
│   ├── 02-install-kubeadm.sh    # kubeadm/kubelet/kubectl (v1.29+)
│   ├── 03-init-control-plane.sh
│   ├── 04-join-worker.sh
│   ├── 05-install-cni.sh        # Calico（既定）/ Cilium
│   └── 06-gpu-node-setup.md
└── addons/
    ├── kustomization.yaml
    ├── apply-addons.sh
    ├── local-path-storage/      # デフォルト StorageClass
    ├── metrics-server/
    ├── nvidia-device-plugin/
    └── amd-gpu-device-plugin/   # 参照ドキュメント
```

## Bootstrap 手順

### 0. 設定編集

1. `kubeadm-config.yaml` の `controlPlaneEndpoint` と `advertiseAddress` を環境に合わせて編集  
2. または init 時に環境変数で上書き（`03-init-control-plane.sh`）

### 1. 全ノード（control-plane + worker）

```bash
cd /path/to/kubernetes
sudo chmod +x kubeadm/scripts/*.sh kubeadm/addons/apply-addons.sh
sudo kubeadm/scripts/01-prerequisites.sh
sudo kubeadm/scripts/02-install-kubeadm.sh
# バージョン変更: export K8S_VERSION=v1.30.4
```

### 2. 最初の control-plane ノード

```bash
export CONTROL_PLANE_IP=192.168.1.10
export CONTROL_PLANE_DNS=cp.example.com   # LB/DNS があれば指定

sudo kubeadm/scripts/03-init-control-plane.sh
sudo kubeadm/scripts/05-install-cni.sh    # 既定: Calico
sudo kubeadm/addons/apply-addons.sh         # local-path + metrics-server
# NVIDIA GPU クラスタ:
sudo kubeadm/addons/apply-addons.sh --with-nvidia
```

### 3. worker ノード

control-plane で join コマンドを取得:

```bash
kubeadm token create --print-join-command
```

worker で:

```bash
sudo kubeadm/scripts/01-prerequisites.sh
sudo kubeadm/scripts/02-install-kubeadm.sh
sudo kubeadm/scripts/04-join-worker.sh --join 'kubeadm join cp.example.com:6443 --token ... --discovery-token-ca-cert-hash sha256:...'
```

### 4. GPU ノード（vLLM 用）

[kubeadm/scripts/06-gpu-node-setup.md](scripts/06-gpu-node-setup.md) を参照。

### 5. Ingress

本リポジトリの既存 nginx マニフェストを利用:

```bash
kubectl apply -k nginx/
```

または Argo CD `nginx-app` 経由でデプロイ。

### 6. Argo CD 連携

クラスタ準備後（既存 [scripts/bootstrap.sh](../scripts/bootstrap.sh) の minikube 部分の代わり）:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl apply -f argocd/apps/root-application.yaml
```

`root-application.yaml` の `repoURL` / `targetRevision` が本環境と一致していることを確認してください。

## minikube からの移行

| 項目 | minikube | kubeadm |
|------|----------|---------|
| kubeconfig | `~/.kube/config` (minikube context) | control-plane の `admin.conf` または merge |
| ストレージ | hostPath PV (`standard`) | local-path 動的 PVC |
| vLLM manifest | `kubectl apply -k vllm/` | `kubectl apply -k vllm/overlays/kubeadm/` |
| Ingress | `minikube addons enable ingress` | `kubectl apply -k nginx/` |

### kubectl コンテキスト切替

```bash
# minikube コンテキストを残したまま kubeadm を追加
scp user@cp:/etc/kubernetes/admin.conf ~/.kube/config-kubeadm
export KUBECONFIG=~/.kube/config-kubeadm
kubectl get nodes
```

### vLLM データ

- モデルキャッシュ: minikube の `/data/vllm` → kubeadm ノードの local-path ボリュームへ手動コピー（[vllm/overlays/kubeadm/README.md](../vllm/overlays/kubeadm/README.md)）
- finetune データセット: 同様に PVC バインド後の実パスへ配置

### Argo CD

minikube 上の Argo CD は新クラスタに再インストールが必要です。Application 定義（`argocd/apps/`）は Git からそのまま再利用できます。

## CNI 選択

| CNI | 設定 |
|-----|------|
| **Calico**（既定） | `05-install-cni.sh` |
| Cilium | `CNI=cilium sudo kubeadm/scripts/05-install-cni.sh`（要 helm） |

## ストレージ

- **local-path-provisioner**（開発 / 単一ノード RWO）: `kubeadm/addons/local-path-storage/`
- **Longhorn**（本番 HA ストレージ）: 別途 [Longhorn 公式](https://longhorn.io/docs/) を導入し、vLLM overlay の `storageClassName` を変更

## 検証

```bash
# リポジトリルートで
kubectl kustomize kubeadm/addons/
kubectl kustomize vllm/overlays/kubeadm/
./scripts/validate.sh   # kubeadm パス含む（更新後）
```

## トラブルシューティング

- **Node NotReady**: CNI 未導入 → `05-install-cni.sh`
- **PVC Pending**: local-path addon 未適用 → `kubeadm/addons/apply-addons.sh`
- **GPU Pending**: Device Plugin / ラベル / taint → `06-gpu-node-setup.md`
- **metrics 未取得**: metrics-server addon と `--kubelet-insecure-tls`（自己署名 kubelet 証明書環境）

## 関連ドキュメント

- [minikube.md](../minikube.md) — 従来の開発手順
- [vllm/README.md](../vllm/README.md) — vLLM デプロイ
- [vllm/overlays/kubeadm/README.md](../vllm/overlays/kubeadm/README.md) — ストレージ overlay
- [argocd/README.md](../argocd/README.md) — App of Apps
