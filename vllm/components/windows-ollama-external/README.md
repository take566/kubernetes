# Windows Ollama → Kubernetes 外部エンドポイント

WSL kubeadm / kind クラスタから **ROCm なし**で AMD GPU 推論（Windows ネイティブ Ollama）を使うための headless Service。

## デプロイ

```powershell
# Windows（共通）
.\scripts\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
.\scripts\restart-ollama-wsl-bridge.ps1
```

### kubeadm

```bash
export KUBECONFIG=~/.kube/config-kubeadm-wsl
./kubeadm/scripts/register-windows-ollama-external.sh
```

### kind

Git Bash / WSL どちらからでも可:

```bash
./kubeadm/scripts/register-windows-ollama-external.sh --cluster kind --verify
```

overlay は `vllm/overlays/kind/windows-ollama-external/`。

## クラスタ内 URL

| API | URL |
|-----|-----|
| Ollama native | `http://ollama-external.vllm:11434/api/generate` |
| OpenAI 互換 | `http://ollama-external.vllm:11434/v1/chat/completions` |

## 制約

- Endpoints の IP は WSL の default gateway（Windows ホスト）。再起動後に変わる場合はスクリプトを再実行。
- Ollama は既定で `127.0.0.1` のみ — `OLLAMA_HOST=0.0.0.0:11434` 必須。
- GPU は Windows ドライバ / Ollama バックエンドに依存（ROCm・`/dev/kfd` 不要）。
- kind ノード（Docker Desktop VM）からも WSL gateway IP で到達可能（`host.docker.internal` は IPv6 にしか解決されないため使用不可）。
- kind ノードには `http_proxy` が注入されており、proxy 経由だと **403**。クライアント Pod に `HTTP_PROXY` を設定する場合は `NO_PROXY=ollama-external.vllm,.svc,.svc.cluster.local` が必要。
- GPU 化は **Vulkan バックエンド**（Ollama フルインストールで `lib\ollama\vulkan\` が存在し `OLLAMA_VULKAN` が無効化されていないこと）が条件。RX 5700 (RDNA1) に Adrenalin build 31000+ / HIP7 は配布されないため**ドライバ更新は条件ではない**（build 21043 系が最新で正常）。Ollama 自己アップデートで vulkan ディレクトリが欠落し CPU フォールバックする既知問題あり — 修復は公式 OllamaSetup.exe 再実行。診断: `scripts/update-adrenalin-gpu.ps1`（`-OpenDownloadPage` / `-VerifyAfterUpdate`）。修復後はクラスタ側変更ゼロで GPU 化される。"AMD driver is too old" ログは RDNA1 では恒常表示で無害（Vulkan 経路に無関係）。詳細: [docs/RX5700_WSL_GPU.md](../../../docs/RX5700_WSL_GPU.md)。
