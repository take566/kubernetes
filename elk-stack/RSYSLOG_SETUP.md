# Raspberry Pi rsyslog 連携設定ガイド

このガイドでは、Raspberry PiのrsyslogをKubernetes上のELKスタックと連携させる方法を説明します。

## 現在の設定情報

- **Raspberry Pi IP**: 192.168.0.133
- **Logstash syslog UDP Port**: 32667
- **Logstash syslog TCP Port**: 32667
- **Minikube IP** (WSL2内): 192.168.58.2

## ⚠️ 重要：ネットワーク設定について

MinikubeがWSL2内で動作しているため、Raspberry Piから直接アクセスするには、以下のいずれかの方法が必要です：

### 方法1: kubectl port-forwardを使用（推奨・簡単）

Windowsホスト上で以下のコマンドを実行し、ポートフォワーディングを有効にします：

```powershell
# UDPポート転送（バックグラウンドで実行）
kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0

# TCPポート転送（別のターミナルで実行）
kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0 --protocol=TCP
```

**注意**: kubectl port-forwardは、UDPとTCPを同時に転送できないため、2つのターミナルで別々に実行する必要があります。

その後、WindowsホストのIPアドレス（192.168.x.xなど）を確認：
```powershell
ipconfig | findstr "IPv4"
```

### 方法2: minikube tunnelを使用

```powershell
minikube tunnel
```

このコマンドを実行すると、Minikubeのサービスがローカルホストからアクセス可能になります。

### 方法3: 直接NodePortを使用（最も簡単だが WSL2 では制限あり）

Raspberry Piから直接Minikube NodeIPにアクセスを試みます：
- **Minikube IP**: 192.168.58.2
- **Port**: 32667

ただし、WSL2のネットワーク制限により、外部からのアクセスができない可能性があります。

## Raspberry Pi側の設定

### 1. rsyslog設定ファイルの作成

Raspberry Pi上で以下のコマンドを実行します：

```bash
# rsyslog設定ファイルを作成
sudo nano /etc/rsyslog.d/50-elk.conf
```

以下の内容を追加（**WindowsホストのIPアドレス**を使用）：

```conf
# すべてのログをELKスタックに転送（UDP）
# <WINDOWS_HOST_IP>をWindowsのIPアドレスに置き換えてください
*.* @<WINDOWS_HOST_IP>:514

# または TCP を使用する場合（より信頼性が高い）
# *.* @@<WINDOWS_HOST_IP>:514
```

**例**（WindowsホストのIPアドレスが 192.168.0.100 の場合）：
```conf
*.* @192.168.0.100:514
```

### 2. 特定のログのみを転送する場合

```conf
# システムログのみ
kern.*,user.*,daemon.* @<WINDOWS_HOST_IP>:514

# 認証ログのみ
authpriv.* @<WINDOWS_HOST_IP>:514

# エラーレベル以上のみ
*.err @<WINDOWS_HOST_IP>:514
```

### 3. rsyslogを再起動

```bash
sudo systemctl restart rsyslog
```

### 4. rsyslogの状態確認

```bash
# サービス状態確認
sudo systemctl status rsyslog

# ログを確認
sudo tail -f /var/log/syslog
```

## テストログの送信

```bash
# Raspberry Piでテストメッセージを送信
logger -p user.notice "ELK Stack test message from Raspberry Pi"
```

## Logstashでログの受信を確認

Windowsホスト上で：

```powershell
# Logstashのログを確認
kubectl logs -f deployment/logstash -n elk-stack
```

正常に動作していれば、Raspberry Piから送信されたログが表示されます。

## Kibanaでログを確認

### 1. Kibanaにアクセス

```powershell
# ポートフォワーディングを設定
kubectl port-forward svc/kibana 5601:5601 -n elk-stack
```

ブラウザで http://localhost:5601 にアクセス

### 2. インデックスパターンを作成

1. 左メニューから「Management」→「Stack Management」を選択
2. 「Kibana」→「Data Views」を選択
3. 「Create data view」をクリック
4. Name: `logstash-logs`
5. Index pattern: `logstash-*`
6. Timestamp field: `@timestamp`
7. 「Save data view to Kibana」をクリック

### 3. ログを閲覧

1. 左メニューから「Discover」を選択
2. Raspberry Piのホスト名でフィルタリング：
   ```
   syslog_hostname: "raspberrypi"
   ```

## 完全な自動化スクリプト（Windows側）

以下のPowerShellスクリプトを作成して、ポートフォワーディングを自動化できます：

`start-elk-portforward.ps1`:
```powershell
# ポートフォワーディングを開始
Write-Host "Starting port forwarding for Logstash syslog..."

# UDP用のジョブを開始
Start-Job -Name "logstash-udp" -ScriptBlock {
    kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0
}

# TCP用のジョブを開始
Start-Job -Name "logstash-tcp" -ScriptBlock {
    kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0 --protocol=TCP
}

# Kibana用のジョブを開始
Start-Job -Name "kibana" -ScriptBlock {
    kubectl port-forward svc/kibana 5601:5601 -n elk-stack --address=0.0.0.0
}

Write-Host "Port forwarding started!"
Write-Host "To stop, run: Get-Job | Stop-Job; Get-Job | Remove-Job"
```

実行：
```powershell
.\start-elk-portforward.ps1
```

停止：
```powershell
Get-Job | Stop-Job; Get-Job | Remove-Job
```

## トラブルシューティング

### ログが届かない場合

1. **ファイアウォールの確認**
   ```powershell
   # Windowsファイアウォールでポート514を許可
   New-NetFirewallRule -DisplayName "Logstash syslog UDP" -Direction Inbound -Protocol UDP -LocalPort 514 -Action Allow
   New-NetFirewallRule -DisplayName "Logstash syslog TCP" -Direction Inbound -Protocol TCP -LocalPort 514 -Action Allow
   ```

2. **ネットワーク接続の確認**
   ```bash
   # Raspberry PiからWindowsホストへの接続確認
   nc -zvu <WINDOWS_HOST_IP> 514
   ```

3. **rsyslogの設定確認**
   ```bash
   # rsyslogの設定をテスト
   sudo rsyslogd -N1
   ```

4. **Logstashの状態確認**
   ```powershell
   # Logstash Podが正常に動作しているか確認
   kubectl get pods -n elk-stack
   
   # Logstashの詳細ログを確認
   kubectl logs deployment/logstash -n elk-stack --tail=100
   ```

### ポートフォワーディングが動作しない場合

WSL2のネットワーク制限により、外部からのアクセスができない場合があります。その場合は：

1. **WSL2のネットワークモードを変更**（Windows 11のみ）
   
   `.wslconfig`ファイルを編集（`C:\Users\<ユーザー名>\.wslconfig`）：
   ```ini
   [wsl2]
   networkingMode=mirrored
   ```

2. **WSL2を再起動**
   ```powershell
   wsl --shutdown
   ```

### 文字化けする場合

`/etc/rsyslog.d/50-elk.conf`に文字エンコーディング設定を追加：
```conf
$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
$EscapeControlCharactersOnReceive off
```

## セキュリティに関する注意事項

- 本番環境では、TLS暗号化を使用することを推奨します
- ネットワークポリシーを使用して、特定のIPアドレスからのみアクセスを許可することを検討してください
- 認証を有効にすることを推奨します

## 参考情報

- [Logstash Syslog Input Plugin](https://www.elastic.co/guide/en/logstash/current/plugins-inputs-syslog.html)
- [rsyslog Documentation](https://www.rsyslog.com/doc/)
- [Kibana Guide](https://www.elastic.co/guide/en/kibana/current/index.html)
- [Minikube Networking](https://minikube.sigs.k8s.io/docs/handbook/accessing/)





