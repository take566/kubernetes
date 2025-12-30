# 📊 定期ログ収集システム - 運用ガイド

**作成日**: 2025年10月1日  
**ステータス**: ✅ 稼働中

## 🎯 システム概要

Kubernetes CronJobを使用して、**5分ごと**に自動的にログを生成してElasticsearchに投入するシステムです。

### システム構成

```
CronJob (log-generator)
    ↓ 5分ごと実行
ランダムログ生成
    ↓ HTTP POST
Elasticsearch
    ↓
Kibana (可視化)
```

## ⚙️ 設定内容

### CronJob詳細

| 項目 | 値 |
|------|------|
| 名前 | `log-generator` |
| スケジュール | `*/5 * * * *` (5分ごと) |
| 名前空間 | `elk-stack` |
| イメージ | `curlimages/curl:latest` |

### 生成されるログの種類

1. **sshd** (SSH接続ログ)
   - 成功: `Accepted password for pi from 192.168.0.X`
   - 失敗: `Failed password for invalid user from 192.168.0.X`

2. **systemd** (システムサービスログ)
   - 起動: `Started Raspberry Pi Service`
   - 停止: `Stopped Raspberry Pi Service`

3. **kernel** (カーネルログ)
   - 正常: `CPU temperature: 40-59C - Normal`
   - 警告: `CPU temperature: 60-74C - High`

4. **cron** (Cronジョブログ)
   - `(root) CMD (backup script executed successfully)`

5. **nginx** (Webサーバーログ)
   - `GET /api/status HTTP/1.1 200`

### ログフォーマット

```json
{
  "@timestamp": "2025-10-01T04:23:30Z",
  "syslog_hostname": "raspberrypi",
  "syslog_program": "sshd",
  "syslog_message": "Accepted password for pi from 192.168.0.6 port 22006",
  "type": "syslog",
  "severity": "info",
  "source": "cronjob-generator"
}
```

## 📋 運用コマンド

### CronJobの状態確認

```bash
# CronJob情報を表示
kubectl get cronjob -n elk-stack

# CronJobの詳細情報
kubectl describe cronjob log-generator -n elk-stack
```

### ジョブ実行履歴の確認

```bash
# 実行されたジョブの一覧
kubectl get jobs -n elk-stack

# 最近のジョブのログを確認
kubectl logs job/log-generator-<job-id> -n elk-stack
```

### 手動でログを生成

```bash
# 即座にログを生成（スケジュールを待たない）
kubectl create job --from=cronjob/log-generator log-generator-manual -n elk-stack

# ジョブの完了を確認
kubectl get jobs -n elk-stack

# ジョブのログを確認
kubectl logs job/log-generator-manual -n elk-stack
```

### ログ収集の一時停止

```bash
# CronJobを一時停止
kubectl patch cronjob log-generator -n elk-stack -p '{"spec":{"suspend":true}}'

# CronJobを再開
kubectl patch cronjob log-generator -n elk-stack -p '{"spec":{"suspend":false}}'
```

### スケジュールの変更

```bash
# 例: 10分ごとに変更
kubectl patch cronjob log-generator -n elk-stack --type='json' -p='[{"op": "replace", "path": "/spec/schedule", "value":"*/10 * * * *"}]'

# 例: 1時間ごとに変更
kubectl patch cronjob log-generator -n elk-stack --type='json' -p='[{"op": "replace", "path": "/spec/schedule", "value":"0 * * * *"}]'

# 例: 1分ごとに変更（テスト用）
kubectl patch cronjob log-generator -n elk-stack --type='json' -p='[{"op": "replace", "path": "/spec/schedule", "value":"*/1 * * * *"}]'
```

## 📊 Elasticsearchでのログ確認

### ログ件数の確認

```bash
# 今日のログ件数
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/logstash-$(date -u +%Y.%m.%d)/_count"

# すべてのlogstashインデックスの件数
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/logstash-*/_count"
```

### 最新のログを表示

```bash
# 最新5件のログを表示
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/logstash-*/_search?size=5&sort=@timestamp:desc&pretty"
```

### CronJobで生成されたログのみ表示

```bash
# source = cronjob-generator のログを検索
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/logstash-*/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{"query":{"term":{"source":"cronjob-generator"}},"size":10}'
```

## 🌐 Kibanaでの確認

### Discoverでログを表示

1. **Kibanaにアクセス**
   ```
   http://localhost:5601/app/discover
   ```

2. **時間範囲を設定**
   - 右上の時間範囲をクリック
   - 「Last 24 hours」または「Last 7 days」を選択

3. **CronJob生成ログのみ表示**
   - 検索バーに入力:
     ```
     source: "cronjob-generator"
     ```

### ダッシュボード作成例

**ログ統計ダッシュボード**:
1. ログプログラム別の件数（円グラフ）
2. 時系列グラフ（折れ線グラフ）
3. 重要度別の分布（棒グラフ）
4. CPU温度の推移（折れ線グラフ）

## 🔧 トラブルシューティング

### CronJobが実行されない

```bash
# CronJobの状態確認
kubectl get cronjob log-generator -n elk-stack -o yaml

# SUSPENDがtrueになっていないか確認
kubectl get cronjob log-generator -n elk-stack -o jsonpath='{.spec.suspend}'

# イベントを確認
kubectl get events -n elk-stack --sort-by='.lastTimestamp'
```

### ジョブが失敗する

```bash
# 失敗したジョブのログを確認
kubectl get jobs -n elk-stack | grep log-generator
kubectl logs job/<job-name> -n elk-stack

# Podの状態確認
kubectl get pods -n elk-stack | grep log-generator
kubectl describe pod <pod-name> -n elk-stack
```

### ログが投入されない

```bash
# Elasticsearchの状態確認
kubectl get pods -n elk-stack | grep elasticsearch

# Elasticsearchのヘルスチェック
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/_cluster/health?pretty"

# ネットワーク疎通確認
kubectl exec -n elk-stack deployment/logstash -- \
  curl -s "http://elasticsearch:9200/_cluster/health"
```

## 📈 スケーリングと最適化

### ログ生成頻度の調整

現在の設定: **5分ごと**

**推奨設定**:
- **開発/テスト**: 1-5分ごと
- **デモ環境**: 5-10分ごと
- **負荷軽減**: 15-30分ごと

### 古いジョブの自動削除

現在の設定:
```yaml
successfulJobsHistoryLimit: 3  # 成功したジョブを3つ保持
failedJobsHistoryLimit: 3      # 失敗したジョブを3つ保持
```

変更方法:
```bash
kubectl edit cronjob log-generator -n elk-stack
```

## 🔄 実際のRaspberry Piへの切り替え

Raspberry Pi (192.168.0.133) がオンラインになったら、以下の手順で実際のrsyslogに切り替えます：

### 1. CronJobを停止

```bash
kubectl patch cronjob log-generator -n elk-stack -p '{"spec":{"suspend":true}}'
```

### 2. Raspberry Piでrsyslog設定

```bash
# 設定スクリプトを転送
scp setup-raspi-rsyslog.sh pi@192.168.0.133:~/

# Raspberry Pi上で実行
ssh pi@192.168.0.133
chmod +x setup-raspi-rsyslog.sh
sudo ./setup-raspi-rsyslog.sh <WINDOWS_HOST_IP> udp
```

詳細は [RSYSLOG_SETUP.md](RSYSLOG_SETUP.md) を参照。

### 3. 両方のログソースを区別

Kibanaで検索:
```
# CronJobで生成されたログ
source: "cronjob-generator"

# Raspberry Piから送信されたログ
NOT source: "cronjob-generator" AND syslog_hostname: "raspberrypi"
```

## 📚 関連ドキュメント

- [README.md](README.md) - ELKスタック全体の説明
- [RSYSLOG_SETUP.md](RSYSLOG_SETUP.md) - Raspberry Pi rsyslog連携詳細
- [LOG_COLLECTION_SUCCESS.md](LOG_COLLECTION_SUCCESS.md) - ログ収集成功レポート
- [TESTING_RESULTS.md](TESTING_RESULTS.md) - 動作確認結果

## 📞 サポート

### よくある質問

**Q: ログが表示されない**  
A: Kibanaで時間範囲を「Last 24 hours」以上に設定してください。

**Q: CronJobが5分ごとに実行されない**  
A: `kubectl get cronjob -n elk-stack` で SUSPEND が False であることを確認してください。

**Q: ログの種類を増やしたい**  
A: `log-generator-cronjob.yaml` を編集して `kubectl apply -f` で再適用してください。

---

**最終更新**: 2025年10月1日  
**ステータス**: ✅ 稼働中  
**次回ログ生成**: 自動（5分ごと）



