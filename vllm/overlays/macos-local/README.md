# vLLM × macOS ローカル開発（GPU 主経路: Ollama + Metal）

**K8s overlay（`kind` / `kubeadm`）とは別ルート**です。Apple Silicon Mac では **NVIDIA/AMD GPU がない**ため、ネイティブ Ollama（Metal）を主推論バックエンドとし、kind はマニフェスト検証・任意の CPU vLLM 実験用です。

## プロファイル

| 層 | 用途 | コマンド |
|----|------|----------|
| **1. Ollama（推奨）** | Metal GPU 推論・ベンチ | `./scripts/setup-ollama-macos.sh` |
| **2. ベンチ** | vLLM 互換メトリクス | `./scripts/bench_ollama_openai.sh` |
| **3. kind + cpu overlay** | K8s マニフェスト / CPU vLLM 実験 | `kubectl apply -k vllm/overlays/kind/cpu/` |

```
┌──────────────────────────────────────────────────────────────┐
│ 層 1: Ollama（macOS）— Metal 推論・モデル比較（主経路）        │
│   HTTP :11434  /  OpenAI互換 :11434/v1                        │
├──────────────────────────────────────────────────────────────┤
│ 層 2: ベンチパイプライン                                        │
│   bench_ollama_openai.sh — bench_vllm.py 同一 JSON 形式       │
├──────────────────────────────────────────────────────────────┤
│ 層 3: kind + vllm/overlays/kind/cpu — 任意（遅い・実験用）     │
│   openeuler/vllm-cpu イメージ、GPU 不要                         │
└──────────────────────────────────────────────────────────────┘
```

## クイックスタート（Ollama — 推奨）

```bash
# 前提: Ollama インストール済み (https://ollama.com)
./scripts/setup-ollama-macos.sh

# OpenAI 互換 API
curl -s http://127.0.0.1:11434/v1/models | jq .

curl -s http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "sam860/LFM2:1.2b",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }' | jq .
```

### 推奨モデル（Apple Silicon / 統合メモリ）

| 用途 | Ollama タグ | HF 対応 |
|------|-------------|---------|
| スモーク | `qwen2.5:0.5b` | Qwen2.5-0.5B |
| バランス | `sam860/LFM2:1.2b` | LFM2.5-1.2B |
| 品質 | `qwen2.5:1.5b` | Qwen2.5-1.5B |

HF ID → Ollama タグ: [vllm/benchmark/ollama-model-map.json](../../benchmark/ollama-model-map.json)

## ベンチマーク

```bash
./scripts/bench_ollama_openai.sh -m sam860/LFM2:1.2b

# HF ID 指定
./scripts/bench_ollama_openai.sh --hf-id Qwen/Qwen2.5-1.5B-Instruct
```

結果: `vllm/benchmark/results/`

## kind（任意 — CPU vLLM 実験）

> **注意:** 公式 `vllm/vllm-openai` は CUDA 前提です。Mac kind では **openeuler/vllm-cpu** を使う `kind/cpu` overlay を用意しています。推論は Ollama より大幅に遅いです。

```bash
# 前提: Docker (Colima/Desktop), kind, kubectl
./kind/scripts/create-cluster.sh
docker pull openeuler/vllm-cpu:0.20.1-oe2403sp3
./kind/scripts/load-images.sh   # IMAGE=vllm-cpu 等で上書き可

kubectl apply -k vllm/overlays/kind/cpu/
kubectl -n vllm get pods -w
kubectl -n vllm port-forward svc/vllm 8000:8000
```

詳細: [kind/cpu/README.md](../kind/cpu/README.md)

## 制限事項（Mac）

| 項目 | Mac | Linux GPU クラスタ |
|------|-----|-------------------|
| NVIDIA CUDA | **不可** | kubeadm overlay |
| AMD ROCm | **不可** | kubeadm/amd overlay |
| Metal (MPS) | **Ollama のみ**（vLLM 本体は非対応） | — |
| vLLM in Docker | CPU ビルドのみ（遅い） | GPU イメージ |
| kind GPU パススルー | **不可** | — |

vLLM は Apple Metal をサポートしていません。実用推論は **Ollama** を使用してください。

## 関連ドキュメント

- [overlays/windows-local/README.md](../windows-local/README.md) — Windows 向け同等ルート
- [overlays/kind/README.md](../kind/README.md) — kind overlay 全般
- [vllm/docs/MODEL_SELECTION.md](../../docs/MODEL_SELECTION.md)
