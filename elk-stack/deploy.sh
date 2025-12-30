#!/bin/bash

echo "ELK StackをKubernetesにデプロイしています..."

# 名前空間を作成
echo "名前空間を作成中..."
kubectl apply -f namespace.yaml

# Elasticsearchをデプロイ
echo "Elasticsearchをデプロイ中..."
kubectl apply -f elasticsearch-configmap.yaml
kubectl apply -f elasticsearch-pv.yaml
kubectl apply -f elasticsearch-deployment.yaml
kubectl apply -f elasticsearch-service.yaml

# Elasticsearchの起動を待つ
echo "Elasticsearchの起動を待機中..."
kubectl wait --for=condition=ready pod -l app=elasticsearch -n elk-stack --timeout=300s

# Logstashをデプロイ
echo "Logstashをデプロイ中..."
kubectl apply -f logstash-configmap.yaml
kubectl apply -f logstash-deployment.yaml
kubectl apply -f logstash-service.yaml

# Kibanaをデプロイ
echo "Kibanaをデプロイ中..."
kubectl apply -f kibana-configmap.yaml
kubectl apply -f kibana-deployment.yaml
kubectl apply -f kibana-service.yaml
kubectl apply -f kibana-ingress.yaml

# Windows Event Log用の設定をデプロイ
echo "Windows Event Log用の設定をデプロイ中..."
kubectl apply -f elasticsearch-index-template.yaml
kubectl apply -f kibana-dashboard-config.yaml
kubectl apply -f winlogbeat-config.yaml

# デプロイ完了を待つ
echo "すべてのコンポーネントの起動を待機中..."
kubectl wait --for=condition=ready pod -l app=logstash -n elk-stack --timeout=300s
kubectl wait --for=condition=ready pod -l app=kibana -n elk-stack --timeout=300s

echo "ELK Stackのデプロイが完了しました！"
echo ""
echo "アクセス情報:"
echo "- Kibana: http://kibana.local (Ingress経由)"
echo "- Elasticsearch: http://localhost:9200 (ポートフォワード経由)"
echo "- Logstash: TCP/UDP 5000, Beats 5044, Syslog 514"
echo ""
echo "ポートフォワードを設定する場合:"
echo "kubectl port-forward svc/elasticsearch 9200:9200 -n elk-stack"
echo "kubectl port-forward svc/kibana 5601:5601 -n elk-stack"
echo ""
echo "Windows Event Log収集を設定する場合:"
echo "powershell -ExecutionPolicy Bypass -File setup-windows-eventlogs.ps1 -ElkStackHost localhost"
echo ""
echo "ログを確認する場合:"
echo "kubectl logs -f deployment/elasticsearch -n elk-stack"
echo "kubectl logs -f deployment/logstash -n elk-stack"
echo "kubectl logs -f deployment/kibana -n elk-stack"
