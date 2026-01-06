# ArgoCD での Nexus Application デプロイを確認するスクリプト

Write-Host "🔍 ArgoCD での Nexus Application 状態を確認中..." -ForegroundColor Cyan
Write-Host ""

# root-application の同期状態確認
Write-Host "📍 root-application の同期状態:" -ForegroundColor Yellow
argocd app get root-application

Write-Host ""
Write-Host "---" -ForegroundColor Gray
Write-Host ""

# nexus-app の状態確認
Write-Host "📍 nexus Application の状態:" -ForegroundColor Yellow

$nexusAppExists = argocd app info nexus -ErrorAction SilentlyContinue

if ($?) {
    argocd app info nexus
} else {
    Write-Host "⚠️  Nexus Application がまだ作成されていません" -ForegroundColor Yellow
    Write-Host "💡 root-application の同期を実行してください:" -ForegroundColor Cyan
    Write-Host "   argocd app sync root-application"
}

Write-Host ""
Write-Host "---" -ForegroundColor Gray
Write-Host ""

# Kubernetes での確認
Write-Host "📍 Nexus リソースの状態:" -ForegroundColor Yellow
kubectl -n nexus get all --ignore-not-found

Write-Host ""
Write-Host "---" -ForegroundColor Gray
Write-Host ""

# 詳細情報
Write-Host "📊 詳細情報:" -ForegroundColor Cyan
Write-Host ""

Write-Host "ArgoCD Application 一覧:" -ForegroundColor Yellow
argocd app list | Select-String -Pattern "nexus|root"

Write-Host ""
Write-Host "Nexus Pod ログ:" -ForegroundColor Yellow

$podExists = kubectl -n nexus get pods -l app=nexus -ErrorAction SilentlyContinue

if ($podExists) {
    $podName = kubectl -n nexus get pods -l app=nexus -o jsonpath='{.items[0].metadata.name}' 2>$null

    if ($podName) {
        Write-Host "Pod: $podName" -ForegroundColor Green
        Write-Host "最後の 10 行:" -ForegroundColor Yellow
        kubectl -n nexus logs $podName --tail=10 2>$null
    }
} else {
    Write-Host "ログが利用可能ではありません" -ForegroundColor Yellow
}
