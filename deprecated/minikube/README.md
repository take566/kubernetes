# Minikube (deprecated)

Minikube-based development is **deprecated** in this repository. Use one of:

| Environment | Bootstrap | vLLM path |
|-------------|-----------|-----------|
| **kubeadm** (production) | [kubeadm/README.md](../../kubeadm/README.md) | `vllm/overlays/kubeadm` |
| **kind** (local dev) | `vllm/overlays/kind` (when available) | Argo CD: `vllm-kind` |

## Why deprecated

- Root `vllm/` kustomization uses **hostPath PV** (`/data/vllm`) tied to minikube node layout
- kubeadm overlay uses **local-path** dynamic provisioning (portable across Linux nodes)
- Argo CD no longer ships `vllm-app` pointing at root `vllm/`

## Archived minikube quick start

See [minikube-quickstart.md](./minikube-quickstart.md) for historical commands only.

## Migration checklist

1. Export model cache from minikube (if needed): see [vllm/overlays/kubeadm/README.md](../../vllm/overlays/kubeadm/README.md)
2. Bootstrap kubeadm cluster: [kubeadm/scripts/](../../kubeadm/scripts/)
3. Install Argo CD and apply `argocd/apps/root-application.yaml`
4. Sync `vllm-kubeadm` Application (replaces deleted `vllm-app`)
