# kind CPU-only vLLM

GPU なし kind / WSL kubeadm の CPU スモーク用 overlay。

```bash
kubectl kustomize vllm/overlays/kind/cpu --load-restrictor LoadRestrictionsNone | kubectl apply -f -
```

WSL + RX 5700 で GPU が必要な場合は Windows Ollama ブリッジを使用: `kubeadm/scripts/register-windows-ollama-external.sh`
