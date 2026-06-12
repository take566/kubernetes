# ローカル GPU セットアップ（Windows）

Issue: GitHub `#11`（ローカル GPU ドライバー / ML スタック不足）

## プロファイル早見表

| GPU | VRAM | 主経路（案 A） | セットアップ |
|-----|------|----------------|-------------|
| **AMD RX 5700** | 8 GiB | **Ollama (Windows)** | `.\scripts\setup-ollama-rx5700.ps1` |
| NVIDIA GTX 1650 | 4 GiB | Ollama + 任意 Docker vLLM | `.\scripts\setup-vllm-windows.ps1` |

RX 5700 では **WSL ROCm は公式非対応**のため、GPU 推論は Ollama を主経路としてください。詳細: [vllm/overlays/windows-local/README.md](../vllm/overlays/windows-local/README.md)

### WSL kubeadm クラスタへ GPU 推論をつなぐ（ROCm 不要）

| 経路 | GPU | 用途 |
|------|-----|------|
| **A: Windows Ollama → K8s 外部 Service** | AMD RX 5700（Vulkan バックエンド/Windows ドライバ） | **推奨** — クラスタ内 Pod から `ollama-external.vllm` で呼び出し |
| **B: クラスタ内 CPU vLLM** | なし | マニフェスト検証・低速スモーク — `vllm/overlays/kubeadm/cpu/` |

**経路 A（推奨）**

```powershell
.\scripts\setup-ollama-rx5700.ps1          # モデル準備（初回）
.\scripts\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
# Ollama 再起動後: netstat -an | findstr 11434  → 0.0.0.0:11434 LISTENING
```

```bash
export KUBECONFIG=~/.kube/config-kubeadm-wsl
./kubeadm/scripts/register-windows-ollama-external.sh --verify
```

| 項目 | 値 |
|------|-----|
| クラスタ内 URL | `http://ollama-external.vllm.svc.cluster.local:11434` |
| OpenAI 互換 | `.../v1/chat/completions` |
| Windows ホスト IP | WSL の default gateway（`ip route \| awk '/default/ {print $3}'`） |
| 前提 | `OLLAMA_HOST=0.0.0.0:11434`、ファイアウォールで TCP 11434 |

**経路 B（CPU フォールバック）**

```bash
kubectl kustomize vllm/overlays/kubeadm/cpu --load-restrictor LoadRestrictionsNone | kubectl apply -f -
kubectl -n vllm wait --for=condition=available deployment/vllm --timeout=600s
curl http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'):30800/v1/models
```

> llama.cpp Vulkan は Windows 単体 HTTP サーバとして可能だが、本リポジトリでは Ollama の方がモデル管理・OpenAI 互換・既存ベンチと統合しやすいため **経路 A を優先**。

---

## 現状診断（NVIDIA GTX 1650 例）

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


---

## CUDA Toolkit / cuDNN / Docker GPU（NVIDIA）

ローカルで **ネイティブビルド** や **nvcc** が必要なとき、または環境の棚卸しには次を実行します。

```powershell
.\scripts\install-nvidia-toolkit-windows.ps1
```

| コンポーネント | 役割 | この PC での目安 |
|----------------|------|------------------|
| NVIDIA ドライバ | `nvidia-smi`、CUDA ランタイム | 595.x、CUDA Version 13.2 表示 |
| CUDA Toolkit | `nvcc`、開発用ヘッダ／ライブラリ | `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.x` |
| cuDNN | 深層学習向け畳み込み（**任意**） | ZIP 手動配置（下記） |
| Docker `nvidia` runtime | `docker run --gpus all` | Docker Desktop で GPU 有効化 |

### インストール手順（自動＋手動）

1. **ドライバ** — [NVIDIA ドライバ](https://www.nvidia.com/Download/index.aspx)。`nvidia-smi` が動けば OK。
2. **CUDA Toolkit** — [CUDA Downloads](https://developer.nvidia.com/cuda-downloads)（Windows 11 x86_64）。**ドライバの最大 CUDA ランタイム以下**の Toolkit を選ぶ。確認: `nvcc --version`。
3. **cuDNN（任意）** — [cuDNN](https://developer.nvidia.com/cudnn)（要アカウント）。`bin` / `lib` / `include` を `%CUDA_PATH%` へコピー。
4. **Docker GPU** — Docker Desktop → Settings → Resources で NVIDIA GPU を有効化。

```powershell
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi
```

`winget` 試行（管理者・対話が必要な場合あり）:

```powershell
.\scripts\install-nvidia-toolkit-windows.ps1 -InstallCudaWinget
```

### WSL 上の CUDA

`wsl -d <distro> -- nvidia-smi` が失敗する場合は **Docker `--gpus`** または **Windows ネイティブ Ollama** を主経路にしてください。

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
| `--gpu-memory-utilization` | 0.75（GTX 1650 + Docker/WDDM） |
| `--max-model-len` | 2048 |
| `--max-num-seqs` | 8 |
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

### 5.1 WSL 前提パッケージ（任意）

`validate.sh` の helm チェックや preflight の `lspci` 用。**sudo パスワード必須**（WSL 内で対話実行）:

```powershell
.\scripts\install-wsl-rocm.ps1 -PrerequisitesOnly
# 表示ブロックを WSL に貼り付け → sudo ./scripts/install-wsl-prerequisites.sh
```

---

## 付録 A: WSL2 + AMD ROCm（RX 5700 / gfx1010）

> **sudo パスワード必須:** ROCm と WSL 前提パッケージ（`helm` / `pciutils` / `wget`）のインストールは **WSL 内で対話的に `sudo` を実行**する必要があります。PowerShell からはパスワードを渡せないため、下記の **インタラクティブ用スクリプト** または **Windows Terminal 起動ラッパー** を使ってください。

**重要:** RX 5700（RDNA1 / **gfx1010**）は AMD ROCm の**公式サポート外**です。vLLM + ROCm は Linux 上でコミュニティ手順（`HSA_OVERRIDE_GFX_VERSION` 等）が必要です。

| スクリプト | 用途 |
|------------|------|
| `scripts/install-wsl-rocm.ps1` | Windows から preflight → コマンド表示 → WT/WSL ターミナル起動 |
| `scripts/install-wsl-rocm-interactive.sh` | WSL に貼り付ける exact コマンドを表示 |
| `scripts/install-wsl-prerequisites.sh` | `helm`, `pciutils`, `wget`（**sudo 必須**） |
| `scripts/install-wsl-rocm.sh` | ROCm 7.2 本体（**sudo 必須**、`--check` でドライラン） |

### A.1 推奨フロー（Windows → WSL 対話インストール）

```powershell
# 1) preflight + 貼り付け用コマンド表示 + Windows Terminal で WSL を開く
.\scripts\install-wsl-rocm.ps1

# WSL ターミナルで sudo パスワードを入力してインストール完了後:

# 2) WSL GPU スタックを再読み込み（推奨）
wsl --shutdown

# 3) 再 preflight
.\scripts\install-wsl-rocm.ps1 -PreflightOnly
```

**ターミナルを自動で開かない**場合:

```powershell
.\scripts\install-wsl-rocm.ps1 -SkipTerminal
```

### A.2 WSL 内プリフライト（手動）

```powershell
wsl -d Ubuntu-24.04 -- bash -lc "cd /mnt/d/work/kubernetes && ./scripts/setup-wsl-gpu-preflight.sh"
```

### A.3 ROCm インストール（Ubuntu 24.04 on WSL）

AMD 公式 **ROCm 7.2 WSL** 手順（[Install Radeon software for WSL with ROCm](https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html)）:

**前提:** Windows 側に **AMD Software: Adrenalin Edition 26.1.1 for WSL2** 以降。WSL には **Ubuntu 24.04**。

**コピペ用コマンド（sudo パスワードは WSL 側で入力）:**

```powershell
wsl -d Ubuntu-24.04 -- bash -lc "cd /mnt/d/work/kubernetes && ./scripts/install-wsl-rocm-interactive.sh"
```

**ドライラン（変更なし・sudo 不要）:**

```powershell
wsl -d Ubuntu-24.04 -- bash -lc "cd /mnt/d/work/kubernetes && ./scripts/install-wsl-rocm.sh --check"
```

**WSL 内インストール（要 sudo — PowerShell からは不可）:**

```bash
sudo ./scripts/install-wsl-prerequisites.sh   # optional: helm, lspci, wget
sudo ./scripts/install-wsl-rocm.sh
```

**確認:**

```bash
amd-smi version || amd-smi static || true   # preferred on ROCm 7+
rocminfo | head -40
rocm-smi || true   # legacy fallback
```

**ROCm インストール後（Windows）:**

```powershell
wsl --shutdown
.\scripts\install-wsl-rocm.ps1 -PreflightOnly
```

> **Note:** `--no-dkms` は WSL2 でカーネルモジュールをビルドしないために必須。

RX 5700（gfx1010）向け環境変数:

```bash
export HSA_OVERRIDE_GFX_VERSION=10.3.0
export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True
```

K8s AMD overlay: `vllm/overlays/kubeadm/amd/`

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
| Ollama が CPU のみ | `scripts/update-adrenalin-gpu.ps1` で診断。RX 5700 (RDNA1) は `lib\ollama\vulkan\` 欠落（自己アップデート破損）が典型原因 — 公式 OllamaSetup.exe を再実行して修復。`AMD driver is too old` ログは RDNA1 では恒常表示で無害（[docs/RX5700_WSL_GPU.md](RX5700_WSL_GPU.md) 参照） |
| Docker vLLM OOM | より小さいモデル（0.5B）、`--max-model-len 1024` に下げる |
| `docker run --gpus all` 失敗 | Docker Desktop → Settings → Resources で GPU を有効化 |
| Docker daemon not running | Docker Desktop を起動 |
| WSL に `docker` なし | Docker Desktop → WSL integration を有効化 |
| `kubectl` cluster 接続不可 | ローカル推論には不要。kind 作成 or リモート kubeconfig |
| vLLM Pod Pending（K8s） | `nvidia.com/gpu` リソース不足 → Device Plugin 確認 |
| ROCm `rocminfo` で GPU なし（AMD/WSL） | 付録 A の ROCm 未インストール、または gfx1010 非対応 |
| `No WDDM adapters found` / `hsa_init Failed`（WSL） | **RX 5700 は ROCm 7.2 WSL 公式非対応**（RDNA3+ のみ）。WSL ROCm は諦め、**Ollama (Windows) + `register-windows-ollama-external.sh`** または **ネイティブ Linux** を使用 |
| WSL から `http://<gateway>:11434` タイムアウト | `configure-ollama-wsl-bridge.ps1 -ConfigureFirewall`、Ollama 再起動、`OLLAMA_HOST=0.0.0.0:11434` 確認。WSL で `http_proxy` がある場合は `curl --noproxy '*'` |
| Squid プロキシエラー（WSL curl） | `http_proxy` が RFC1918 を横取り — 登録スクリプトは `--noproxy` 使用。シェルで `unset http_proxy https_proxy` |
| `amdgpu not found in modules`（WSL） | WSL では通常の `amdgpu` モジュールは使わない。上記と合わせて GPU 非対応を疑う |
| `sudo` が PowerShell から失敗 | 正常 — WSL ターミナルで `install-wsl-rocm-interactive.sh` のブロックを実行 |
| `lspci` / `helm` missing in WSL preflight | WSL 内で `sudo ./scripts/install-wsl-prerequisites.sh` |

---

## 関連ドキュメント

- [vllm/overlays/windows-local/README.md](../vllm/overlays/windows-local/README.md)
- [ollama/modelfiles/README.md](../ollama/modelfiles/README.md)
- [vllm/docs/MODEL_SELECTION.md](../vllm/docs/MODEL_SELECTION.md)
- [vllm/docs/MODEL_CANDIDATES_EXTENDED.md](../vllm/docs/MODEL_CANDIDATES_EXTENDED.md)
- [kubeadm/scripts/06-gpu-node-setup.md](../kubeadm/scripts/06-gpu-node-setup.md)

## WSL2 kubeadm + vLLM

WSL ��� Kubernetes (kubeadm) ���� GPU vLLM �𓮂����菇�� [WSL_KUBEADM_GPU.md](WSL_KUBEADM_GPU.md) ���Q�Ƃ��Ă��������B
