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
# Username: admin / Password: secrets/runtime/grafana-admin.sops.env in take566/ansible
# (sops decrypt on a recipient host; set by playbooks/grafana_secrets.yml, take566/ansible#1022)

# Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

# Alertmanager
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager -n monitoring 9093:9093
```

## Central metrics store (take566/ansible#991, #1015)
On tmf-desktop this Prometheus is the fleet's central store:

- `enableRemoteWriteReceiver: true` - mac-k3s (tmf-m3) and deploynote remote_write their OpenClaw Prometheus to
  `http://100.84.245.6:19090/api/v1/write`, which take566/ansible relays to `monitoring-kube-prometheus-prometheus:9090`
  (WSL socat + Windows portproxy). There is no auth on the receiver, so it is tailnet-only.
- A default scrapeClass adds `cluster="tmf-desktop"` to every series scraped here, matching the edges' external label.
- 30d / 6GB retention inside the 8Gi PVC.
- OpenClaw's otel-collector is scraped through a ServiceMonitor, and its dashboards are ConfigMaps labeled
  `grafana_dashboard=1`, both from take566/ansible terraform/k8s. OpenClaw's own prometheus/grafana are scaled to 0
  on tmf-desktop.

The Argo Application `monitoring` has no automated sync: sync it after a merge.

## OpsDB datasource (take566/ansible#1017)
Grafana has a Postgres datasource `opsdb` for OpenClaw's `hermes-overview` / `openclaw-ops-jobs` dashboards. It logs in
to `ops-postgres.openclaw.svc` as the read-only role `grafana_ro`, which can read only three aggregate views. The
password comes from the Secret `grafana-opsdb` (env `GRAFANA_DB_PASSWORD`). take566/ansible
`playbooks/grafana_secrets.yml` sets it on the role and in the Secret from sops. Run that play before syncing a fresh
cluster: the Grafana Pod does not start without the Secrets grafana-opsdb and grafana-admin.
