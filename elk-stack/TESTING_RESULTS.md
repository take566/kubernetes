# ELK Stack rsyslog連携 動作確認結果

**実施日時**: 2025年10月1日  
**対象**: Raspberry Pi (192.168.0.133) との rsyslog連携

## ✅ 完了した作業

### 1. ELKスタックのデプロイと不具合修正

すべてのコンポーネントが正常に起動しています：

```
NAME                             READY   STATUS    RESTARTS   AGE
elasticsearch-747969c79b-fl22j   1/1     Running   0          29m
kibana-558cfd7fd9-ppc45          1/1     Running   0          3m26s
logstash-5cc574bbff-8tdxr        1/1     Running   0          61s
```

### 2. 修正した不具合

#### Elasticsearch設定エラー
- **問題**: Elasticsearch 8.11.0で廃止された設定項目を使用
  - `xpack.monitoring.enabled`
  - `xpack.reporting.enabled`
- **解決**: `elasticsearch-configmap.yaml`から削除

#### Elasticsearchデータディレクトリ権限エラー
- **問題**: `/usr/share/elasticsearch/data`へのアクセス権限不足
- **解決**: `elasticsearch-deployment.yaml`にinitContainerを追加して権限修正
  ```yaml
  initContainers:
  - name: fix-permissions
    image: busybox:1.36
    command: ['sh', '-c', 'chown -R 1000:1000 /usr/share/elasticsearch/data']
    volumeMounts:
    - name: elasticsearch-data
      mountPath: /usr/share/elasticsearch/data
    securityContext:
      runAsUser: 0
  ```

#### Kibana設定エラー
- **問題**: Kibana 8.11.0で廃止された設定項目を使用
- **解決**: `kibana-configmap.yaml`を最小限の設定に変更

### 3. Logstash syslog設定

`logstash-configmap.yaml`にsyslog入力を追加：

```ruby
input {
  # rsyslog input (UDP)
  syslog {
    port => 514
    type => "syslog"
  }
}

filter {
  if [type] == "syslog" {
    grok {
      match => { "message" => "%{SYSLOGTIMESTAMP:syslog_timestamp} %{SYSLOGHOST:syslog_hostname} %{DATA:syslog_program}(?:\[%{POSINT:syslog_pid}\])?: %{GREEDYDATA:syslog_message}" }
    }
    date {
      match => [ "syslog_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
    }
  }
}
```

Logstashログで確認済み：
```
[2025-10-01T01:01:53,241][INFO ][logstash.inputs.syslog] Starting syslog udp listener {:address=>"0.0.0.0:514"}
[2025-10-01T01:01:53,244][INFO ][logstash.inputs.syslog] Starting syslog tcp listener {:address=>"0.0.0.0:514"}
```

### 4. 作成したドキュメントとスクリプト

1. **RSYSLOG_SETUP.md** (261行)
   - 詳細な設定ガイド
   - 3つの異なるアプローチ方法
   - トラブルシューティングセクション

2. **setup-raspi-rsyslog.sh** (Raspberry Pi用自動設定スクリプト)
   - rsyslog設定の自動作成
   - 設定検証
   - サービス再起動
   - カラー出力で分かりやすい

3. **start-elk-portforward.ps1** (Windows用自動化スクリプト)
   - ポートフォワーディング自動開始
   - ELKスタック状態確認
   - ファイアウォール設定確認
   - アクセス情報表示

## ⚠️ 判明した制限事項と課題

### kubectl port-forwardの制限

**重要**: kubectl port-forwardは**TCPのみ**をサポートしており、**UDPをサポートしていません**。

これは以下を意味します：
- rsyslogのデフォルトプロトコル（UDP）はkubectl port-forwardで転送できない
- Raspberry Piからのrsyslogログを受信するには別の方法が必要

### 代替ソリューション

#### 方法1: socatを使用（推奨）

WSL2内でsocatを使用してUDPポート転送：

```bash
# WSL2内でsocatをインストール
wsl -e sudo apt-get update
wsl -e sudo apt-get install -y socat

# MinikubeのIPとNodePortを確認
kubectl get nodes -o wide  # Minikube IP: 192.168.58.2
kubectl get svc logstash -n elk-stack  # NodePort: 32667

# UDPポート転送
wsl -e sudo socat UDP4-LISTEN:514,fork UDP4:192.168.58.2:32667 &
```

#### 方法2: minikube tunnelを使用

LoadBalancerタイプのServiceを使用：

```bash
# logstash-service.yamlを変更
type: LoadBalancer

# minikube tunnelを起動（管理者権限が必要）
minikube tunnel
```

#### 方法3: NodePortに直接アクセス

Raspberry Piから直接MinikubeのNodeIPにアクセス：

**前提条件**: WSL2のネットワークモードを変更（Windows 11のみ）

`.wslconfig`ファイルを編集（`C:\Users\<ユーザー名>\.wslconfig`）：
```ini
[wsl2]
networkingMode=mirrored
```

その後、Raspberry Piの設定：
```conf
*.* @192.168.58.2:32667
```

## 🔄 Raspberry Piがオンラインになった際の確認手順

### 前提条件
- Raspberry Pi IPアドレス: 192.168.0.133
- Windows ホストIPアドレス: 192.168.0.132（確認要）

### 手順

#### 1. Raspberry Pi接続確認
```powershell
Test-Connection -ComputerName 192.168.0.133 -Count 4
```

#### 2. 設定スクリプト転送
```powershell
scp D:\work\kubernetes\elk-stack\setup-raspi-rsyslog.sh pi@192.168.0.133:~/
```

#### 3. Raspberry Pi上で設定
```bash
ssh pi@192.168.0.133
chmod +x setup-raspi-rsyslog.sh
sudo ./setup-raspi-rsyslog.sh <WINDOWS_HOST_IP> udp
```

#### 4. Windowsファイアウォール設定
```powershell
# 管理者権限で実行
New-NetFirewallRule -DisplayName "Logstash syslog UDP" -Direction Inbound -Protocol UDP -LocalPort 514 -Action Allow
New-NetFirewallRule -DisplayName "Logstash syslog TCP" -Direction Inbound -Protocol TCP -LocalPort 514 -Action Allow
```

#### 5. UDPポート転送開始
```bash
# socatを使用
wsl -e sudo socat UDP4-LISTEN:514,fork UDP4:192.168.58.2:32667
```

#### 6. テストログ送信
```bash
# Raspberry Pi上で実行
logger -p user.notice "ELK Stack test from Raspberry Pi"
logger -p kern.info "Kernel test message"
logger -p auth.warn "Auth warning test"
```

#### 7. ログ受信確認

**Logstashログ確認**:
```powershell
kubectl logs -f deployment/logstash -n elk-stack
```

**Elasticsearch確認**:
```powershell
kubectl exec -n elk-stack deployment/elasticsearch -- curl -s http://localhost:9200/_cat/indices?v
kubectl exec -n elk-stack deployment/elasticsearch -- curl -s http://localhost:9200/logstash-*/_search?pretty | Select-String -Pattern "syslog_hostname"
```

**Kibana確認**:
```powershell
kubectl port-forward svc/kibana 5601:5601 -n elk-stack
```
ブラウザで http://localhost:5601 にアクセス

## 📊 期待される結果

### Logstashログ
```json
{
  "syslog_timestamp" => "Oct  1 10:05:01",
  "syslog_hostname" => "raspberrypi",
  "syslog_program" => "test-app",
  "syslog_pid" => "1234",
  "syslog_message" => "Test message from Raspberry Pi",
  "type" => "syslog",
  "@timestamp" => 2025-10-01T01:05:01.000Z
}
```

### Elasticsearch
```
health status index                uuid   pri rep docs.count docs.deleted store.size pri.store.size
yellow open   logstash-2025.10.01  abc123  1   1          3            0      5.2kb          5.2kb
```

### Kibana
- インデックスパターン `logstash-*` が作成可能
- Discoverでログが表示される
- フィルター `syslog_hostname: "raspberrypi"` で絞り込み可能

## 🔧 トラブルシューティング

### ログが届かない場合

1. **ポート転送の確認**
   ```powershell
   Get-NetUDPEndpoint | Where-Object LocalPort -eq 514
   ```

2. **Raspberry Piからの接続テスト**
   ```bash
   nc -zvu <WINDOWS_HOST_IP> 514
   echo "test" | nc -u <WINDOWS_HOST_IP> 514
   ```

3. **Logstashの状態確認**
   ```powershell
   kubectl get pods -n elk-stack
   kubectl logs deployment/logstash -n elk-stack --tail=100
   ```

4. **Kubernetesサービス確認**
   ```powershell
   kubectl get svc logstash -n elk-stack
   kubectl describe svc logstash -n elk-stack
   ```

## 📝 次のステップ

1. **Raspberry Piがオンラインになったら実際のログ送信テスト**
2. **Kibanaでダッシュボード作成**
   - システムログ監視ダッシュボード
   - エラーログ集計
   - ホスト別ログ分析
3. **本番環境への展開検討**
   - TLS暗号化の有効化
   - 認証の設定
   - ログローテーション設定

## 📚 参考資料

- [RSYSLOG_SETUP.md](RSYSLOG_SETUP.md) - 詳細設定ガイド
- [Logstash Syslog Input Plugin](https://www.elastic.co/guide/en/logstash/current/plugins-inputs-syslog.html)
- [rsyslog Documentation](https://www.rsyslog.com/doc/)
- [Kubernetes Port Forwarding](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/)
- [WSL2 Networking](https://learn.microsoft.com/en-us/windows/wsl/networking)




