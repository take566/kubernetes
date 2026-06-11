# Kubernetes Platform

Kubernetes マニフェスト、クラスタ bootstrap、Argo CD GitOps をまとめたリポジトリです。

## 前提条件

| 用途 | 必要なツール |
|------|-------------|
| 共通 | [kubectl](https://kubernetes.io/docs/tasks/tools/) |
| ローカル開発 | [Docker](https://docs.docker.com/get-docker/) + [kind](https://kind.sigs.k8s.io/) |
| 本番 bootstrap | Linux ノード（Ubuntu/Debian）上で kubeadm スクリプトを実行 |
| GitOps / 検証 | [Helm](https://helm.sh/) v3（`validate.sh` の Helm チェック、Helm アプリ用） |

## 使い方

### 全体の流れ

```
クラスタ作成 (kind / kubeadm)
    ↓
Argo CD bootstrap（任意・推奨）
    ↓
Application sync または kubectl apply -k
    ↓
validate.sh / CI で検証
```

| シナリオ | 手順 | 詳細 |
|---------|------|------|
| ローカル開発 | kind →（任意）Argo CD → overlay 適用 | [kind/README.md](kind/README.md) |
| 本番クラスタ | kubeadm → Argo CD → App of Apps | [kubeadm/README.md](kubeadm/README.md) |
| GitOps 運用 | `bootstrap.sh` + `root-application` | [docs/ARGOCD_SETUP.md](docs/ARGOCD_SETUP.md) |
| マニフェスト検証 | `./scripts/validate.sh` | 下記「検証」 |
| CI runner | ARC controller → Secret → github-runners | [github-runners/README.md](github-runners/README.md) |

---

### 1. ローカル開発（kind）

```bash
chmod +x kind/scripts/*.sh kind/addons/apply-addons.sh

# クラスタ作成（名前: dev）
./kind/scripts/create-cluster.sh

kubectl config use-context kind-dev
kubectl get nodes
```

よく使う次のステップ:

```bash
# Ingress サンプル
kubectl apply -k nginx/

# vLLM（GPU なしスモーク — 制限は kind/README.md 参照）
kubectl apply -k vllm/overlays/kind/
```

削除: `./kind/scripts/delete-cluster.sh`

---

### 2. 本番クラスタ（kubeadm）

スクリプトは **Linux ノード上** で実行します（Windows では編集・レビューのみ）。

```bash
# control-plane で順に実行（詳細は kubeadm/README.md）
./kubeadm/scripts/01-prerequisites.sh
./kubeadm/scripts/02-install-kubeadm.sh
./kubeadm/scripts/03-init-control-plane.sh
./kubeadm/scripts/05-install-cni.sh

# worker で join
./kubeadm/scripts/04-join-worker.sh

# クラスタアドオン
./kubeadm/addons/apply-addons.sh
```

---

### 3. Argo CD（GitOps bootstrap）

既存クラスタ（kind / kubeadm / クラウド）に Argo CD を入れ、App of Apps を有効化します。

```bash
./scripts/bootstrap.sh
# bootstrap.sh 内で root-application も適用されます
```

UI アクセス:

```bash
kubectl port-forward svc/argocd-server -n argocd 8443:443
# https://localhost:8443 （初回パスワードは bootstrap 出力を参照）
```

Application の一覧・sync 方針（auto / manual）: [docs/ARGOCD_SETUP.md](docs/ARGOCD_SETUP.md)

**手動 sync が必要な例**（Secret や GPU 排他があるもの）:

```bash
argocd app sync gitlab
argocd app sync github-runners   # 事前に Secret 作成が必須
argocd app sync vllm-amd         # vllm-kubeadm と namespace 排他
```

---

### 4. アプリのデプロイ

**直接適用（kubectl）** — 検証や一時的な試行向け:

```bash
kubectl apply -k vllm/overlays/kubeadm/    # 本番 vLLM
kubectl apply -k vllm/overlays/kind/       # ローカル vLLM
kubectl apply -k elk-stack/
kubectl apply -k prometheus/
```

**GitOps（Argo CD）** — 運用の正:

- 定義: [argocd/apps/](argocd/apps/)
- `root-application` が App of Apps として子 Application を管理
- 廃止パス: [argocd/apps/DEPRECATED.md](argocd/apps/DEPRECATED.md)

vLLM のレイアウト: `vllm/base/` + `vllm/components/` + `vllm/overlays/{kubeadm,kind}/`  
（ルート `vllm/kustomization.yaml` や `vllm/amd/` は廃止済み）

モデル選定・拡張候補（LFM / Qwen3.6 / Gemma4）: [vllm/docs/MODEL_SELECTION.md](vllm/docs/MODEL_SELECTION.md) · [vllm/docs/MODEL_CANDIDATES_EXTENDED.md](vllm/docs/MODEL_CANDIDATES_EXTENDED.md)

---

### 5. 検証

ローカルでマニフェスト一式を検証:

```bash
chmod +x scripts/validate.sh
./scripts/validate.sh
```

- Kustomize build、kubectl dry-run、Argo CD Application の構文チェック
- Helm ラッパー（gitlab, jenkins, github-runners 等）は `helm` がある場合のみ検証

CI（GitHub Actions）でも同等の検証を実行: [.github/workflows/validate.yaml](.github/workflows/validate.yaml)

---

### 6. GitHub Actions セルフホスト runner（任意）

ARC v2 でクラスタ内 runner を運用する場合:

1. `actions-runner-controller` を sync
2. `github-runners` namespace に認証 Secret を手動作成
3. `github-runners` Application を sync
4. 動作確認: `.github/workflows/self-hosted-test.yaml`（`workflow_dispatch`）

手順の詳細: [github-runners/README.md](github-runners/README.md)

---

### 7. ローカル反復開発（Skaffold）

[skaffold.yaml](skaffold.yaml) にプロファイルがあります。

| プロファイル | 内容 |
|-------------|------|
| `elk` | ELK スタック |
| `monitoring` | Prometheus + Node Exporter |
| `nexus` | Nexus |
| `agents` | Hermes 等 |
| `full` | elk + prometheus + nexus + nginx（kustomize） |

```bash
skaffold dev -p full
```

---

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
| [monitoring/](monitoring/) | kube-prometheus-stack values | `monitoring` (manual — prometheus と同一 NS) |
| [nginx/](nginx/) | Nginx Ingress サンプル | `nginx` |
| [nexus/](nexus/) | Nexus Repository Manager | `nexus` |
| [gitlab/](gitlab/) | GitLab Helm values | `gitlab` (manual) |
| [jenkins/](jenkins/) | Jenkins Helm values | `jenkins` (manual) |
| [actions-runner-controller/](actions-runner-controller/) | GitHub ARC v2 controller | `actions-runner-controller` (manual) |
| [github-runners/](github-runners/) | GitHub Actions セルフホスト runner | `github-runners` (manual) |
| [cert-manager/](cert-manager/) | cert-manager Helm wrapper | `cert-manager` |
| [agents/](agents/) | Hermes 等エージェント | `agents` |

### GitOps・スクリプト

| ディレクトリ | 説明 |
|-------------|------|
| [argocd/](argocd/) | Argo CD インストール手順・Ingress |
| [argocd/apps/](argocd/apps/) | App of Apps（各 Application 定義） |
| [policies/](policies/) | ResourceQuota 等 |
| [scripts/](scripts/) | `bootstrap.sh`（Argo CD）、`validate.sh`（マニフェスト検証） |
| [docs/](docs/) | 補足ドキュメント索引 |
| [docs/backlog/](docs/backlog/) | kubeadm バックログ（issue-01〜08） |
| [ollama/modelfiles/](ollama/modelfiles/) | Ollama Modelfile（GPU 別チューニング） |

## 関連ドキュメント

| ドキュメント | 内容 |
|-------------|------|
| [docs/README.md](docs/README.md) | 補足ガイド一覧 |
| [docs/ARGOCD_SETUP.md](docs/ARGOCD_SETUP.md) | Application 一覧・sync 方針 |
| [argocd/README.md](argocd/README.md) | Argo CD Helm インストール |
| [vllm/README.md](vllm/README.md) | vLLM overlay 構成 |
| [docs/LOCAL_GPU_SETUP_WINDOWS.md](docs/LOCAL_GPU_SETUP_WINDOWS.md) | Windows ローカル GPU（ドライバー / ROCm / WSL） |
| [docs/REDESIGN.md](docs/REDESIGN.md) | 再設計分析（参考） |
