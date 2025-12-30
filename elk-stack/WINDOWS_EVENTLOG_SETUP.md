# Windows Event Log Collection Setup Guide

このガイドでは、ELKスタックを使用してWindowsのイベントログを収集・監視する方法について説明します。

## 概要

Windows Event Log Collectionは、Winlogbeatを使用してWindowsシステムのイベントログをELKスタックに送信し、Kibanaで可視化・分析する仕組みです。

## 前提条件

- Windows 10/11 または Windows Server 2016以降
- PowerShell 5.1以降
- 管理者権限
- ELKスタックがデプロイ済み（Kubernetes上）
- ネットワーク接続（ELKスタックへのアクセス）

## クイックスタート

### 1. ELKスタックのデプロイ

```bash
# ELKスタックをデプロイ
./deploy.sh

# ポートフォワーディングを開始
.\start-elk-portforward.ps1
```

### 2. Windows Event Log収集の設定

```powershell
# 管理者権限でPowerShellを実行
.\setup-windows-eventlogs.ps1 -ElkStackHost "localhost" -ElkStackPort 5044
```

### 3. Kibanaでの確認

1. ブラウザで http://localhost:5601 にアクセス
2. インデックスパターン `winlogbeat-*` を作成
3. Windows Events Overview ダッシュボードをインポート
4. DiscoverでWindowsイベントログを閲覧

## 詳細設定

### Winlogbeat設定

`winlogbeat-config.yaml` ファイルには、以下のWindowsイベントログが設定されています：

#### 基本イベントログ
- **Application**: アプリケーションイベント
- **System**: システムイベント
- **Security**: セキュリティイベント

#### 詳細イベントログ
- **Microsoft-Windows-Sysmon/Operational**: Sysmonイベント（プロセス監視）
- **Microsoft-Windows-PowerShell/Operational**: PowerShellイベント
- **Microsoft-Windows-Windows Defender/Operational**: Windows Defenderイベント
- **Microsoft-Windows-TaskScheduler/Operational**: タスクスケジューラーイベント
- **Microsoft-Windows-DNS-Client/Operational**: DNSクライアントイベント
- **Microsoft-Windows-NetworkProfile/Operational**: ネットワークプロファイルイベント
- **Microsoft-Windows-WLAN-AutoConfig/Operational**: WLAN設定イベント
- **Microsoft-Windows-TerminalServices-LocalSessionManager/Operational**: ターミナルサービスイベント
- **Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational**: リモート接続マネージャーイベント

### 手動設定

自動設定スクリプトを使用しない場合は、以下の手順で手動設定できます：

#### 1. Winlogbeatのダウンロード・インストール

```powershell
# Winlogbeatをダウンロード
$DownloadUrl = "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-8.11.0-windows-x86_64.zip"
$ZipFile = "$env:TEMP\winlogbeat.zip"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipFile

# 展開
Expand-Archive -Path $ZipFile -DestinationPath "C:\ProgramData\" -Force
```

#### 2. 設定ファイルの作成

`C:\ProgramData\winlogbeat\winlogbeat.yml` を作成し、`winlogbeat-config.yaml` の内容をコピーして、ELKスタックのホスト名を適切に設定します。

#### 3. サービスのインストール・開始

```powershell
# Winlogbeatディレクトリに移動
cd C:\ProgramData\winlogbeat

# サービスをインストール
.\winlogbeat.exe install service -c .\winlogbeat.yml

# サービスを開始
Start-Service winlogbeat
```

## 監視・分析

### Kibanaダッシュボード

以下のダッシュボードが利用可能です：

1. **Windows Events Overview**: 全体的なWindowsイベントの概要
2. **Windows Events by Level**: イベントレベル別の分布
3. **Windows Events Timeline**: 時系列でのイベント推移
4. **Windows Events by Source**: イベントソース別の分析
5. **Windows Events by Computer**: コンピューター別の分析
6. **Windows Security Events**: セキュリティイベントの詳細

### 重要なイベントID

監視すべき重要なWindowsイベントID：

#### セキュリティイベント
- **4624**: ログオン成功
- **4625**: ログオン失敗
- **4634**: ログオフ
- **4648**: 明示的な資格情報を使用したログオン
- **4720**: ユーザーアカウント作成
- **4722**: ユーザーアカウント有効化
- **4724**: パスワードリセット
- **4732**: ローカルグループへのメンバー追加
- **4735**: セキュリティが有効なローカルグループの変更
- **4740**: ユーザーアカウントのロックアウト
- **4771**: Kerberos認証前チケット要求失敗
- **4776**: コンピューターがアカウントの資格情報を検証
- **4781**: アカウント名が変更
- **4793**: パスワードポリシーチェックAPIが呼び出し
- **5376**: 資格情報マネージャーが資格情報を読み取り
- **5377**: 資格情報マネージャーが資格情報を書き込み

#### システムイベント
- **6005**: イベントログサービス開始
- **6006**: イベントログサービス停止
- **6008**: 予期しないシステムシャットダウン
- **6009**: システム開始
- **6013**: システム稼働時間
- **1074**: システムシャットダウン開始
- **1076**: システムシャットダウン開始（ユーザー開始）

#### アプリケーションイベント
- **1000**: アプリケーションエラー
- **1001**: アプリケーションクラッシュ
- **1002**: アプリケーション応答なし

## トラブルシューティング

### よくある問題

#### 1. Winlogbeatサービスが開始しない

```powershell
# サービス状態を確認
Get-Service winlogbeat

# ログを確認
Get-Content C:\ProgramData\winlogbeat\logs\winlogbeat.log -Tail 50

# 設定ファイルの構文チェック
C:\ProgramData\winlogbeat\winlogbeat.exe test config -c C:\ProgramData\winlogbeat\winlogbeat.yml
```

#### 2. ELKスタックに接続できない

```powershell
# ネットワーク接続を確認
Test-NetConnection -ComputerName localhost -Port 5044

# ファイアウォール設定を確認
Get-NetFirewallRule -DisplayName "*Winlogbeat*"
```

#### 3. イベントログが表示されない

1. Kibanaでインデックスパターン `winlogbeat-*` が作成されているか確認
2. Elasticsearchにデータが送信されているか確認
3. LogstashのログでWindowsイベントログの処理状況を確認

```bash
# Logstashのログを確認
kubectl logs -f deployment/logstash -n elk-stack

# Elasticsearchのインデックスを確認
kubectl exec -it deployment/elasticsearch -n elk-stack -- curl -X GET "localhost:9200/_cat/indices?v"
```

### ログの確認

#### Winlogbeatログ
```powershell
# リアルタイムログ
Get-Content C:\ProgramData\winlogbeat\logs\winlogbeat.log -Tail 50 -Wait

# エラーログのみ
Get-Content C:\ProgramData\winlogbeat\logs\winlogbeat.log | Select-String "ERROR"
```

#### ELKスタックログ
```bash
# Elasticsearchログ
kubectl logs -f deployment/elasticsearch -n elk-stack

# Logstashログ
kubectl logs -f deployment/logstash -n elk-stack

# Kibanaログ
kubectl logs -f deployment/kibana -n elk-stack
```

## セキュリティ考慮事項

### 1. ネットワークセキュリティ
- ELKスタックへの通信は暗号化を推奨
- ファイアウォールで適切なポート制限を設定
- VPN経由での接続を検討

### 2. データ保護
- 機密情報を含むイベントログの取り扱いに注意
- 適切なアクセス制御を設定
- ログの保持期間を設定

### 3. 監査
- Winlogbeatの設定変更を監査
- イベントログの収集状況を監視
- 異常なアクセスパターンを検出

## パフォーマンス最適化

### 1. イベントログのフィルタリング
```yaml
winlogbeat.event_logs:
  - name: Application
    level: error  # エラーレベルのみ収集
    include_xml: false  # XMLデータを除外
```

### 2. バッファサイズの調整
```yaml
queue.mem:
  events: 4096
  flush.min_events: 1024
  flush.timeout: 1s
```

### 3. インデックス設定の最適化
```yaml
setup.template.settings:
  index.number_of_shards: 1
  index.number_of_replicas: 0
  index.refresh_interval: 30s
```

## メンテナンス

### 1. 定期的な確認事項
- Winlogbeatサービスの状態
- ディスク使用量
- ログファイルのサイズ
- ネットワーク接続状況

### 2. ログローテーション
```yaml
logging.files:
  keepfiles: 7  # 7日分のログを保持
  rotateeverybytes: 10485760  # 10MBでローテーション
```

### 3. インデックス管理
```bash
# 古いインデックスを削除
kubectl exec -it deployment/elasticsearch -n elk-stack -- curl -X DELETE "localhost:9200/winlogbeat-2023.01.*"
```

## 関連ファイル

- `setup-windows-eventlogs.ps1`: 自動設定スクリプト
- `winlogbeat-config.yaml`: Winlogbeat設定テンプレート
- `elasticsearch-index-template.yaml`: Elasticsearchインデックステンプレート
- `kibana-dashboard-config.yaml`: Kibanaダッシュボード設定
- `logstash-configmap.yaml`: Logstash設定（Windowsイベントログ処理）

## 参考資料

- [Winlogbeat公式ドキュメント](https://www.elastic.co/guide/en/beats/winlogbeat/current/index.html)
- [Windows Event Log Reference](https://docs.microsoft.com/en-us/windows/security/threat-protection/auditing/event-4625)
- [ELK Stack公式ドキュメント](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html)
