# Nexus 管理者パスワード取得スクリプト

Write-Host "🔐 Nexus 管理者パスワードを取得中..." -ForegroundColor Cyan

# Pod 名取得
$podName = kubectl -n nexus get pods -l app=nexus -o jsonpath='{.items[0].metadata.name}'

if (-not $podName) {
    Write-Host "❌ Nexus Pod が見つかりません" -ForegroundColor Red
    Write-Host "Nexus が正しくデプロイされているか確認してください" -ForegroundColor Yellow
    exit 1
}

Write-Host "Pod: $podName" -ForegroundColor Green

# パスワード取得
$password = kubectl -n nexus exec $podName -- cat /nexus-data/admin.password

Write-Host ""
Write-Host "✅ Nexus 管理者パスワード:" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host $password -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""
Write-Host "📌 このパスワードは初回ログイン後、変更することをお勧めします"
