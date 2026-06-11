# GTX 1650 (4GB VRAM) on kubeadm

`scripts/run-vllm-docker.ps1` と同じモデル・メモリ設定を Kubernetes 向けに適用します。

```bash
kubectl apply -k vllm/overlays/kubeadm/gtx1650/
```

- モデル: Qwen2.5-0.5B-Instruct
- NodePort: 30800（ベース Service 継承）
