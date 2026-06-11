# kubeadm CPU-only vLLM（ROCm / GPU 不要）

WSL kubeadm で GPU が使えないときのフォールバック。推論は遅いがマニフェスト検証・OpenAI API スモークに使える。

**GPU 推論（推奨）:** [Windows Ollama 外部エンドポイント](../../../../kubeadm/scripts/register-windows-ollama-external.sh) を先に検討してください。

## デプロイ

```bash
export KUBECONFIG=~/.kube/config-kubeadm-wsl
kubectl kustomize vllm/overlays/kubeadm/cpu --load-restrictor LoadRestrictionsNone | kubectl apply -f -
kubectl -n vllm wait --for=condition=available deployment/vllm --timeout=600s
```

## 確認

```bash
kubectl -n vllm get pods
curl -s "http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}'):30800/v1/models"
```
