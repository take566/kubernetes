# dm-system CronJobs

営業自動化 [dm-system](https://github.com/Deploy-inc/dm-system) の定期実行 (Deploy-inc/dm-system#167)。

| CronJob | スケジュール (JST) | 内容 |
|---|---|---|
| `dm-system-pipeline` | 平日 09:00 | collect → check-bounces → enrich → … → sync（送信なし） |
| `dm-system-send` | 平日 09:30 | フォーム → 追いメール → メールの実送信 → sync。**`suspend: true` で入る** |

- クラスタ: `kind/kind-config-ops.yaml`（`kind-ops`）。hostPath PV が `D:\k8s-data` の extraMounts 前提なので他クラスタでは使わない
- イメージ `dm-system:local` は dm-system リポジトリの `scripts/k8s/build-image.sh` で kind へ読み込む
- Secret `dm-system-env` は dm-system の `scripts/k8s/apply-secrets.sh`（1Password → Secret）。`secret.example.yaml` は例示のみ
- Argo CD の App には登録していない（ローカル専用イメージ・hostPath のため `kubectl apply -k` で入れる）

手順の全量: dm-system の `docs/K8S_CRONJOB.md`
