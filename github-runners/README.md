# GitHub Actions セルフホスト Runner（ARC v2）

Kubernetes 上で [Actions Runner Controller v2](https://github.com/actions/actions-runner-controller)（Runner Scale Sets）を使い、GitHub Actions のセルフホスト runner を運用する設定です。

## 構成

| パス | 内容 |
|------|------|
| [../actions-runner-controller/](../actions-runner-controller/) | ARC コントローラ（`gha-runner-scale-set-controller`） |
| `Chart.yaml` / `values.yaml` | Runner scale set（`gha-runner-scale-set` → `AutoscalingRunnerSet`） |
| `github-runners-secret.example.yaml` | 認証 Secret の例（**本番トークンはコミットしない**） |

## 前提条件

- Kubernetes クラスタ（kind / kubeadm — 本リポジトリの bootstrap 手順）
- **kind / 開発環境**: runner の作業ボリューム（`kubernetesModeWorkVolumeClaim`）には **local-path** StorageClass が必要です。kind では `kind/addons/apply-addons.sh` で local-path を適用済みであること。`values.yaml` の `storageClassName` は既定で `local-path`（本番で別 SC を使う場合は上書き）。
- Helm v3
- GitHub PAT または GitHub App（runner 登録用）
- Argo CD（GitOps 経由の場合のみ — [docs/ARGOCD_SETUP.md](../docs/ARGOCD_SETUP.md)）

## クイック bootstrap（Helm / kubectl）

Argo CD なしで ARC コントローラ + runner scale set を入れる場合:

```bash
# 事前チェック（クラスタ変更なし）
./scripts/bootstrap-self-hosted-runner.sh --check

# インストール（GITHUB_TOKEN または ~/.github-runner-token があれば Secret + runner も適用）
# 注意: `gh auth token` の gho_* は不可。classic PAT (ghp_*) を使用すること。
export GITHUB_TOKEN=ghp_YOUR_TOKEN
./scripts/bootstrap-self-hosted-runner.sh

# 動作確認
gh workflow run self-hosted-test.yaml

# vLLM ベンチマーク（compare_set: default | extended | all）
./scripts/trigger-vllm-benchmark.sh default
```

| スクリプト | 内容 |
|------------|------|
| [../scripts/bootstrap-self-hosted-runner.sh](../scripts/bootstrap-self-hosted-runner.sh) | ARC controller + runner scale set（idempotent） |
| [../scripts/trigger-vllm-benchmark.sh](../scripts/trigger-vllm-benchmark.sh) | `vllm-model-benchmark.yaml` を `workflow_dispatch` |

## Windows + Ollama runner（RX 5700 / GPU ローカルベンチ）

K8s 内 vLLM が GPU を使えない場合、**ホスト Windows** に runner を直接登録し、Ollama で GPU ベンチを回します。

1. [actions/runner](https://github.com/actions/runner/releases) を Windows にインストール
2. リポジトリ Settings → Actions → Runners → New self-hosted runner
3. 登録時にラベルを追加: `ollama`（既存: `self-hosted`, `Windows`, `X64`）
4. Ollama を常駐、`.\scripts\setup-ollama-rx5700.ps1` でモデル準備

```powershell
gh workflow run vllm-ollama-benchmark.yaml -f compare_set=default -f run_benchmark=true
```

| スクリプト | 用途 |
|------------|------|
| [../scripts/setup-ollama-rx5700.ps1](../scripts/setup-ollama-rx5700.ps1) | モデル pull + :rx5700 Modelfile |
| [../scripts/compare_models_ollama.ps1](../scripts/compare_models_ollama.ps1) | HF 候補一括比較 |
| [../scripts/bench_ollama_openai.ps1](../scripts/bench_ollama_openai.ps1) | `bench_vllm.py` 互換 JSON |

## デプロイ手順（Argo CD）

### 1. コントローラ（初回のみ）

```bash
kubectl apply -f argocd/apps/actions-runner-controller-app.yaml -n argocd
argocd app sync actions-runner-controller
```

Namespace: `actions-runner-system`

### 2. GitHub 認証 Secret（手動・必須）

PAT または GitHub App で Secret を作成してから runner を sync します。

```bash
kubectl create namespace github-runners

# 例: PAT
kubectl create secret generic github-runners-secret \
  --namespace github-runners \
  --from-literal=github_token='ghp_YOUR_TOKEN'

# または example を編集して apply（プレースホルダーのみコミット済み）
# kubectl apply -f github-runners-secret.example.yaml -n github-runners
```

**GitHub App を使う場合**（推奨・ org 向け）:

1. GitHub → Settings → Developer settings → GitHub Apps → New
2. Permissions: Actions (Read), Administration (Read), Organization self-hosted runners (Write) 等
3. Install App を org/repo に実行
4. Secret に `github_app_id`, `github_app_installation_id`, `github_app_private_key` を設定

### 3. Runner scale set

`values.yaml` の `githubConfigUrl` を org / repo / enterprise URL に合わせて編集。

```bash
kubectl apply -f argocd/apps/github-runners-app.yaml -n argocd
argocd app sync github-runners
```

Namespace: `github-runners`

### 4. ワークフローでの利用

`runnerScaleSetName`（既定: `k8s-self-hosted`）を `runs-on` に指定します。

```yaml
jobs:
  build:
    runs-on: k8s-self-hosted
    # または scaleSetLabels 利用時: runs-on: [self-hosted, linux, k8s]
```

サンプル: [.github/workflows/self-hosted-test.yaml](../.github/workflows/self-hosted-test.yaml)

## カスタマイズ

| 項目 | values.yaml キー |
|------|------------------|
| スケール上限 | `minRunners` / `maxRunners` |
| ラベル | `scaleSetLabels` |
| Docker ビルド | `containerMode.type: dind`（privileged が必要） |
| リソース | `template.spec.containers[].resources` |

## トラブルシューティング

```bash
# コントローラ
kubectl get pods -n actions-runner-system
kubectl logs -n actions-runner-system -l app.kubernetes.io/name=gha-runner-scale-set-controller

# Runner / Listener
kubectl get autoscalingrunnersets -n github-runners
kubectl get pods -n github-runners
kubectl logs -n github-runners -l actions.github.com/scale-set-name=k8s-self-hosted

# Secret 未作成時
# → AutoscalingRunnerSet が GitHub API 認証エラー。Secret を先に作成して再 sync。
```

| 症状 | 対処 |
|------|------|
| Runner が GitHub に表示されない | Secret / `githubConfigUrl` / PAT 権限を確認 |
| Job がキューに残る | `runs-on` が `runnerScaleSetName` と一致しているか確認 |
| Pod が Pending（PVC Unbound） | `storageClassName` がクラスタの SC と一致しているか確認（kind/dev は `local-path`） |
| DinD でビルド失敗 | `containerMode.type: dind` + privileged / storageClass を確認 |

## 削除

```bash
argocd app delete github-runners
argocd app delete actions-runner-controller
kubectl delete namespace github-runners
kubectl delete namespace actions-runner-system
```

## 参考

- [Deploy runner scale sets (GitHub Docs)](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets)
- [actions-runner-controller](https://github.com/actions/actions-runner-controller)
- Jenkins / GitLab との役割分担: Jenkins/GitLab = 従来 CI、本構成 = GitHub Actions 専用 runner
