# kind ローカル開発クラスタ

本ディレクトリは **Docker 上の [kind](https://kind.sigs.k8s.io/) クラスタ** をローカル開発・CI 向けに構築するための設定です。

> **旧環境 非推奨**  
> ローカル開発の標準は kind に移行しました。旧環境 は廃止済みです。本番相当の構築は [kubeadm/README.md](../kubeadm/README.md) を参照してください。

## 前提条件

| ツール | 用途 |
|--------|------|
| [Docker](https://docs.docker.com/get-docker/) | kind ノードの実行 |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | クラスタ作成 |
| kubectl | マニフェスト適用 |

推奨リソース: **CPU 4+ / RAM 8Gi+**（worker 2 台構成時は 12Gi+ 推奨）

```bash
# kind インストール例 (Linux)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
```

## ディレクトリ構成

```
kind/
├── README.md
├── kind-config.yaml           # クラスタ定義（Ingress 80/443 ポートマップ）
├── scripts/
│   ├── create-cluster.sh      # 作成 + アドオン適用
│   ├── delete-cluster.sh      # 削除
│   └── load-images.sh         # イメージ事前ロード（任意）
└── addons/
    ├── kustomization.yaml     # kubeadm/addons を再利用
    └── apply-addons.sh
```

## クイックスタート

```bash
cd /path/to/kubernetes
chmod +x kind/scripts/*.sh kind/addons/apply-addons.sh

# クラスタ作成（名前: dev）
./kind/scripts/create-cluster.sh

# コンテキスト確認
kubectl config use-context kind-dev
kubectl get nodes

# Ingress（nginx DaemonSet + hostPort 80/443）
kubectl apply -k nginx/

# vLLM スモークテスト（GPU なし — 下記制限参照）
kubectl apply -k vllm/overlays/kind/
```

## クラスタ削除

```bash
./kind/scripts/delete-cluster.sh
# またはクラスタ名指定
./kind/scripts/delete-cluster.sh dev
```

## イメージ事前ロード（任意）

レジストリ pull を避ける場合:

```bash
docker pull vllm/vllm-openai:latest
./kind/scripts/load-images.sh
```

## 制限事項

| 項目 | kind | kubeadm / 本番 |
|------|------|----------------|
| GPU (NVIDIA/AMD) | **不可** — Docker 内で GPU パススルーなし | Device Plugin + ラベル |
| vLLM 推論 | マニフェスト検証・スモークのみ（Pod は GPU 不足で Pending になり得る） | 本番推論 |
| ストレージ | local-path（kubeadm addon 共用） | local-path / Longhorn |
| Ingress | hostPort 80/443 → control-plane | LB / MetalLB 等 |

AMD / NVIDIA overlay（`vllm/overlays/kind/amd/`）も同様に **GPU 非対応** のため、CI で `kubectl kustomize` 検証用途に限定してください。

## Argo CD

kind 上で Argo CD を使う場合:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl apply -f argocd/apps/root-application.yaml
```

vLLM（kind 向け overlay）は **手動 sync** の Application です:

```bash
kubectl apply -f argocd/apps/vllm-kind-app.yaml
# Argo CD UI または CLI で Sync（automated sync なし — GPU なし環境向け）
```

旧 `vllm-app.yaml`（root hostPath）は kind では使わないでください。`vllm-kind-app` が `vllm/overlays/kind` を指します。

## 以前の hostPath 環境からの移行

| 項目 | 旧 hostPath 環境 | kind |
|------|-------------------|------|
| 起動 | `./kind/scripts/create-cluster.sh` | `./kind/scripts/create-cluster.sh` |
| Ingress | `kubectl apply -k nginx/` | `kubectl apply -k nginx/` |
| ストレージ | hostPath PV (`standard`) | local-path 動的 PVC |
| vLLM | `kubectl apply -k vllm/` | `kubectl apply -k vllm/overlays/kind/` |
| モデルキャッシュ | ノード上の `/data/vllm` またはエクスポート | PVC バインド後に Pod 経由で配置、または `extraMounts` |

## 検証

```bash
kubectl kustomize kind/addons/
kubectl kustomize vllm/overlays/kind/
./scripts/validate.sh
```

## 関連ドキュメント

- [kubeadm/README.md](../kubeadm/README.md) — 本番向け kubeadm
- [vllm/overlays/kind/README.md](../vllm/overlays/kind/README.md) — vLLM overlay
- [旧環境.md](../旧環境.md) — **非推奨**（レガシー）
