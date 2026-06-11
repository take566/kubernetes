# vLLM × Windows ローカル開発（GPU 主経路: Ollama）

**K8s overlay（`kind` / `kubeadm`）とは別ルート**です。VRAM と GPU ベンダーに応じて、Windows ネイティブの Ollama を主 GPU バックエンドとして使います。

## プロファイル別ルート

| プロファイル | GPU | 主スクリプト | 備考 |
|-------------|-----|-------------|------|
| **RX 5700 8GB (AMD)** | Ollama CUDA/ROCm on Windows | `scripts/setup-ollama-rx5700.ps1` | **推奨** — WSL ROCm は非対応 |
| GTX 1650 4GB (NVIDIA) | Ollama + 任意 Docker vLLM | `scripts/setup-vllm-windows.ps1` | CUDA Container Toolkit |

```
┌──────────────────────────────────────────────────────────────┐
│ 層 1: Ollama（Windows）— GPU 推論・モデル比較（主経路）         │
│   HTTP :11434  /  OpenAI互換 :11434/v1                        │
├──────────────────────────────────────────────────────────────┤
│ 層 2: ベンチパイプライン                                        │
│   compare_models_ollama.ps1  — HF候補一括比較                 │
│   bench_ollama_openai.ps1    — bench_vllm.py 同一 JSON 形式   │
├──────────────────────────────────────────────────────────────┤
│ 層 3: Docker vLLM（NVIDIA のみ・副経路）                      │
│   run-vllm-docker.ps1 → :8000/v1                              │
├──────────────────────────────────────────────────────────────┤
│ 層 4: kind + vllm/overlays/kind — CI / マニフェスト検証のみ    │
└──────────────────────────────────────────────────────────────┘
```

## RX 5700 — クイックスタート

```powershell
.\scripts\detect-gpu.ps1
.\scripts\setup-ollama-rx5700.ps1
```

Ollama のみ（ベンチ省略）:

```powershell
.\scripts\setup-ollama-rx5700.ps1 -SkipBenchmark
```

### 推奨モデル（8GB VRAM）

| 用途 | Ollama タグ | HF 対応 |
|------|-------------|---------|
| kind スモーク | `qwen2.5:0.5b` / `qwen2.5:0.5b-rx5700` | Qwen2.5-0.5B |
| 本番候補 | `qwen2.5:1.5b` / `qwen2.5:1.5b-rx5700` | Qwen2.5-1.5B |
| 高速候補 | `sam860/LFM2:1.2b` | LFM2.5-1.2B |
| 拡張（遅い） | `gemma4:rx5700`, `qwen3.6:rx5700` | Issue #10 |

Modelfile: [ollama/modelfiles/README.md](../../../ollama/modelfiles/README.md)

## ベンチマーク

### 一括比較（HF 候補 → Ollama タグ）

```powershell
$env:COMPARE_SET = 'default'   # 8GB では extended は時間がかかる
.\scripts\compare_models_ollama.ps1
```

### vLLM 互換メトリクス（p50 / tok/s）

```powershell
.\scripts\bench_ollama_openai.ps1 -HfId Qwen/Qwen2.5-1.5B-Instruct
python vllm/benchmark/scripts/bench_vllm.py --base-url http://127.0.0.1:11434/v1 --model qwen2.5:1.5b --skip-health
```

結果: `vllm/benchmark/results/` → [BENCHMARK_RESULTS.md](../../docs/BENCHMARK_RESULTS.md)

## CI（Windows self-hosted + Ollama）

1. この PC に **Actions runner** を登録（ラベル: `self-hosted`, `Windows`, `ollama`）
2. GitHub → **vLLM Ollama Benchmark** → `run_benchmark: true`

```powershell
gh workflow run vllm-ollama-benchmark.yaml -f compare_set=default -f run_benchmark=true
```

Runner 登録手順: [github-runners/README.md](../../../github-runners/README.md)

## GTX 1650（NVIDIA 4GB）

```powershell
.\scripts\setup-vllm-windows.ps1
.\scripts\run-vllm-docker.ps1   # 任意
```

| 項目 | 推奨値 |
|------|--------|
| モデル規模 | **≤ 3B**（0.5B が稳定） |
| vLLM `--max-model-len` | **2048** |
| vLLM `--max-num-seqs` | **8** |
| vLLM `--gpu-memory-utilization` | **0.75**（Docker/WDDM で空き VRAM が約 3.2GiB のため） |

## kind を使うタイミング

ローカル Windows で **GPU 付き推論に kind は不要**です。マニフェスト検証・Argo CD sync テスト時のみ [kind overlay](../kind/README.md) を使用してください。

本番同等 vLLM ベンチは [kubeadm overlay](../kubeadm/README.md) または Linux GPU ノード + Actions **vLLM Model Benchmark** です。

## WSL kubeadm へつなぐ（ROCm 不要）

Windows Ollama をクラスタ内 `ollama-external.vllm` として登録:

```powershell
.\scripts\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
```

```bash
./kubeadm/scripts/register-windows-ollama-external.sh --verify
```

CPU フォールバック: `kubectl apply -k vllm/overlays/kubeadm/cpu/`

## 関連ドキュメント

- [docs/LOCAL_GPU_SETUP_WINDOWS.md](../../../docs/LOCAL_GPU_SETUP_WINDOWS.md)
- [vllm/benchmark/ollama-model-map.json](../../benchmark/ollama-model-map.json)
- [vllm/docs/MODEL_SELECTION.md](../../docs/MODEL_SELECTION.md)
