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
├── bootstrap.sh                 # 統一エントリポイント（init / join-worker / join-cp）
├── kubeadm-config.yaml          # ClusterConfiguration / InitConfiguration
├── join-config.yaml.example     # ワーカー / HA CP join テンプレート
├── docs/
│   ├── ha-control-plane.md      # 3 ノード stacked etcd
│   ├── load-balancer-external.md
│   └── network-policies.md      # NetworkPolicy addon（issue-07 参照）
├── scripts/
│   ├── common.sh
│   ├── 00-configure-lb.sh       # controlPlaneEndpoint 検証（init 前）
│   ├── 01-prerequisites.sh      # swap, sysctl, containerd
│   ├── 02-install-kubeadm.sh    # kubeadm/kubelet/kubectl (v1.29+)
│   ├── 03-init-control-plane.sh # 最初の control-plane
│   ├── 03b-join-control-plane.sh # HA 追加 control-plane
│   ├── 04-join-worker.sh
│   ├── 05-install-cni.sh        # Calico（既定）/ Cilium
│   ├── 05-install-rocm-worker.sh # AMD GPU worker: ROCm 導入
│   ├── 06-gpu-node-setup.md     # GPU ノード概要
│   ├── 07-register-gpu-worker.sh # GPU ラベル / device plugin 登録
│   ├── 08-export-kubeconfig.sh  # CP から kubeconfig エクスポート（issue-06）
│   └── 99-reset-cluster.sh      # ノード reset（CP / worker）
└── addons/
    ├── kustomization.yaml
    ├── apply-addons.sh
    ├── local-path-storage/      # デフォルト StorageClass
    ├── metrics-server/
    ├── nvidia-device-plugin/
    └── amd-gpu-device-plugin/   # 参照ドキュメント
```

### スクリプト一覧

| スクリプト | 実行ノード | 概要 |
|------------|------------|------|
| `00-configure-lb.sh` | 任意 | `CONTROL_PLANE_IP` / DNS の検証 |
| `01-prerequisites.sh` | 全ノード | swap 無効化、sysctl、containerd |
| `02-install-kubeadm.sh` | 全ノード | kubeadm / kubelet / kubectl |
| `03-init-control-plane.sh` | 最初の CP | `kubeadm init` |
| `03b-join-control-plane.sh` | 追加 CP | HA control-plane join |
| `04-join-worker.sh` | worker | `kubeadm join` |
| `05-install-cni.sh` | CP | Calico / Cilium |
| `05-install-rocm-worker.sh` | AMD GPU worker | ROCm / amdgpu 導入 |
| `07-register-gpu-worker.sh` | 管理端末 | GPU ラベル・addon 登録 |
| `08-export-kubeconfig.sh` | CP | kubeconfig エクスポート（issue-06） |
| `99-reset-cluster.sh` | 全ノード | `kubeadm reset` + 後片付け |

## Quick start（`bootstrap.sh`）

```bash
cd /path/to/kubernetes
chmod +x kubeadm/bootstrap.sh kubeadm/scripts/*.sh kubeadm/addons/apply-addons.sh

# init 前: LB / DNS エンドポイント確認（任意）
export CONTROL_PLANE_IP=192.168.1.10
export CONTROL_PLANE_DNS=cp.example.com
./kubeadm/scripts/00-configure-lb.sh --check-api

# 最初の control-plane（Calico + 基本 addons）
sudo kubeadm/bootstrap.sh --role init

# フルオプション例（Cilium + GPU + Ingress + MetalLB + Longhorn + NetworkPolicy）
sudo kubeadm/bootstrap.sh --role init \
  --with-cni cilium \
  --with-nvidia \
  --with-amd \
  --with-ingress \
  --with-metallb \
  --with-longhorn \
  --with-network-policies

# worker 参加
sudo kubeadm/bootstrap.sh --role join-worker \
  --join-command 'kubeadm join cp.example.com:6443 --token ... --discovery-token-ca-cert-hash sha256:...'

# HA: 追加 control-plane（upload-certs の certificate-key が必要）
sudo kubeadm/bootstrap.sh --role join-cp \
  --join-command 'kubeadm join cp.example.com:6443 --token ... --discovery-token-ca-cert-hash sha256:...' \
  --certificate-key '<certificate-key>'

# 前提スキップ / 実行内容の確認のみ
sudo kubeadm/bootstrap.sh --role init --skip-prerequisites
sudo kubeadm/bootstrap.sh --role init --dry-run
```

## 動作確認（bootstrap 後 / kind-dev）

Linux control-plane 上、または WSL の `kind-dev` コンテキストで統合テストを実行できます。

```bash
# 全 addon 検証（cluster / metrics / ingress / MetalLB / NetworkPolicy / PVC）
./kubeadm/scripts/run-integration-tests.sh

# Ingress のみ
./kubeadm/scripts/verify-ingress.sh
```

`run-integration-tests.sh` は 10 項目（cluster-info、metrics-server、ingress echo、MetalLB CRD、NetworkPolicy、bootstrap dry-run、local-path PVC）を検証します。

`bootstrap.sh` オプション一覧:

| オプション | 説明 |
|------------|------|
| `--role init \| join-worker \| join-cp` | ブートストラップ役割（必須） |
| `--with-cni calico \| cilium` | CNI（init のみ、既定: calico） |
| `--with-nvidia` | NVIDIA device plugin |
| `--with-amd` | AMD GPU device plugin |
| `--with-ingress` | ingress-nginx addon |
| `--with-metallb` | MetalLB addon |
| `--with-longhorn` | Longhorn addon |
| `--with-network-policies` | NetworkPolicy addon |
| `--join-command '<cmd>'` | join-worker / join-cp 用 |
| `--certificate-key '<key>'` | join-cp 用（`upload-certs` のキー） |
| `--skip-prerequisites` | `01-prerequisites.sh` をスキップ |
| `--dry-run` | フェーズを表示のみ |

詳細手順・個別スクリプト実行は以下を参照。

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

AMD GPU worker の推奨フロー:

```bash
# 1) worker ノードで ROCm を導入（join 前でも可）
sudo kubeadm/scripts/05-install-rocm-worker.sh
sudo kubeadm/scripts/05-install-rocm-worker.sh --check   # dry-run 相当

# 2) クラスタへ join（bootstrap または 04-join-worker）
sudo kubeadm/bootstrap.sh --role join-worker --join-command 'kubeadm join ...'

# 3) 管理端末から GPU 登録（ラベル + device plugin 確認、任意で vLLM 適用）
./kubeadm/scripts/07-register-gpu-worker.sh --node gpu-worker-01 --vendor amd
./kubeadm/scripts/07-register-gpu-worker.sh --node gpu-worker-01 --vendor amd --apply-vllm
```

NVIDIA の場合は init 時に `--with-nvidia`、join 後に `07-register-gpu-worker.sh --vendor nvidia` を使用。

詳細: [kubeadm/scripts/06-gpu-node-setup.md](scripts/06-gpu-node-setup.md)、[docs/GPU_WORKER_JOIN_AMD.md](../docs/GPU_WORKER_JOIN_AMD.md)

### 5. Ingress

本リポジトリの既存 nginx マニフェストを利用:

```bash
kubectl apply -k nginx/
```

または Argo CD `nginx-app` 経由でデプロイ。

### 6. Argo CD 連携

クラスタ準備後:

```bash
./scripts/bootstrap.sh
# または手動:
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl apply -f argocd/apps/root-application.yaml
```

vLLM: `vllm-kubeadm` → `vllm/overlays/kubeadm`（auto sync）。AMD / finetune / benchmark は manual。 [argocd/apps/DEPRECATED.md](../argocd/apps/DEPRECATED.md)

`root-application.yaml` の `repoURL` / `targetRevision` が本環境と一致していることを確認してください。

## 旧ローカルクラスタからの移行

| 項目 | 旧環境 | kubeadm |
|------|----------|---------|
| kubeconfig | `~/.kube/config`（旧 context） | control-plane の `admin.conf` または merge |
| ストレージ | hostPath PV (`standard`) | local-path 動的 PVC |
| vLLM manifest | `kubectl apply -k vllm/` | `kubectl apply -k vllm/overlays/kubeadm/` |
| Ingress | `kubectl apply -k nginx/` | `kubectl apply -k nginx/` |

### kubectl コンテキスト切替

```bash
# 旧 context を残したまま kubeadm を追加
scp user@cp:/etc/kubernetes/admin.conf ~/.kube/config-kubeadm
export KUBECONFIG=~/.kube/config-kubeadm
kubectl get nodes
```

### vLLM データ

- モデルキャッシュ: 旧ローカルクラスタ の `/data/vllm` → kubeadm ノードの local-path ボリュームへ手動コピー（[vllm/overlays/kubeadm/README.md](../vllm/overlays/kubeadm/README.md)）
- finetune データセット: 同様に PVC バインド後の実パスへ配置

### Argo CD

旧クラスタ上の Argo CD は新クラスタに再インストールが必要です。Application 定義（`argocd/apps/`）は Git からそのまま再利用できます。

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

## クラスタ / ノードのリセット

ノードを再構築する場合（control-plane / worker 共通）:

```bash
# 計画確認
sudo kubeadm/scripts/99-reset-cluster.sh --dry-run

# 確認プロンプト付き reset
sudo kubeadm/scripts/99-reset-cluster.sh

# 確認スキップ + etcd / CNI 残骸削除
sudo kubeadm/scripts/99-reset-cluster.sh --yes --purge-data
```

HA control-plane では、可能なら先に `kubectl drain` / `kubectl delete node` を実行してください。手順: [docs/ha-control-plane.md](docs/ha-control-plane.md)

## トラブルシューティング

- **Node NotReady**: CNI 未導入 → `05-install-cni.sh`
- **PVC Pending**: local-path addon 未適用 → `kubeadm/addons/apply-addons.sh`
- **GPU Pending**: Device Plugin / ラベル / taint → `06-gpu-node-setup.md`、`07-register-gpu-worker.sh`
- **metrics 未取得**: metrics-server addon と `--kubelet-insecure-tls`（自己署名 kubelet 証明書環境）
- **再 join 失敗**: 古い kubelet / CNI 状態 → `99-reset-cluster.sh --yes --purge-data`

## 関連ドキュメント

### kubeadm ランブック

- [docs/ha-control-plane.md](docs/ha-control-plane.md) — 3 ノード HA control-plane
- [docs/load-balancer-external.md](docs/load-balancer-external.md) — 外部 LB（keepalived / haproxy）
- [docs/network-policies.md](docs/network-policies.md) — NetworkPolicy addon（`--with-network-policies`）
- [docs/GPU_WORKER_JOIN_AMD.md](../docs/GPU_WORKER_JOIN_AMD.md) — AMD GPU worker 参加手順

### リポジトリ全体

- [kind/README.md](../kind/README.md) — ローカル dev / CI（推奨）
- [vllm/README.md](../vllm/README.md) — vLLM デプロイ
- [vllm/overlays/kubeadm/README.md](../vllm/overlays/kubeadm/README.md) — ストレージ overlay
- [argocd/README.md](../argocd/README.md) — App of Apps
- [argocd/apps/DEPRECATED.md](../argocd/apps/DEPRECATED.md) — vLLM Application 移行
