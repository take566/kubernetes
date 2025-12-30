# ELK Stack on Kubernetes

このディレクトリには、Kubernetes上でELKスタック（Elasticsearch、Logstash、Kibana）を実行するためのマニフェストファイルが含まれています。

## 構成

- **Elasticsearch**: データの保存と検索エンジン
- **Logstash**: ログの収集、処理、変換
- **Kibana**: データの可視化とダッシュボード

## 前提条件

- Kubernetesクラスターが動作していること
- `kubectl`がインストールされていること
- NGINX Ingress Controllerがインストールされていること（KibanaのIngress用）

## デプロイ方法

### 1. 自動デプロイ（推奨）

```bash
chmod +x deploy.sh
./deploy.sh
```

### 2. 手動デプロイ

```bash
# 名前空間を作成
kubectl apply -f namespace.yaml

# Elasticsearchをデプロイ
kubectl apply -f elasticsearch-configmap.yaml
kubectl apply -f elasticsearch-pv.yaml
kubectl apply -f elasticsearch-deployment.yaml
kubectl apply -f elasticsearch-service.yaml

# Logstashをデプロイ
kubectl apply -f logstash-configmap.yaml
kubectl apply -f logstash-deployment.yaml
kubectl apply -f logstash-service.yaml

# Kibanaをデプロイ
kubectl apply -f kibana-configmap.yaml
kubectl apply -f kibana-deployment.yaml
kubectl apply -f kibana-service.yaml
kubectl apply -f kibana-ingress.yaml
```

## アクセス方法

### Kibana
- URL: http://kibana.local
- ポートフォワード: `kubectl port-forward svc/kibana 5601:5601 -n elk-stack`

### Elasticsearch
- ポートフォワード: `kubectl port-forward svc/elasticsearch 9200:9200 -n elk-stack`
- ヘルスチェック: `curl http://localhost:9200/_cluster/health`

### Logstash
- TCP: 5000
- UDP: 5000
- Beats: 5044

## ログの確認

```bash
# Elasticsearchのログ
kubectl logs -f deployment/elasticsearch -n elk-stack

# Logstashのログ
kubectl logs -f deployment/logstash -n elk-stack

# Kibanaのログ
kubectl logs -f deployment/kibana -n elk-stack
```

## ステータス確認

```bash
# Podの状態確認
kubectl get pods -n elk-stack

# Serviceの確認
kubectl get svc -n elk-stack

# Ingressの確認
kubectl get ingress -n elk-stack
```

## 削除方法

```bash
chmod +x cleanup.sh
./cleanup.sh
```

または

```bash
kubectl delete namespace elk-stack
```

## 設定のカスタマイズ

### Elasticsearch
- `elasticsearch-configmap.yaml`でElasticsearchの設定を変更
- `elasticsearch-pv.yaml`でストレージサイズを調整

### Logstash
- `logstash-configmap.yaml`でLogstashのパイプライン設定を変更
- 入力、フィルター、出力の設定をカスタマイズ可能

### Kibana
- `kibana-configmap.yaml`でKibanaの設定を変更
- ダッシュボードやインデックスパターンの設定

## トラブルシューティング

### よくある問題

1. **Podが起動しない**
   - リソース制限を確認
   - ログを確認してエラーメッセージを確認

2. **Elasticsearchに接続できない**
   - サービス名とポート番号を確認
   - ネットワークポリシーを確認

3. **Kibanaにアクセスできない**
   - Ingress Controllerが動作していることを確認
   - ホスト名の設定を確認
   - **DNS解決エラー（DNS_PROBE_POSSIBLE）の場合**: Windowsのhostsファイルに`kibana.local`のエントリを追加する必要があります
     ```powershell
     # 管理者権限でPowerShellを実行
     .\fix-kibana-dns.ps1
     ```
     または、hostsファイル（`C:\Windows\System32\drivers\etc\hosts`）に手動で以下を追加:
     ```
     192.168.49.2    kibana.local
     ```
     （minikube IPは `minikube ip` コマンドで確認できます）

### ログの確認

```bash
# 詳細なログを確認
kubectl describe pod <pod-name> -n elk-stack
kubectl logs <pod-name> -n elk-stack
```

## Raspberry Pi rsyslog連携

Raspberry Piのrsyslogと連携してログを収集・閲覧できます。

### クイックスタート

#### 1. ELKスタックをデプロイ
```bash
./deploy.sh
```

#### 2. Windowsホスト側でポートフォワーディングを開始
```powershell
.\start-elk-portforward.ps1
```

このスクリプトは以下を自動実行します：
- Logstash syslog (UDP/TCP) のポートフォワーディング（514番ポート）
- Kibanaのポートフォワーディング（5601番ポート）
- Elasticsearchのポートフォワーディング（9200番ポート）
- ファイアウォールルールの設定確認

#### 3. Raspberry Pi (192.168.0.133) でrsyslog設定

**自動設定（推奨）:**
```bash
# スクリプトをRaspberry Piにコピー
scp setup-raspi-rsyslog.sh pi@192.168.0.133:~

# Raspberry Pi上で実行
ssh pi@192.168.0.133
chmod +x setup-raspi-rsyslog.sh
sudo ./setup-raspi-rsyslog.sh <WINDOWS_HOST_IP> udp
```

**手動設定:**
```bash
# /etc/rsyslog.d/50-elk.conf を作成
echo "*.* @<WINDOWS_HOST_IP>:514" | sudo tee /etc/rsyslog.d/50-elk.conf
sudo systemctl restart rsyslog
```

詳細は [RSYSLOG_SETUP.md](RSYSLOG_SETUP.md) を参照してください。

#### 4. テストログを送信
```bash
# Raspberry Pi上で実行
logger -p user.notice "ELK Stack test from Raspberry Pi"
```

#### 5. Kibanaでログを確認
- ブラウザで http://localhost:5601 にアクセス
- インデックスパターン `logstash-*` を作成
- Discoverでログを閲覧

### ファイル一覧

- **RSYSLOG_SETUP.md**: 詳細な設定ガイド（トラブルシューティング含む）
- **setup-raspi-rsyslog.sh**: Raspberry Pi用の自動設定スクリプト
- **start-elk-portforward.ps1**: Windows用ポートフォワーディング自動化スクリプト

## Windows Event Log連携

WindowsのイベントログをELKスタックに取り込んで監視・分析できます。

### クイックスタート

#### 1. ELKスタックをデプロイ
```bash
./deploy.sh
```

#### 2. Windowsホスト側でポートフォワーディングを開始
```powershell
.\start-elk-portforward.ps1
```

#### 3. Windows Event Log収集を設定

**自動設定（推奨）:**
```powershell
# 管理者権限でPowerShellを実行
.\setup-windows-eventlogs.ps1 -ElkStackHost "localhost" -ElkStackPort 5044
```

**手動設定:**
1. [Winlogbeat](https://www.elastic.co/downloads/beats/winlogbeat) をダウンロード・インストール
2. `winlogbeat-config.yaml` の設定を参考に `winlogbeat.yml` を設定
3. Winlogbeatサービスをインストール・開始

#### 4. KibanaでWindowsイベントログを確認
- ブラウザで http://localhost:5601 にアクセス
- インデックスパターン `winlogbeat-*` を作成
- Windows Events Overview ダッシュボードをインポート
- DiscoverでWindowsイベントログを閲覧

### 収集されるWindowsイベントログ

- **Application**: アプリケーションイベント
- **System**: システムイベント
- **Security**: セキュリティイベント
- **Microsoft-Windows-Sysmon/Operational**: Sysmonイベント
- **Microsoft-Windows-PowerShell/Operational**: PowerShellイベント
- **Microsoft-Windows-Windows Defender/Operational**: Windows Defenderイベント
- **Microsoft-Windows-TaskScheduler/Operational**: タスクスケジューラーイベント
- **Microsoft-Windows-DNS-Client/Operational**: DNSクライアントイベント
- **Microsoft-Windows-NetworkProfile/Operational**: ネットワークプロファイルイベント
- **Microsoft-Windows-WLAN-AutoConfig/Operational**: WLAN設定イベント
- **Microsoft-Windows-TerminalServices-LocalSessionManager/Operational**: ターミナルサービスイベント
- **Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational**: リモート接続マネージャーイベント

### Windows Event Log用ファイル一覧

- **setup-windows-eventlogs.ps1**: Windows Event Log収集の自動設定スクリプト
- **winlogbeat-config.yaml**: Winlogbeat設定テンプレート
- **elasticsearch-index-template.yaml**: Windowsイベントログ用のElasticsearchインデックステンプレート
- **kibana-dashboard-config.yaml**: Windowsイベントログ用のKibanaダッシュボード設定

## 注意事項

- 本番環境では、セキュリティ設定を有効にすることを推奨
- ストレージクラスは環境に応じて調整が必要
- リソース制限は環境に応じて調整が必要
