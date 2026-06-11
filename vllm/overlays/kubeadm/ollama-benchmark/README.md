# kubeadm + Windows Ollama benchmark overlay

Applies `vllm/benchmark/` with ConfigMap overrides for the `ollama-external` Service (no in-cluster vLLM GPU on WSL).

```bash
export KUBECONFIG=~/.kube/config-kubeadm-wsl
./kubeadm/scripts/register-windows-ollama-external.sh --verify
kubectl apply -k vllm/overlays/kubeadm/ollama-benchmark/
kubectl wait --for=condition=complete job/vllm-benchmark -n vllm --timeout=30m
```

Results are written inside the Job pod under `/tmp/vllm-bench/` (emptyDir). For local runs use `scripts/bench_ollama_openai.ps1`.
