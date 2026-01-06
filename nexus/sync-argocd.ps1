# ArgoCD での Nexus Application 同期スクリプト

Write-Host "🔄 ArgoCD での Nexus Application 同期を開始します..." -ForegroundColor Cyan
Write-Host ""

# ArgoCD CLI がインストールされているか確認
$argocdCmd = Get-Command argocd -ErrorAction SilentlyContinue

if (-not $argocdCmd) {
    Write-Host "❌ argocd CLI がインストールされていません" -ForegroundColor Red
    Write-Host "📥 https://argo-cd.readthedocs.io/en/stable/cli_installation/ からインストールしてください" -ForegroundColor Yellow
    exit 1
}

# ArgoCD ログイン
Write-Host "🔐 ArgoCD にログインしています..." -ForegroundColor Yellow

$ARGOCD_SERVER = Read-Host "ArgoCD サーバー (デフォルト: argocd.local)"
if ([string]::IsNullOrEmpty($ARGOCD_SERVER)) { $ARGOCD_SERVER = "argocd.local" }

$ARGOCD_USERNAME = Read-Host "ユーザー名 (デフォルト: admin)"
if ([string]::IsNullOrEmpty($ARGOCD_USERNAME)) { $ARGOCD_USERNAME = "admin" }

$ARGOCD_PASSWORD = Read-Host "パスワード" -AsSecureString

# SecureString を平文に変換
$ARGOCD_PASSWORD_PLAIN = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($ARGOCD_PASSWORD)
)

argocd login $ARGOCD_SERVER --username $ARGOCD_USERNAME --password $ARGOCD_PASSWORD_PLAIN --insecure

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ ArgoCD にログインしました" -ForegroundColor Green
} else {
    Write-Host "❌ ログインに失敗しました" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Application 同期
Write-Host "🚀 Nexus Application を同期中..." -ForegroundColor Cyan
argocd app sync nexus

Write-Host ""
Write-Host "⏳ Nexus Application の状態を確認中..." -ForegroundColor Yellow
argocd app wait nexus

Write-Host ""
Write-Host "✅ Nexus Application の同期が完了しました" -ForegroundColor Green
Write-Host ""

# Application 詳細情報
Write-Host "📊 Application 詳細:" -ForegroundColor Cyan
argocd app info nexus

Write-Host ""
Write-Host "💡 次のコマンドで Pod の状態を確認できます:" -ForegroundColor Green
Write-Host "  kubectl -n nexus get pods -w"
