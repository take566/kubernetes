#!/bin/bash

# ArgoCD での Nexus Application デプロイを確認するスクリプト

set -e

echo "🔍 ArgoCD での Nexus Application 状態を確認中..."
echo ""

# root-application の同期状態確認
echo "📍 root-application の同期状態:"
argocd app get root-application

echo ""
echo "---"
echo ""

# nexus-app の状態確認
echo "📍 nexus Application の状態:"
if argocd app info nexus &> /dev/null; then
    argocd app info nexus
else
    echo "⚠️  Nexus Application がまだ作成されていません"
    echo "💡 root-application の同期を実行してください:"
    echo "   argocd app sync root-application"
fi

echo ""
echo "---"
echo ""

# Kubernetes での確認
echo "📍 Nexus リソースの状態:"
kubectl -n nexus get all --ignore-not-found

echo ""
echo "---"
echo ""

# 詳細情報
echo "📊 詳細情報:"
echo ""
echo "ArgoCD Application 一覧:"
argocd app list | grep -E "nexus|root"

echo ""
echo "Nexus Pod ログ:"
if kubectl -n nexus get pods -l app=nexus &> /dev/null; then
    POD_NAME=$(kubectl -n nexus get pods -l app=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAME" ]; then
        echo "Pod: $POD_NAME"
        echo "最後の 10 行:"
        kubectl -n nexus logs -n nexus $POD_NAME --tail=10 2>/dev/null || echo "ログが利用可能ではありません"
    fi
fi
