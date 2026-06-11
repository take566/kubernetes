# ARC monitoring quick checks

Prometheus job `arc-metrics` scrapes controller (`actions-runner-system`) and listener (`github-runners`) pods with `prometheus.io/*` annotations.

## Deploy order

1. Sync `actions-runner-controller` (enables metrics on controller + listener)
2. Sync `github-runners` (listener pod annotations)
3. Sync `prometheus` (reload via `--web.enable-lifecycle` or restart StatefulSet)

## PromQL examples

- `up{job="arc-metrics"}`
- `sum by (component, kubernetes_namespace) (up{job="arc-metrics"})`
- `gha_idle_runners{job="arc-metrics"}`
- `gha_running_jobs{job="arc-metrics"}`
- `gha_desired_runners{job="arc-metrics"}`
- `rate(gha_started_jobs_total{job="arc-metrics"}[5m])`
- `rate(container_cpu_usage_seconds_total{namespace=~"actions-runner-system|github-runners", container!=""}[5m])`
- `container_memory_working_set_bytes{namespace=~"actions-runner-system|github-runners", container!=""}`

## Verify targets

```bash
kubectl -n actions-runner-system get pod -o yaml | grep prometheus.io
kubectl -n github-runners get pod -l app.kubernetes.io/part-of=gha-runner-scale-set -o yaml | grep prometheus.io
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# open http://localhost:9090/targets and confirm arc-metrics is UP
```
