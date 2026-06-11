# Windows Ollama → Kubernetes 外部エンドポイント

WSL kubeadm クラスタから **ROCm なし**で AMD GPU 推論（Windows ネイティブ Ollama）を使うための headless Service。

## デプロイ

```powershell
# Windows
.\scripts\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
.\scripts\restart-ollama-wsl-bridge.ps1
```

```bash
export KUBECONFIG=~/.kube/config-kubeadm-wsl
./kubeadm/scripts/register-windows-ollama-external.sh
```

## クラスタ内 URL

| API | URL |
|-----|-----|
| Ollama native | `http://ollama-external.vllm:11434/api/generate` |
| OpenAI 互換 | `http://ollama-external.vllm:11434/v1/chat/completions` |

## 制約

- Endpoints の IP は WSL の default gateway（Windows ホスト）。再起動後に変わる場合はスクリプトを再実行。
- Ollama は既定で `127.0.0.1` のみ — `OLLAMA_HOST=0.0.0.0:11434` 必須。
- GPU は Windows ドライバ / Ollama バックエンドに依存（ROCm・`/dev/kfd` 不要）。
