# Kibana DNS 解決のための hosts ファイル設定スクリプト
# 管理者権限で実行してください

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostEntry = "kibana.local"

Write-Host "Kibana DNS 設定を開始します..." -ForegroundColor Green

# cluster node IP を取得
try {
    $nodeIP = (kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $clusterIP = ($nodeIP | Out-String).Trim()
        Write-Host "cluster node IP: $clusterIP" -ForegroundColor Cyan
    }
} catch {
    Write-Host "cluster node IP の取得に失敗しました。デフォルト値を使用します: $clusterIP" -ForegroundColor Yellow
}

# hosts ファイルの内容を確認
$hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue

# 既存のエントリをチェック
$entryExists = $hostsContent | Where-Object { $_ -match "kibana\.local" }

if ($entryExists) {
    Write-Host "既存の kibana.local エントリが見つかりました:" -ForegroundColor Yellow
    $entryExists | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    
    $response = Read-Host "既存のエントリを更新しますか? (Y/N)"
    if ($response -eq "Y" -or $response -eq "y") {
        # 既存のエントリを削除
        $newContent = $hostsContent | Where-Object { $_ -notmatch "kibana\.local" }
        $newContent | Set-Content $hostsPath -Force
        Write-Host "既存のエントリを削除しました。" -ForegroundColor Green
    } else {
        Write-Host "処理をキャンセルしました。" -ForegroundColor Red
        exit
    }
}

# 新しいエントリを追加
$newEntry = "$clusterIP`t$hostEntry"
Add-Content -Path $hostsPath -Value $newEntry -Force

Write-Host "`nhosts ファイルに以下のエントリを追加しました:" -ForegroundColor Green
Write-Host "  $newEntry" -ForegroundColor Cyan

Write-Host "`nこれで http://kibana.local にアクセスできるようになりました！" -ForegroundColor Green
Write-Host "ブラウザで http://kibana.local を開いてください。" -ForegroundColor Cyan
