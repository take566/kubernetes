# ローカル GPU セットアップ（Windows + NVIDIA GTX 1650）

Issue: GitHub `#11`（ローカル GPU ドライバー / ML スタック不足）

## 現状診断（このリポジトリの想定環境）

| 項目 | 状態 | 説明 |
|------|------|------|
| GPU ハードウェア | **NVIDIA GeForce GTX 1650** | 4 GiB VRAM |
| Windows 表示ドライバ / CUDA | **OK** | `nvidia-smi` で確認 |
| Ollama | **推奨・主経路** | Windows ネイティブで CUDA 利用可 |
| Docker Desktop | **要起動** | vLLM コンテナ・WSL 連携用 |
| Kubernetes クラスタ | **未接続でも可** | ローカル推論は Ollama / Docker vLLM で完結 |
| kind | **任意（CI 検証のみ）** | GPU 非対応 |

**重要:** GTX 1650 4GB は VRAM が限られるため、**0.5B〜3B クラスの小モデル**を前提にします。7B 以上は OOM が想定内です。

## 目的別ルート

```
┌─────────────────────────────────────────────────────────────┐
│ 目的 A: モデル品質を手軽に比較（今すぐ・推奨）                │
│   → Ollama (Windows) + :gtx1650 カスタムタグ                 │
├─────────────────────────────────────────────────────────────┤
│ 目的 B: vLLM OpenAI API 互換の検証                           │
│   → Docker vLLM（Qwen2.5-0.5B、低メモリ設定）                │
├─────────────────────────────────────────────────────────────┤
│ 目的 C: 本リポジトリの K8s ベンチ（compare_models.sh）       │
│   → Linux GPU ワーカー + kubeadm（または Actions）           │
├─────────────────────────────────────────────────────────────┤
│ 目的 D: CI / マニフェスト検証のみ                            │
│   → kind（GPU なし）— ローカル Windows では必須ではない       │
└─────────────────────────────────────────────────────────────┘
```

Windows ローカル開発の全体像は [vllm/overlays/windows-local/README.md](../vllm/overlays/windows-local/README.md) を参照してください。

---

## 手順 1: プリフライト（毎回）

```powershell
.\scripts\detect-gpu.ps1
```

`nvidia-smi` が OK、`docker` が OK であることを確認します。`kind` / `kubectl` クラスタ未接続はローカル推論には影響しません。

---

## 手順 2: 一括セットアップ（推奨）

```powershell
.\scripts\setup-vllm-windows.ps1
```

このスクリプトは次を実行します:

1. `detect-gpu.ps1`
2. Ollama API（`http://127.0.0.1:11434`）の疎通確認
3. `qwen2.5:0.5b` の pull（未所持時）
4. Modelfile から `phi4-mini:gtx1650` の作成（未所持時）
5. Ollama API スモークテスト
6. （任意）Docker vLLM コンテナ起動

Ollama のみで十分な場合:

```powershell
.\scripts\setup-vllm-windows.ps1 -SkipVllmDocker
```

---

## 手順 3: Ollama — GTX 1650 向けモデル

### 3.1 ベースモデルとカスタムタグ

既にローカルにある例:

| タグ | 用途 |
|------|------|
| `phi4-mini:gtx1650` | 汎用（num_ctx 4096） |
| `granite-code:gtx1650` | コード |
| `hermes3:gtx1650-tools` | ツール呼び出し |
| `gemma4:gtx1650` | 軽量汎用 |

Modelfile からの作成手順: [ollama/modelfiles/README.md](../ollama/modelfiles/README.md)

```powershell
ollama pull phi4-mini
ollama create phi4-mini:gtx1650 -f ollama/modelfiles/phi4-mini-gtx1650.Modelfile
ollama run phi4-mini:gtx1650 "Kubernetes の GPU スケジューリングについて短く説明して"
```

### 3.2 ベンチマーク記録

```powershell
.\scripts\ollama-bench.ps1 -Models qwen2.5:0.5b,phi4-mini:gtx1650 -Prompt "Say hello in one sentence."
```

結果は `vllm/benchmark/results/` に JSON 出力されます。[vllm/docs/BENCHMARK_RESULTS.md](../vllm/docs/BENCHMARK_RESULTS.md) に手動追記可能です。

### 3.3 `compare_models_ollama.ps1`（K8s なし・候補一括比較）

vLLM クラスタが未接続でも、HuggingFace 候補を Ollama タグにマップして一括ベンチできます（[vllm/benchmark/ollama-model-map.json](../vllm/benchmark/ollama-model-map.json)）。

**GTX 1650 4GB では `COMPARE_SET=extended` は非推奨**（Gemma4 / Qwen3.6 は OOM 想定）。まず default で小モデルのみ:

```powershell
$env:COMPARE_SET = 'default'
.\scripts\compare_models_ollama.ps1

# 個別指定（0.5B〜1.5B のみ）
.\scripts\compare_models_ollama.ps1 -Models 'Qwen/Qwen2.5-0.5B-Instruct','Qwen/Qwen2.5-1.5B-Instruct'
```

**出力:** `vllm/benchmark/results/ollama-compare-<timestamp>.json`

**CI:** GitHub Actions → **vLLM Ollama Benchmark**（`run_benchmark: false` でマップ検証のみ）。GPU 実測は self-hosted Windows runner（ラベル `ollama`）で `run_benchmark: true`。

---

## 手順 4: Docker vLLM（副経路）

GTX 1650 向けにメモリを抑えた設定で起動:

```powershell
.\scripts\run-vllm-docker.ps1
```

| 設定 | 値 |
|------|-----|
| イメージ | `vllm/vllm-openai:latest` |
| モデル | `Qwen/Qwen2.5-0.5B-Instruct` |
| `--gpu-memory-utilization` | 0.85 |
| `--max-model-len` | 2048 |
| `--max-num-seqs` | 32 |
| ポート | 8000 |

確認:

```powershell
curl http://127.0.0.1:8000/v1/models
```

ベンチ:

```bash
python vllm/benchmark/scripts/bench_vllm.py --base-url http://127.0.0.1:8000
```

**前提:** Docker Desktop で NVIDIA GPU サポート（Container Toolkit）が有効であること。

---

## 手順 5: Docker Desktop / WSL（kind 利用時のみ）

kind や WSL 内 docker を使う場合:

1. **Docker Desktop** を起動
2. Settings → **Resources → WSL integration** → `Ubuntu-24.04` を ON
3. 確認:

```powershell
docker info
wsl -d Ubuntu-24.04 -- docker info
```

> kind クラスタは GPU を渡しません（マニフェスト検証用）。GPU ベンチには手順 6 を使用してください。

---

## 手順 6: Kubernetes + vLLM ベンチ（本番同等）

### オプション A — kind（GPU なし検証のみ・任意）

```bash
./kind/scripts/create-cluster.sh
./scripts/validate.sh
kubectl apply -k vllm/overlays/kind/
```

### オプション B — Linux GPU ワーカー + kubeadm（推奨）

1. ネイティブ Linux で [kubeadm/README.md](../kubeadm/README.md) を実行
2. [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md) で NVIDIA Device Plugin
3. `kubectl apply -k vllm/overlays/kubeadm/`
4. ベンチ:

```bash
COMPARE_SET=extended ./vllm/benchmark/scripts/compare_models.sh
```

### オプション C — GitHub Actions

Actions → **vLLM Model Benchmark** → `compare_set: extended`  
（要 `k8s-self-hosted` runner + クラスタ内 vLLM）

---

## GTX 1650 4GB 固有の注意

| 項目 | 値 |
|------|-----|
| VRAM | **4 GiB** |
| 推奨モデルサイズ | **≤ 3B**（0.5B〜1.5B が安定） |
| Ollama `num_ctx` | **2048〜4096** |
| vLLM overlay（K8s） | `vllm/overlays/kubeadm/`（NVIDIA） |
| Windows ローカル | `vllm/overlays/windows-local/`（Ollama 主・Docker 副） |

7B 以上・大コンテキストは 4GB では**実測失敗が想定内**です。Issue #10 のマトリクス参照。

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| `nvidia-smi` not found | NVIDIA ドライバを再インストール（Game Ready / Studio） |
| Ollama に接続できない | Ollama アプリを起動、`http://127.0.0.1:11434/api/tags` を確認 |
| Ollama が CPU のみ | タスクマネージャで GPU 使用率を確認。ドライバ更新後に Ollama 再起動 |
| Docker vLLM OOM | より小さいモデル（0.5B）、`--max-model-len 1024` に下げる |
| `docker run --gpus all` 失敗 | Docker Desktop → Settings → Resources で GPU を有効化 |
| Docker daemon not running | Docker Desktop を起動 |
| `kubectl` cluster 接続不可 | ローカル推論には不要。kind 作成 or リモート kubeconfig |
| vLLM Pod Pending（K8s） | `nvidia.com/gpu` リソース不足 → Device Plugin 確認 |

---

## 関連ドキュメント

- [vllm/overlays/windows-local/README.md](../vllm/overlays/windows-local/README.md)
- [ollama/modelfiles/README.md](../ollama/modelfiles/README.md)
- [vllm/docs/MODEL_SELECTION.md](../vllm/docs/MODEL_SELECTION.md)
- [vllm/docs/MODEL_CANDIDATES_EXTENDED.md](../vllm/docs/MODEL_CANDIDATES_EXTENDED.md)
- [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)
