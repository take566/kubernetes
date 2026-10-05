# Deprecated Argo CD Applications

## Removed: `vllm-app.yaml` (legacy root `vllm/` path)

| Old | Replacement |
|-----|-------------|
| `vllm` → root `vllm/` or `vllm/base/` alone (no PVC) | `vllm-kubeadm` → `vllm/overlays/kubeadm` |
| `vllm-amd` → `vllm/amd/` (removed) | `vllm-amd` → `vllm/overlays/kubeadm/amd` |
| `vllm-finetune` → `vllm/finetune/` (removed) | `vllm-finetune` → `vllm/overlays/kubeadm/finetune` |

## Application inventory (managed by root-application)

| Application | Path | Auto sync | Namespace | Notes |
|-------------|------|-----------|-----------|-------|
| `root-application` | `argocd/apps` | Yes | argocd | App of Apps |
| `vllm-kubeadm` | `vllm/overlays/kubeadm` | Yes | vllm | Production NVIDIA inference |
| `vllm-kind` | `vllm/overlays/kind` | No | vllm | Local kind dev (no GPU auto-deploy) |
| `vllm-amd` | `vllm/overlays/kubeadm/amd` | No | vllm | AMD inference — one stack only |
| `vllm-finetune` | `vllm/overlays/kubeadm/finetune` | No | vllm | AMD LoRA Job |
| `vllm-benchmark` | `vllm/benchmark` | No | vllm | On-demand perf Jobs |
| `nginx` | `nginx` | Yes | default | Ingress sample |
| `nexus` | `nexus/overlays/deploy-note` | Yes | nexus | Artifact repository (Ingress removed on deploy-note, NodePort only, #70) |
| `cert-manager` | `cert-manager` | Yes | cert-manager | TLS operator (Helm via kustomize) |
| `agents` | `agents/hermes` | Yes | agents | Hermes agent stack |
| `prometheus` | `prometheus/overlays/deploy-note` | Yes | monitoring | Lightweight Prometheus manifests (Ingress removed on deploy-note, port-forward only, #73) |
| `monitoring` | `monitoring` | No | monitoring | kube-prometheus-stack — conflicts with `prometheus` |
| `jenkins` | `jenkins` | No | jenkins | Jenkins Helm (stateful CI/CD) |
| `actions-runner-controller` | `actions-runner-controller` | No | actions-runner-system | ARC v2 scale-set controller (sync before github-runners) |
| `github-runners` | `github-runners` | No | github-runners | GitHub Actions self-hosted runners (Secret required) |
| `elk-stack` | `elk-stack` | No | elk-stack | ELK stack (stateful) |

### GitOps excluded (bootstrap / reference only)

| Path | Reason |
|------|--------|
| `kind/`, `kubeadm/` | Cluster bootstrap, not GitOps apps |
| `vllm/base`, `vllm/components` | Consumed via overlays only |
| `docs/`, `scripts/`, `policies/` | Operational helpers |

**Rule:** Only `vllm-kubeadm` uses automated sync for NVIDIA inference. Enable `vllm-amd` manual sync only after disabling/removing kubeadm auto sync in the same cluster.

**Rule:** Do not auto-sync both `prometheus` and `monitoring` — they target the same namespace.

### Migration from legacy root `vllm/`

1. Delete old Application: `kubectl delete application vllm -n argocd` (if present)
2. Commit pulls in `vllm-kubeadm-app.yaml` via root-application
3. Sync `vllm-kubeadm` in Argo CD UI or `argocd app sync vllm-kubeadm`

See [kind/README.md](../../kind/README.md) and [kubeadm/README.md](../../kubeadm/README.md).
## Inactive: kept in `argocd/apps-inactive/`, not synced by root-application

| Application | Why | To restore |
|-------------|-----|------------|
| `gitlab` | `gitlab/` held only a dangling gitlink with no chart (#44/#75), so the app was a permanent ComparisonError and never deployed anything | Vendor or reference the chart properly, then `git mv` the manifest back into `argocd/apps/` |
