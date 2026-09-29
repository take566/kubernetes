# dm-system CronJobs

営業自動化 [dm-system](https://github.com/Deploy-inc/dm-system) の定期実行 (Deploy-inc/dm-system#167)。

| CronJob | スケジュール (JST) | 内容 |
|---|---|---|
| `dm-system-pipeline` | 平日 09:00 | collect → check-bounces → enrich → … → sync（送信なし） |
| `dm-system-send` | 平日 09:30 | フォーム → 追いメール → メールの実送信 → sync。**`suspend: true` で入る** |

- クラスタ:
  - `kind/kind-config-ops.yaml`（`kind-ops`）: `kubectl apply -k agents/dm-system`。hostPath PV が `D:\k8s-data` の extraMounts 前提
  - WSL 上の kubeadm（tmf-desktop）: `kubectl apply -k agents/dm-system/wsl-kubeadm`。hostPath は `/mnt/d/k8s-data/dm-system`、**2 本とも `suspend: true` で入る**（kind 側と同じ DB を使うため、切替は kind を止めてから。Deploy-inc/OpenClaw#2813）
  - 共通部分は `base/`
- イメージ `dm-system:local` は dm-system リポジトリの `scripts/k8s/build-image.sh` で kind へ読み込む
- Secret `dm-system-env` は dm-system の `scripts/k8s/apply-secrets.sh`（1Password → Secret）。`secret.example.yaml` は例示のみ
- Argo CD の App には登録していない（ローカル専用イメージ・hostPath のため `kubectl apply -k` で入れる）

手順の全量: dm-system の `docs/K8S_CRONJOB.md`
