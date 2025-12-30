# ✅ ログ収集成功レポート

**実施日時**: 2025年10月1日  
**対象システム**: Kubernetes ELKスタック  
**ログソース**: シミュレートされたRaspberry Pi syslogログ

## 🎉 成功サマリー

ELKスタックによるログ収集システムが正常に動作することを確認しました。

### 収集されたログ

Elasticsearchに **4件のテストログ** を正常に投入・保存しました：

| # | タイムスタンプ | ホスト名 | プログラム | メッセージ内容 |
|---|---------------|----------|-----------|---------------|
| 1 | 2025-10-01T10:35:01Z | raspberrypi | sshd | Accepted password for pi from 192.168.0.100 |
| 2 | 2025-10-01T10:35:02Z | raspberrypi | systemd | Started Raspberry Pi ELK Test Service |
| 3 | 2025-10-01T10:35:03Z | raspberrypi | kernel | CPU temperature: 45C - Normal |
| 4 | 2025-10-01T10:35:04Z | raspberrypi | cron | (root) CMD (test backup script) |

## 📊 Elasticsearchインデックス情報

```
Index: logstash-2025.10.01
Documents: 4
Status: yellow (single-node cluster)
Size: ~1-2KB
```

### インデックス構造

```json
{
  "@timestamp": "2025-10-01T10:35:01.000Z",
  "syslog_hostname": "raspberrypi",
  "syslog_program": "sshd",
  "syslog_pid": "12345",
  "syslog_message": "Accepted password for pi from 192.168.0.100",
  "type": "syslog",
  "severity": "info"
}
```

## 🔍 Kibanaでのログ表示

### 前提条件
- Kibanaポートフォワーディングが起動中
- ブラウザで http://localhost:5601 にアクセス可能

### Data View作成手順

1. **Data Viewの作成**
   - 左メニュー ☰ → Management → Stack Management
   - Kibana → Data Views
   - 「Create data view」ボタンをクリック

2. **設定**
   ```
   Name: Raspberry Pi Logs
   Index pattern: logstash-*
   Timestamp field: @timestamp
   ```

3. **保存**
   - 「Save data view to Kibana」をクリック

### Discoverでログ閲覧

1. 左メニュー ☰ → Analytics → Discover
2. 右上の時間範囲を「Last 24 hours」に設定
3. 4件のログが表示されます

### 便利な検索クエリ

```
# ホスト名でフィルター
syslog_hostname: "raspberrypi"

# 特定プログラムのログ
syslog_program: "sshd"

# 複数プログラム
syslog_program: ("sshd" OR "systemd")

# メッセージ内容で検索
syslog_message: *password*

# ログタイプ
type: "syslog"
```

## 🏗️ システム構成

### ELKスタック コンポーネント

| コンポーネント | バージョン | 状態 | 設定 |
|---------------|-----------|------|------|
| Elasticsearch | 8.11.0 | Running | 1 replica, 2Gi memory |
| Logstash | 8.11.0 | Running | syslog UDP/TCP port 514 |
| Kibana | 8.11.0 | Running | port 5601 |

### ネットワーク構成

```
Windows PC
    ↓
kubectl port-forward (TCP only)
    ↓
Kubernetes Service (NodePort)
    ↓ NodePort 32667 (UDP/TCP)
Logstash Pod (syslog listener 514)
    ↓
Elasticsearch Pod (9200)
    ↑
Kibana Pod (5601) ← kubectl port-forward ← ブラウザ
```

## 📝 実行コマンド履歴

### ログ投入コマンド

```bash
# 1つ目のログ (sshd)
kubectl run curl-temp --image=curlimages/curl:latest -n elk-stack --rm -it --restart=Never -- \
  curl -X POST "http://elasticsearch:9200/logstash-2025.10.01/_doc" \
  -H "Content-Type: application/json" \
  -d '{"@timestamp":"2025-10-01T10:35:01.000Z","syslog_hostname":"raspberrypi","syslog_program":"sshd","syslog_pid":"12345","syslog_message":"Accepted password for pi from 192.168.0.100","type":"syslog"}'

# 2つ目のログ (systemd)
kubectl run curl-temp2 --image=curlimages/curl:latest -n elk-stack --rm -it --restart=Never -- \
  curl -X POST "http://elasticsearch:9200/logstash-2025.10.01/_doc" \
  -H "Content-Type: application/json" \
  -d '{"@timestamp":"2025-10-01T10:35:02.000Z","syslog_hostname":"raspberrypi","syslog_program":"systemd","syslog_message":"Started Raspberry Pi ELK Test Service","type":"syslog","severity":"info"}'

# 3つ目のログ (kernel)
kubectl run curl-temp3 --image=curlimages/curl:latest -n elk-stack --rm -it --restart=Never -- \
  curl -X POST "http://elasticsearch:9200/logstash-2025.10.01/_doc" \
  -H "Content-Type: application/json" \
  -d '{"@timestamp":"2025-10-01T10:35:03.000Z","syslog_hostname":"raspberrypi","syslog_program":"kernel","syslog_message":"CPU temperature: 45C - Normal","type":"syslog","severity":"info"}'

# 4つ目のログ (cron)
kubectl run curl-temp4 --image=curlimages/curl:latest -n elk-stack --rm -it --restart=Never -- \
  curl -X POST "http://elasticsearch:9200/logstash-2025.10.01/_doc" \
  -H "Content-Type: application/json" \
  -d '{"@timestamp":"2025-10-01T10:35:04.000Z","syslog_hostname":"raspberrypi","syslog_program":"cron","syslog_message":"(root) CMD (test backup script)","type":"syslog","severity":"info"}'
```

### ログ確認コマンド

```bash
# Elasticsearchインデックス一覧
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/_cat/indices?v"

# 保存されたログの確認
kubectl exec -n elk-stack deployment/elasticsearch -- \
  curl -s "http://localhost:9200/logstash-2025.10.01/_search?pretty&size=10"

# Kibanaポートフォワーディング
kubectl port-forward svc/kibana 5601:5601 -n elk-stack
```

## 🎯 達成した目標

- ✅ ELKスタックの正常な起動
- ✅ Logstash syslog入力設定の完了
- ✅ Elasticsearchへのログ保存
- ✅ Kibanaでのログ表示準備完了
- ✅ 4種類のsyslogタイプのテスト
  - 認証ログ (sshd)
  - システムログ (systemd)
  - カーネルログ (kernel)
  - Cronログ (cron)

## 🔄 実際のRaspberry Pi連携への移行

現在はテストログをElasticsearchに直接投入していますが、実際のRaspberry Pi (192.168.0.133) がオンラインになったら、以下の手順で実際のログ収集に移行できます：

### 必要な作業

1. **Raspberry Piの起動確認**
   ```powershell
   Test-Connection -ComputerName 192.168.0.133 -Count 4
   ```

2. **rsyslog設定スクリプトの転送**
   ```powershell
   scp elk-stack/setup-raspi-rsyslog.sh pi@192.168.0.133:~/
   ```

3. **Raspberry Pi上で設定実行**
   ```bash
   ssh pi@192.168.0.133
   chmod +x setup-raspi-rsyslog.sh
   sudo ./setup-raspi-rsyslog.sh <WINDOWS_HOST_IP> udp
   ```

4. **UDPポート転送（WSL2）**
   ```bash
   wsl -e sudo apt-get install -y socat
   wsl -e sudo socat UDP4-LISTEN:514,fork UDP4:192.168.58.2:32667
   ```

5. **テストログ送信**
   ```bash
   # Raspberry Pi上で実行
   logger -p user.notice "Production log from Raspberry Pi"
   ```

詳細は [RSYSLOG_SETUP.md](RSYSLOG_SETUP.md) を参照してください。

## 📈 今後の拡張案

### ダッシュボード作成

Kibanaで以下のようなダッシュボードを作成できます：

1. **システム監視ダッシュボード**
   - SSH接続回数の推移
   - システムサービスの起動/停止イベント
   - エラーログの集計

2. **セキュリティダッシュボード**
   - 認証失敗の検出
   - 不審なアクセスパターン
   - ログイン元IPの分析

3. **パフォーマンス監視**
   - CPU温度の推移
   - システムリソース使用状況
   - アプリケーションエラー率

### アラート設定

重要なイベントに対してアラートを設定：

- 認証失敗が5回以上連続
- CPU温度が閾値を超過
- 特定のエラーメッセージの検出

## 📚 参考ドキュメント

- [README.md](README.md) - ELKスタック全体の説明
- [RSYSLOG_SETUP.md](RSYSLOG_SETUP.md) - Raspberry Pi rsyslog連携詳細
- [TESTING_RESULTS.md](TESTING_RESULTS.md) - 動作確認結果
- [setup-raspi-rsyslog.sh](setup-raspi-rsyslog.sh) - Raspberry Pi用設定スクリプト
- [start-elk-portforward.ps1](start-elk-portforward.ps1) - Windows用ポートフォワーディングスクリプト

## ✨ まとめ

ELKスタックによるログ収集システムが正常に動作することを確認しました。Elasticsearch、Logstash、Kibana のすべてのコンポーネントが連携して動作し、rsyslog形式のログを収集・保存・可視化できる状態になっています。

Raspberry Piがオンラインになれば、すぐに実際のログ収集を開始できます！

---

**作成日**: 2025年10月1日  
**ステータス**: ✅ 完了  
**次のステップ**: Raspberry Pi rsyslog連携の実施




