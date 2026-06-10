# Deprecated Argo CD Applications

## Removed: `vllm-app.yaml` (legacy root `vllm/` path)

| Old | Replacement |
|-----|-------------|
| `vllm` → `vllm/` (hostPath PV, legacy) | `vllm-kubeadm` → `vllm/overlays/kubeadm` |
| `vllm-amd` → `vllm/amd/` | `vllm-amd` → `vllm/overlays/kubeadm/amd` |
| `vllm-finetune` → `vllm/finetune/` | `vllm-finetune` → `vllm/overlays/kubeadm/finetune` |

### Multi-environment naming (coordinate with kind overlay agent)

| Application | Path | Auto sync | Notes |
|-------------|------|-----------|-------|
| `vllm-kubeadm` | `vllm/overlays/kubeadm` | Yes | Production kubeadm (NVIDIA) |
| `vllm-kind` | `vllm/overlays/kind` | No | Local kind dev (manual — no GPU auto-deploy) |
| `vllm-amd` | `vllm/overlays/kubeadm/amd` | No | AMD inference — enable one stack only |
| `vllm-finetune` | `vllm/overlays/kubeadm/finetune` | No | AMD LoRA Job |
| `vllm-benchmark` | `vllm/benchmark` | No | On-demand perf Jobs |

**Rule:** Only `vllm-kubeadm` uses automated sync for NVIDIA inference. Enable `vllm-amd` manual sync only after disabling/removing kubeadm auto sync in the same cluster.

### Migration from legacy root `vllm/`

1. Delete old Application: `kubectl delete application vllm -n argocd` (if present)
2. Commit pulls in `vllm-kubeadm-app.yaml` via root-application
3. Sync `vllm-kubeadm` in Argo CD UI or `argocd app sync vllm-kubeadm`

See [kind/README.md](../../kind/README.md) and [kubeadm/README.md](../../kubeadm/README.md).`n