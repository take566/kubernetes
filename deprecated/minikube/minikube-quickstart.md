# Minikube quick start (archived — do not use for new work)

> **Deprecated.** Use [kubeadm/README.md](../../kubeadm/README.md) or kind overlays instead.

```bash
minikube delete
minikube start --cpus 4 --memory 10240
minikube addons enable ingress
```

Install (legacy — hostPath):

```bash
kubectl apply -k vllm/   # superseded by vllm/overlays/kubeadm/
```

Original notes lived in repository root `minikube.md`.
