# vLLM × Windows ローカル開発

GTX 1650 4GB など **VRAM が限られた Windows マシン**向けのローカル開発パスです。K8s overlay（`kind` / `kubeadm`）とは別ルートとして扱います。

## 3 層の役割分担

```
┌──────────────────────────────────────────────────────────────┐
│ 層 1: Ollama（Windows ネイティブ）— 主経路                  │
│   GPU 推論・モデル比較・日常開発。HTTP API :11434             │
├──────────────────────────────────────────────────────────────┤
│ 層 2: Docker vLLM — 副経路（OpenAI 互換 API の検証）         │
│   Qwen2.5-0.5B 等の小モデル。:8000 /v1/*                      │
├──────────────────────────────────────────────────────────────┤
│ 層 3: kind + vllm/overlays/kind — CI / マニフェスト検証のみ   │
│   GPU 非対応。本番同等ベンチは kubeadm または Actions         │
└──────────────────────────────────────────────────────────────┘
```

| 経路 | GPU | 用途 |
|------|-----|------|
| Ollama (`phi4-mini:gtx1650` 等) | あり（CUDA） | **推奨** — 手軽な推論・ベンチ比較 |
| `scripts/run-vllm-docker.ps1` | あり（NVIDIA Container Toolkit） | vLLM パイプライン・`bench_vllm.py` 検証 |
| `vllm/overlays/kind/` | なし | Kustomize / Argo CD / CI の YAML 検証 |
| `vllm/overlays/kubeadm/` | あり（Linux クラスタ） | 本番・self-hosted runner ベンチ |

## クイックスタート

```powershell
.\scripts\detect-gpu.ps1
.\scripts\setup-vllm-windows.ps1
```

Ollama のみで十分な場合:

```powershell
.\scripts\setup-vllm-windows.ps1 -SkipVllmDocker
```

## GTX 1650 4GB の目安

| 項目 | 推奨値 |
|------|--------|
| モデル規模 | **≤ 3B**（0.5B〜1.5B が安定） |
| Ollama `num_ctx` | **2048〜4096** |
| vLLM `--max-model-len` | **2048** |
| vLLM `--gpu-memory-utilization` | **0.85** 前後 |

大規模モデル（7B+）は 4GB VRAM では OOM が想定内です。

## ベンチマーク連携

- Ollama: `.\scripts\ollama-bench.ps1 -Models qwen2.5:0.5b,phi4-mini:gtx1650 -Prompt "..."`  
  結果は `vllm/benchmark/results/` に JSON 出力
- vLLM Docker: `vllm/benchmark/scripts/bench_vllm.py --base-url http://127.0.0.1:8000`

## kind を使うタイミング

**ローカル Windows で kind は必須ではありません。** 次の場合のみ:

- `kubectl apply -k vllm/overlays/kind/` によるマニフェスト検証
- GitHub Actions 以外の CI で K8s リソースを dry-run 相当で確認

GPU 付きベンチは [kubeadm overlay](../kubeadm/README.md) または Actions **vLLM Model Benchmark** を使用してください。

## 関連ドキュメント

- [docs/LOCAL_GPU_SETUP_WINDOWS.md](../../../docs/LOCAL_GPU_SETUP_WINDOWS.md)
- [ollama/modelfiles/README.md](../../../ollama/modelfiles/README.md)
- [vllm/overlays/kind/README.md](../kind/README.md)
