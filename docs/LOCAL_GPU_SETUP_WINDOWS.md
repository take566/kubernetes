# ローカル GPU セットアップ（Windows + AMD）

Issue: GitHub `#11`（ローカル GPU ドライバー / ML スタック不足）

## 現状診断（このリポジトリの想定環境）

| 項目 | 状態 | 説明 |
|------|------|------|
| GPU ハードウェア | **AMD Radeon RX 5700** | 検出済み |
| Windows 表示ドライバ | **OK** | Adrenalin 32.x |
| `nvidia-smi` / `rocm-smi` | **なし** | Windows には同梱されない（正常） |
| WSL2 Ubuntu 24.04 | **あり** | `/dev/dxg` あり → GPU パススルー可能 |
| Docker Desktop | **要起動** | daemon 停止時は kind/k8s 不可 |
| Kubernetes クラスタ | **未接続** | ベンチマーク未実施の直接原因 |

**重要:** RX 5700（RDNA1 / **gfx1010**）は AMD ROCm の**公式サポート外**です。vLLM + ROCm は Linux 上でコミュニティ手順（`HSA_OVERRIDE_GFX_VERSION` 等）が必要です。

## 目的別ルート

```
┌─────────────────────────────────────────────────────────────┐
│ 目的 A: モデル品質を手軽に比較（今すぐ）                      │
│   → Ollama (Windows) / WSL llama.cpp                         │
├─────────────────────────────────────────────────────────────┤
│ 目的 B: 本リポジトリの vLLM ベンチ（compare_models.sh）      │
│   → Linux + ROCm + K8s GPU ノード（WSL または別 Linux）       │
├─────────────────────────────────────────────────────────────┤
│ 目的 C: CI ベンチ（推奨・安定）                              │
│   → self-hosted runner + kubeadm GPU worker                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 手順 1: プリフライト（毎回）

```powershell
.\scripts\detect-gpu.ps1
```

---

## 手順 2: Docker Desktop を有効化（kind / WSL 共通）

1. **Docker Desktop** を起動
2. Settings → **Resources → WSL integration** → `Ubuntu-24.04` を ON
3. 確認:

```powershell
docker info
wsl -d Ubuntu-24.04 -- docker info
```

> kind クラスタは GPU を渡しません（マニフェスト検証用）。GPU ベンチには手順 4 以降が必要です。

---

## 手順 3: クイック比較 — Ollama（Windows、GPU 利用可）

vLLM パイプライン構築前にモデル候補を試す場合:

```powershell
# https://ollama.com からインストール後
ollama pull qwen2.5:1.5b
ollama pull qwen2.5:0.5b
ollama run qwen2.5:1.5b "Kubernetes の GPU スケジューリングについて短く説明して"
```

LFM / Qwen3.6 / Gemma4 は Ollama カタログの有無を `ollama search` で確認してください。結果は [vllm/docs/BENCHMARK_RESULTS.md](../vllm/docs/BENCHMARK_RESULTS.md) に手動記録可能です。

---

## 手順 4: WSL2 で ROCm 準備（RX 5700 / gfx1010）

### 4.1 WSL 内プリフライト

```powershell
wsl -d Ubuntu-24.04 -- bash -lc "cd /mnt/d/work/kubernetes && ./scripts/setup-wsl-gpu-preflight.sh"
```

### 4.2 ROCm インストール（Ubuntu 24.04 on WSL）

AMD 公式手順に従い ROCm をインストールします。

- [ROCm install Ubuntu](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html)
- RX 5700 は非公式のため以下を常に設定:

```bash
export HSA_OVERRIDE_GFX_VERSION=10.3.0
export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True
```

### 4.3 gfx1010 向け PyTorch（コミュニティ）

公式 wheel は gfx1010 で動かない場合があります。

- [PyTorch-ROCm-gfx1010-Debian13](https://github.com/Efenstor/PyTorch-ROCm-gfx1010-Debian13)（Ubuntu 24.04 でも参考になる）

### 4.4 ローカル vLLM スモーク（K8s 外）

```bash
pip install vllm  # または rocm 対応ビルド
export HSA_OVERRIDE_GFX_VERSION=10.3.0
vllm serve Qwen/Qwen2.5-1.5B-Instruct --host 0.0.0.0 --port 8000 --max-model-len 4096
```

成功したら `vllm/benchmark/scripts/bench_vllm.py` を `--base-url http://localhost:8000` で実行できます。

---

## 手順 5: Kubernetes + vLLM ベンチ（本番同等）

### オプション A — WSL 上の kind（GPU なし検証のみ）

```bash
./kind/scripts/create-cluster.sh
./scripts/validate.sh
```

### オプション B — Linux GPU ワーカー + kubeadm（推奨）

1. 別 Linux マシンまたは WSL ではなく **ネイティブ Linux** で [kubeadm/README.md](../kubeadm/README.md) を実行
2. [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md) で Device Plugin
3. `kubectl apply -k vllm/overlays/kubeadm/amd/`（RX 5700 は AMD overlay）
4. ベンチ:

```bash
COMPARE_SET=extended ./vllm/benchmark/scripts/compare_models.sh
```

### オプション C — GitHub Actions

Actions → **vLLM Model Benchmark** → `compare_set: extended`  
（要 `k8s-self-hosted` runner + クラスタ内 vLLM）

---

## RX 5700 固有の注意

| 項目 | 値 |
|------|-----|
| アーキテクチャ | gfx1010 (RDNA1) |
| VRAM | 8 GiB |
| 推奨モデルサイズ | **≤ 1.5B〜3B**（BF16）、大モデルは OOM |
| vLLM overlay | `vllm/overlays/kubeadm/amd/` |
| 環境変数 | `HSA_OVERRIDE_GFX_VERSION=10.3.0`（Deployment に既にコメントあり） |

Qwen3.6-35B-A3B / Gemma4-E4B は 8 GiB では**実測失敗が想定内**です。Issue #10 のマトリクス参照。

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| `nvidia-smi` not found（AMD GPU） | 正常。NVIDIA ツールは不要 |
| Docker daemon not running | Docker Desktop を起動 |
| WSL に `docker` なし | Docker Desktop → WSL integration を有効化 |
| `kubectl` cluster 接続不可 | kind 作成 or リモート kubeconfig 設定 |
| ROCm `rocminfo` で GPU なし | WSL に ROCm 未インストール、または gfx1010 非対応 |
| vLLM Pod Pending | `amd.com/gpu` リソース不足 → Device Plugin 確認 |

---

## 関連ドキュメント

- [vllm/docs/MODEL_SELECTION.md](../vllm/docs/MODEL_SELECTION.md)
- [vllm/docs/MODEL_CANDIDATES_EXTENDED.md](../vllm/docs/MODEL_CANDIDATES_EXTENDED.md)
- [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)
