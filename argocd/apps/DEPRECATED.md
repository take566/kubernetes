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
| `nexus` | `nexus` | Yes | nexus | Artifact repository |
| `cert-manager` | `cert-manager` | Yes | cert-manager | TLS operator (Helm via kustomize) |
| `agents` | `agents/hermes` | Yes | agents | Hermes agent stack |
| `prometheus` | `prometheus` | Yes | monitoring | Lightweight Prometheus manifests |
| `monitoring` | `monitoring` | No | monitoring | kube-prometheus-stack — conflicts with `prometheus` |
| `gitlab` | `gitlab` | No | gitlab | GitLab Helm (heavy/stateful) |
| `jenkins` | `jenkins` | No | jenkins | Jenkins Helm (stateful CI/CD) |
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