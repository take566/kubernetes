# ELK Stack ポートフォワーディング開始スクリプト
# Raspberry Pi rsyslog連携用
#
# 使用方法:
#   .\start-elk-portforward.ps1
#
# 停止方法:
#   Get-Job | Stop-Job; Get-Job | Remove-Job
#

Write-Host "=== ELK Stack ポートフォワーディング開始 ===" -ForegroundColor Green
Write-Host ""

# クラスターの状態確認
Write-Host "Kubernetesクラスターの状態を確認中..." -ForegroundColor Yellow
$clusterInfo = kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: Kubernetesクラスターに接続できません" -ForegroundColor Red
    Write-Host "Minikubeが起動していることを確認してください: minikube status" -ForegroundColor Yellow
    exit 1
}

# ELKスタックの状態確認
Write-Host "ELKスタックの状態を確認中..." -ForegroundColor Yellow
$elkPods = kubectl get pods -n elk-stack --no-headers 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: elk-stack名前空間が見つかりません" -ForegroundColor Red
    Write-Host "ELKスタックをデプロイしてください: .\deploy.sh" -ForegroundColor Yellow
    exit 1
}

# Podの状態表示
Write-Host "`nELKスタックのPod状態:" -ForegroundColor Cyan
kubectl get pods -n elk-stack

# すべてのPodがRunningか確認
$notReady = kubectl get pods -n elk-stack --no-headers | Where-Object { $_ -notmatch '\s1/1\s+Running\s' }
if ($notReady) {
    Write-Host "`n警告: 一部のPodがReady状態ではありません" -ForegroundColor Yellow
    Write-Host "すべてのPodが起動するまで待機することを推奨します" -ForegroundColor Yellow
    $response = Read-Host "続行しますか？ (y/N)"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "中止しました" -ForegroundColor Yellow
        exit 0
    }
}

# WindowsホストのIPアドレスを表示
Write-Host "`nWindowsホストのIPアドレス:" -ForegroundColor Cyan
$ipAddresses = Get-NetIPAddress -AddressFamily IPv4 | 
    Where-Object { $_.IPAddress -like "192.168.*" -or $_.IPAddress -like "10.*" } |
    Select-Object IPAddress, InterfaceAlias

$ipAddresses | Format-Table -AutoSize

if ($ipAddresses.Count -gt 0) {
    $hostIP = $ipAddresses[0].IPAddress
    Write-Host "Raspberry Piの設定に使用するIPアドレス: $hostIP" -ForegroundColor Green
} else {
    Write-Host "警告: プライベートIPアドレスが見つかりませんでした" -ForegroundColor Yellow
    $hostIP = "localhost"
}

Write-Host ""

# 既存のジョブをクリーンアップ
Write-Host "既存のポートフォワーディングジョブをクリーンアップ中..." -ForegroundColor Yellow
Get-Job | Where-Object { $_.Name -like "elk-*" } | Stop-Job
Get-Job | Where-Object { $_.Name -like "elk-*" } | Remove-Job
Start-Sleep -Seconds 2

# ポートフォワーディングを開始
Write-Host "ポートフォワーディングを開始中..." -ForegroundColor Yellow
Write-Host ""

# Logstash syslog (UDP) - ポート514
Write-Host "1. Logstash syslog UDP (ポート 514)..." -ForegroundColor Cyan
Start-Job -Name "elk-logstash-udp-514" -ScriptBlock {
    kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0
} | Out-Null

# Logstash syslog (TCP) - ポート514
Write-Host "2. Logstash syslog TCP (ポート 514)..." -ForegroundColor Cyan
Start-Job -Name "elk-logstash-tcp-514" -ScriptBlock {
    kubectl port-forward svc/logstash 514:514 -n elk-stack --address=0.0.0.0
} | Out-Null

# Kibana
Write-Host "3. Kibana (ポート 5601)..." -ForegroundColor Cyan
Start-Job -Name "elk-kibana" -ScriptBlock {
    kubectl port-forward svc/kibana 5601:5601 -n elk-stack --address=0.0.0.0
} | Out-Null

# Elasticsearch (オプション)
Write-Host "4. Elasticsearch (ポート 9200)..." -ForegroundColor Cyan
Start-Job -Name "elk-elasticsearch" -ScriptBlock {
    kubectl port-forward svc/elasticsearch 9200:9200 -n elk-stack --address=0.0.0.0
} | Out-Null

# ジョブの起動を待機
Start-Sleep -Seconds 5

# ジョブの状態確認
Write-Host ""
Write-Host "ポートフォワーディングジョブの状態:" -ForegroundColor Cyan
Get-Job | Where-Object { $_.Name -like "elk-*" } | Format-Table -AutoSize

$runningJobs = Get-Job | Where-Object { $_.Name -like "elk-*" -and $_.State -eq "Running" }
if ($runningJobs.Count -eq 4) {
    Write-Host "`n✓ すべてのポートフォワーディングが正常に起動しました！" -ForegroundColor Green
} else {
    Write-Host "`n警告: 一部のポートフォワーディングが起動していません" -ForegroundColor Yellow
    Write-Host "詳細を確認するには: Get-Job | Receive-Job" -ForegroundColor Yellow
}

# Windowsファイアウォール設定の確認
Write-Host ""
Write-Host "ファイアウォール設定の確認..." -ForegroundColor Yellow
$firewallRules = Get-NetFirewallRule -DisplayName "*Logstash*" -ErrorAction SilentlyContinue

if ($firewallRules.Count -eq 0) {
    Write-Host "警告: Logstash用のファイアウォールルールが見つかりません" -ForegroundColor Yellow
    $response = Read-Host "ファイアウォールルールを作成しますか？ (管理者権限が必要) (y/N)"
    if ($response -eq 'y' -or $response -eq 'Y') {
        try {
            New-NetFirewallRule -DisplayName "Logstash syslog UDP" -Direction Inbound -Protocol UDP -LocalPort 514 -Action Allow | Out-Null
            New-NetFirewallRule -DisplayName "Logstash syslog TCP" -Direction Inbound -Protocol TCP -LocalPort 514 -Action Allow | Out-Null
            Write-Host "✓ ファイアウォールルールを作成しました" -ForegroundColor Green
        } catch {
            Write-Host "エラー: ファイアウォールルールの作成に失敗しました (管理者権限が必要です)" -ForegroundColor Red
            Write-Host "手動で設定してください:" -ForegroundColor Yellow
            Write-Host "  New-NetFirewallRule -DisplayName 'Logstash syslog UDP' -Direction Inbound -Protocol UDP -LocalPort 514 -Action Allow" -ForegroundColor Gray
            Write-Host "  New-NetFirewallRule -DisplayName 'Logstash syslog TCP' -Direction Inbound -Protocol TCP -LocalPort 514 -Action Allow" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "✓ ファイアウォールルールが設定されています" -ForegroundColor Green
}

# アクセス情報を表示
Write-Host ""
Write-Host "=== アクセス情報 ===" -ForegroundColor Green
Write-Host ""
Write-Host "Kibana:" -ForegroundColor Cyan
Write-Host "  - URL: http://localhost:5601" -ForegroundColor White
Write-Host "  - URL (外部): http://${hostIP}:5601" -ForegroundColor White
Write-Host ""
Write-Host "Elasticsearch:" -ForegroundColor Cyan
Write-Host "  - URL: http://localhost:9200" -ForegroundColor White
Write-Host "  - ヘルスチェック: curl http://localhost:9200/_cluster/health" -ForegroundColor White
Write-Host ""
Write-Host "Logstash (rsyslog):" -ForegroundColor Cyan
Write-Host "  - syslog UDP: ${hostIP}:514" -ForegroundColor White
Write-Host "  - syslog TCP: ${hostIP}:514" -ForegroundColor White
Write-Host ""

# Raspberry Pi設定手順
Write-Host "=== Raspberry Pi設定手順 ===" -ForegroundColor Green
Write-Host ""
Write-Host "1. setup-raspi-rsyslog.sh をRaspberry Piにコピー:" -ForegroundColor Yellow
Write-Host "   scp setup-raspi-rsyslog.sh pi@192.168.0.133:~" -ForegroundColor White
Write-Host ""
Write-Host "2. Raspberry Pi上で実行:" -ForegroundColor Yellow
Write-Host "   chmod +x setup-raspi-rsyslog.sh" -ForegroundColor White
Write-Host "   sudo ./setup-raspi-rsyslog.sh $hostIP udp" -ForegroundColor White
Write-Host ""
Write-Host "3. テストログを送信:" -ForegroundColor Yellow
Write-Host "   logger -p user.notice 'ELK Stack test from Raspberry Pi'" -ForegroundColor White
Write-Host ""
Write-Host "4. Logstashのログを確認:" -ForegroundColor Yellow
Write-Host "   kubectl logs -f deployment/logstash -n elk-stack" -ForegroundColor White
Write-Host ""

# 停止方法を表示
Write-Host "=== ポートフォワーディング停止方法 ===" -ForegroundColor Yellow
Write-Host ""
Write-Host "すべて停止:" -ForegroundColor Cyan
Write-Host "  Get-Job | Stop-Job; Get-Job | Remove-Job" -ForegroundColor White
Write-Host ""
Write-Host "特定のジョブのみ停止:" -ForegroundColor Cyan
Write-Host "  Stop-Job -Name elk-logstash-udp-514" -ForegroundColor White
Write-Host "  Remove-Job -Name elk-logstash-udp-514" -ForegroundColor White
Write-Host ""

Write-Host "=== ポートフォワーディングが動作中です ===" -ForegroundColor Green
Write-Host "このウィンドウを閉じないでください" -ForegroundColor Yellow
Write-Host ""





