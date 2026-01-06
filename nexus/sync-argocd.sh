#!/bin/bash

# ArgoCD での Nexus Application 同期スクリプト

set -e

echo "🔄 ArgoCD での Nexus Application 同期を開始します..."
echo ""

# ArgoCD CLI が インストールされているか確認
if ! command -v argocd &> /dev/null; then
    echo "❌ argocd CLI がインストールされていません"
    echo "📥 https://argo-cd.readthedocs.io/en/stable/cli_installation/ からインストールしてください"
    exit 1
fi

# ArgoCD ログイン
echo "🔐 ArgoCD にログインしています..."
ARGOCD_SERVER="argocd.local"  # TODO: 環境に合わせて変更
ARGOCD_USERNAME="admin"        # TODO: 必要に応じて変更

# パスワード取得または入力
read -sp "ArgoCD パスワード: " ARGOCD_PASSWORD
echo ""

argocd login $ARGOCD_SERVER --username $ARGOCD_USERNAME --password $ARGOCD_PASSWORD --insecure

echo "✅ ArgoCD にログインしました"
echo ""

# Application 同期
echo "🚀 Nexus Application を同期中..."
argocd app sync nexus

echo ""
echo "⏳ Nexus Application の状態を確認中..."
argocd app wait nexus

echo ""
echo "✅ Nexus Application の同期が完了しました"
echo ""

# Application 詳細情報
echo "📊 Application 詳細:"
argocd app info nexus

echo ""
echo "💡 次のコマンドで Pod の状態を確認できます:"
echo "  kubectl -n nexus get pods -w"
