#!/bin/bash

# Nexus Repository Manager デプロイスクリプト
# npm および Docker レジストリ管理用

set -e

echo "🚀 Nexus Repository Manager をデプロイしています..."

# Namespace 作成
echo "📦 Namespace を作成中..."
kubectl apply -f namespace.yaml

# PersistentVolume と PersistentVolumeClaim 作成
echo "💾 PersistentVolume と PersistentVolumeClaim を作成中..."
kubectl apply -f nexus-pv.yaml

# Deployment 作成
echo "🐳 Nexus Deployment を作成中..."
kubectl apply -f nexus-deployment.yaml

# Service 作成
echo "🔌 Service を作成中..."
kubectl apply -f nexus-service.yaml

# Ingress 作成
echo "🌐 Ingress を作成中..."
kubectl apply -f nexus-ingress.yaml

echo ""
echo "✅ Nexus のデプロイが完了しました！"
echo ""
echo "📊 Nexus のデプロイ状態を確認中..."
kubectl -n nexus get pods -w

echo ""
echo "🔗 アクセス方法:"
echo "  - Nexus Web UI: http://nexus.local:8081"
echo "  - Docker Registry: docker-registry.local:8082"
echo "  - npm Registry: npm-registry.local:8083"
echo ""
echo "💡 ローカルアクセス (NodePort):"
echo "  - Nexus Web UI: http://<node-ip>:30081"
echo "  - Docker Registry: <node-ip>:30082"
echo "  - npm Registry: <node-ip>:30083"
echo ""
echo "🔑 デフォルト認証情報:"
echo "  - ユーザー名: admin"
echo "  - パスワード: (初回アクセス時に /nexus-data/admin.password から取得)"
echo ""
echo "初回パスワードを取得するには:"
echo "  kubectl -n nexus exec -it \$(kubectl -n nexus get pods -l app=nexus -o jsonpath='{.items[0].metadata.name}') -- cat /nexus-data/admin.password"
