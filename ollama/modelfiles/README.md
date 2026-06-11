# Ollama Modelfiles（Windows ローカル GPU）

カスタムタグで `num_ctx` / `temperature` を固定し、VRAM 向けにチューニングします。

## RX 5700 8GB（AMD — 主経路）

```powershell
.\scripts\setup-ollama-rx5700.ps1
```

| Modelfile | タグ | ベース |
|-----------|------|--------|
| `qwen2.5-0.5b-rx5700.Modelfile` | `qwen2.5:0.5b-rx5700` | `qwen2.5:0.5b` |
| `qwen2.5-1.5b-rx5700.Modelfile` | `qwen2.5:1.5b-rx5700` | `qwen2.5:1.5b` |
| `lfm2-1.2b-rx5700.Modelfile` | `sam860/LFM2:1.2b-rx5700` | `sam860/LFM2:1.2b` |

手動作成:

```powershell
ollama create qwen2.5:1.5b-rx5700 -f ollama/modelfiles/qwen2.5-1.5b-rx5700.Modelfile
```

---

## GTX 1650 4GB（NVIDIA）

Windows ローカル（NVIDIA GTX 1650 4GB）向けに、ベースモデルへコンテキスト長・温度などを上書きしたカスタムタグ `:gtx1650` を作るためのテンプレートです。

## 前提

- [Ollama](https://ollama.com) がインストール済みで、デーモンが `http://127.0.0.1:11434` で応答すること
- ベースモデル（例: `phi4-mini`）を先に pull しておくこと

```powershell
ollama pull phi4-mini
```

## Modelfile から作成

リポジトリルート（`C:\work\kubernetes`）で実行:

```powershell
ollama create phi4-mini:gtx1650 -f ollama/modelfiles/phi4-mini-gtx1650.Modelfile
```

確認:

```powershell
ollama list
ollama run phi4-mini:gtx1650 "Kubernetes の Pod とは？ 1文で。"
```

## 他モデルへの展開

同じパターンで `:gtx1650` タグを追加できます。4GB VRAM では **小〜中規模モデル** と **num_ctx ≤ 4096** を目安にしてください。

| カスタムタグ | ベース例 | 用途 |
|-------------|---------|------|
| `phi4-mini:gtx1650` | `phi4-mini` | 汎用・軽量 |
| `granite-code:gtx1650` | `granite-code` 系 | コード補完 |
| `hermes3:gtx1650-tools` | `hermes3` 系 | ツール呼び出し |
| `gemma4:gtx1650` | `gemma4` 系 | 軽量汎用 |

Modelfile の雛形:

```dockerfile
FROM <ベースモデル名>
PARAMETER num_ctx 4096
PARAMETER temperature 0.5
```

```powershell
ollama create <名前>:gtx1650 -f ollama/modelfiles/<ファイル名>.Modelfile
```

## 一括セットアップ

```powershell
.\scripts\setup-vllm-windows.ps1
```

`phi4-mini:gtx1650` が未作成なら Modelfile から自動作成し、Ollama API スモークテストを実行します。

## 関連

- [docs/LOCAL_GPU_SETUP_WINDOWS.md](../../docs/LOCAL_GPU_SETUP_WINDOWS.md)
- [vllm/overlays/windows-local/README.md](../../vllm/overlays/windows-local/README.md)
