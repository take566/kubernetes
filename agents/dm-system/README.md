# dm-system CronJobs

営業自動化 [dm-system](https://github.com/Deploy-inc/dm-system) の定期実行 (Deploy-inc/dm-system#167)。

| CronJob | スケジュール (JST) | 内容 |
|---|---|---|
| `dm-system-pipeline` | 平日 09:00 | collect → check-bounces → enrich → … → sync（送信なし） |
| `dm-system-send` | 平日 09:30 | フォーム → 追いメール → メールの実送信 → sync。**`suspend: true` で入る** |

- クラスタ: tmf-desktop の WSL 上の kubeadm。`kubectl apply -k agents/dm-system/wsl-kubeadm`。hostPath は `/mnt/d/k8s-data/dm-system`、**2 本とも `suspend: true` で入る**（初回は手動実行で確かめてから resume する）。共通部分は `base/`
  - 以前の kind クラスタ `ops`（Docker Desktop 上）は 2026-10-01 に WSL へ移し（Deploy-inc/OpenClaw#2813）、2026-10-02 に撤去した（Deploy-inc/OpenClaw#2814）。`kind/kind-config-ops.yaml` と kind 用の `agents/dm-system/kustomization.yaml` も削除した
- イメージ `dm-system:local` は dm-system リポジトリの `scripts/k8s/build-image.sh` で WSL の containerd へ直接ビルドする（Docker 不要）
- Secret `dm-system-env` は dm-system の `scripts/k8s/apply-secrets.sh`（1Password → Secret）。`secret.example.yaml` は例示のみ
- Argo CD の App には登録していない（ローカル専用イメージ・hostPath のため `kubectl apply -k` で入れる）

手順の全量: dm-system の `docs/K8S_CRONJOB.md`
