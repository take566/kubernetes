# Kubernetes Platform

Kubernetes マニフェスト、クラスタ bootstrap、Argo CD GitOps をまとめたリポジトリです。

## ディレクトリ構成

### クラスタ Bootstrap

| ディレクトリ | 用途 | ドキュメント |
|-------------|------|-------------|
| [kind/](kind/) | ローカル開発（Docker + kind） | [kind/README.md](kind/README.md) |
| [kubeadm/](kubeadm/) | 本番向け kubeadm クラスタ | [kubeadm/README.md](kubeadm/README.md) |

### アプリケーション / ワークロード

| ディレクトリ | 説明 | Argo CD Application |
|-------------|------|---------------------|
| [vllm/](vllm/) | vLLM 推論・AMD LoRA 学習・ベンチマーク | `vllm-kubeadm`, `vllm-kind`, `vllm-amd`, `vllm-finetune`, `vllm-benchmark` |
| [elk-stack/](elk-stack/) | Elasticsearch / Logstash / Kibana | `elk-stack` (manual) |
| [prometheus/](prometheus/) | Prometheus + Node Exporter | `prometheus` (auto) |
| [monitoring/](monitoring/) | kube-prometheus-stack values | `monitoring` (manual — same NS as prometheus) |
| [nginx/](nginx/) | Nginx Ingress サンプル | `nginx` |
| [nexus/](nexus/) | Nexus Repository Manager | `nexus` |
| [gitlab/](gitlab/) | GitLab Helm values | `gitlab` (manual) |
| [jenkins/](jenkins/) | Jenkins Helm values | `jenkins` (manual) |
| [actions-runner-controller/](actions-runner-controller/) | GitHub ARC v2 controller | `actions-runner-controller` (manual) |
| [github-runners/](github-runners/) | GitHub Actions セルフホスト runner | `github-runners` (manual) |
| [cert-manager/](cert-manager/) | cert-manager Helm wrapper | `cert-manager` |
| [agents/](agents/) | Hermes 等エージェント | `agents` |

### GitOps

| ディレクトリ | 説明 |
|-------------|------|
| [argocd/](argocd/) | Argo CD インストール手順・Ingress |
| [argocd/apps/](argocd/apps/) | App of Apps（各 Application 定義） |

廃止済みパス: [argocd/apps/DEPRECATED.md](argocd/apps/DEPRECATED.md)

### ポリシー・スクリプト

| ディレクトリ | 説明 |
|-------------|------|
| [policies/](policies/) | ResourceQuota 等 |
| [scripts/](scripts/) | `bootstrap.sh`（Argo CD）、`validate.sh`（マニフェスト検証） |
| [docs/](docs/) | 補足ドキュメント索引 |

## クイックスタート

### 1. クラスタ作成

```bash
# ローカル dev
./kind/scripts/create-cluster.sh

# 本番 kubeadm（Linux ノード上で実行）
# 手順: kubeadm/README.md
```

### 2. Argo CD bootstrap（既存クラスタ）

```bash
./scripts/bootstrap.sh
kubectl apply -f argocd/apps/root-application.yaml
```

### 3. マニフェスト検証

```bash
./scripts/validate.sh
```

### 4. vLLM デプロイ（例）

```bash
# kubeadm 本番
kubectl apply -k vllm/overlays/kubeadm/

# kind ローカル
kubectl apply -k vllm/overlays/kind/
```

詳細: [vllm/README.md](vllm/README.md)

## ローカル開発（Skaffold）

[skaffold.yaml](skaffold.yaml) に nginx / elk / prometheus / nexus / agents のプロファイルがあります。

```bash
skaffold dev -p full
```

## 関連ドキュメント

- [docs/README.md](docs/README.md) — 補足ガイド一覧
- [argocd/README.md](argocd/README.md) — Argo CD インストール
- [docs/REDESIGN.md](docs/REDESIGN.md) — 再設計分析（参考）
