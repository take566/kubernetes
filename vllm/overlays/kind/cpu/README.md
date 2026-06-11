# vLLM × kind CPU overlay（Mac / GPU なし）

GPU なし kind / WSL kubeadm / Apple Silicon Mac 向けの **CPU 推論** overlay です。

> **Mac 推奨:** 実用推論は [macos-local overlay](../../macos-local/README.md) の Ollama（Metal）を使用してください。本 overlay は K8s 上で vLLM API を試す実験用です。

## デプロイ

```bash
# Mac: CPU イメージを kind に載せる（公式 vllm/vllm-openai は CUDA 前提）
docker pull openeuler/vllm-cpu:0.20.1-oe2403sp3
export VLLM_CPU_IMAGE=openeuler/vllm-cpu:0.20.1-oe2403sp3
./kind/scripts/load-images.sh

kubectl apply -k vllm/overlays/kind/cpu/
kubectl -n vllm get pods -w
kubectl -n vllm port-forward svc/vllm 8000:8000
```

WSL + RX 5700 で GPU が必要な場合は Windows Ollama ブリッジを使用: `kubeadm/scripts/register-windows-ollama-external.sh`

## ベース kind overlay との違い

| 項目 | `kind/` | `kind/cpu/` |
|------|---------|-------------|
| イメージ | `vllm/vllm-openai`（CUDA） | `openeuler/vllm-cpu` |
| GPU リソース | 削除済み | 削除済み |
| 実際に起動 | Pending / CUDA エラー | CPU で起動（遅い） |
| teacher-stub | あり | あり（パイプライン検証） |

## トラブルシューティング

- **ImagePullBackOff** → `kind load docker-image` でイメージをノードに載せる
- **OOMKilled** → `cpu-deployment-patch.yaml` の memory limits を増やす
- **CrashLoop (CUDA)** → cpu overlay が適用されているか確認

## ベンチマーク（Mac Docker）

kind/kubectl なしでも Docker 直起動で計測可能:

```bash
./scripts/bench_vllm_macos_cpu.sh
```

結果: `vllm/benchmark/results/bench-vllm-cpu-*.json` · 比較表: [../../docs/BENCHMARK_RESULTS.md](../../docs/BENCHMARK_RESULTS.md)
