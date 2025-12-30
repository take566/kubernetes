# Kibanaに直接アクセスするためのポートフォワードスクリプト
# Ingress経由ではなく、Kibanaサービスに直接ポートフォワードします

Write-Host "Kibanaに直接アクセスするためのポートフォワードを開始します..." -ForegroundColor Green
Write-Host "ブラウザで http://localhost:5601 にアクセスしてください。" -ForegroundColor Cyan
Write-Host ""
Write-Host "停止するには Ctrl+C を押してください。" -ForegroundColor Yellow
Write-Host ""

# ポートフォワードを開始
kubectl port-forward svc/kibana 5601:5601 -n elk-stack
