# Monitoring Stack (kube-prometheus-stack)

## Overview
This directory contains the Helm-based monitoring stack configuration using `kube-prometheus-stack`.
It replaces the hand-written Prometheus manifests in `prometheus/` with an integrated solution.

## Components
- **Prometheus**: Metrics collection and storage (8Gi persistent storage)
- **Grafana**: Dashboards and visualization (with default K8s dashboards)
- **Alertmanager**: Alert routing and notification
- **Node Exporter**: Node-level metrics collection
- **kube-state-metrics**: Kubernetes object metrics

## Migration from prometheus/
The `prometheus/` directory contains the original hand-written manifests.
This `monitoring/` directory is the replacement using HelmChartInflator.

### Migration steps:
1. Deploy monitoring stack: `kubectl kustomize monitoring/ | kubectl apply -f -`
2. Verify Grafana dashboards are working
3. Verify Prometheus targets are being scraped
4. Remove old prometheus/ manifests from ArgoCD
5. Update ArgoCD Application to point to monitoring/

## Access
```bash
# Grafana
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
# Username: admin / Password: admin

# Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

# Alertmanager
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager -n monitoring 9093:9093
```
