# 拡張モデル候補（LFM / Qwen3.6 / Gemma4）

Issue [#10](https://github.com/take566/kubernetes/issues/10) で追加入りした次世代モデルの検証マトリクスです。

## 検証対象

| ファミリ | モデル ID | 推定 VRAM | 1 GPU 適合 | 備考 |
|---------|-----------|-----------|------------|------|
| **LFM** | `LiquidAI/LFM2.5-350M` | ~1 GiB | ◎ | オンデバイス向け、日本語対応 |
| **LFM** | `LiquidAI/LFM2.5-1.2B-Instruct` | ~2.5 GiB | ◎ | vLLM 0.14+、エージェント向け |
| **Qwen3.6** | `Qwen/Qwen3.6-35B-A3B` | ~22 GiB (BF16) | △ | MoE・active ~3B、**24GB+ GPU 推奨** |
| **Qwen3.6** | `Qwen/Qwen3.6-27B` | ~54 GiB | ✗ |  dense 27B、TP≥2 または 80GB GPU |
| **Gemma4** | `google/gemma-4-E2B-it` | ~6 GiB (text-only) | △ | 要 `--limit-mm-per-prompt`，recipes は 24GB+ |
| **Gemma4** | `google/gemma-4-E4B-it` | ~10 GiB (text-only) | △ | 同上、品質↑ |
| **Gemma4** | `google/gemma-4-12B-it` | ~24 GiB+ | ✗ | 40GB+ GPU 推奨 |

### クラスタ前提との整合

現行 Deployment: GPU 1 枚、Pod memory 8–16 GiB。

- **即ベンチ可能（現行クラスタ向け）:** LFM2.5 系、既存 Qwen2.5 系
- **GPU アップグレード後に再検証:** Qwen3.6-35B-A3B、Gemma4 E2B/E4B
- **マルチ GPU overlay 追加後:** Qwen3.6-27B、Gemma4-12B

## モデル別 vLLM 設定の要点

### LFM2.5

- vLLM **0.14+**（Liquid 公式ドキュメント）
- 標準 `vllm/vllm-openai:latest` で可（要バージョン確認）
- 日本語・中国語・韓国語など多言語

### Qwen3.6

- デフォルトで **thinking モード** — レイテンシ計測時は無効化推奨:

```yaml
--default-chat-template-kwargs '{"enable_thinking": false}'
```

- `Qwen3.6-35B-A3B` は Image-Text-to-Text（マルチモーダル）。テキストのみ API でも動作するが weights サイズは MoE 全体
- ベンチ API では `chat_template_kwargs.enable_thinking: false` も併用可（[Qwen3.6 README](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)）

### Gemma4

- マルチモーダルアーキテクチャ — **テキスト推論のみ**の場合は必須:

```yaml
--limit-mm-per-prompt '{"image": 0, "audio": 0}'
```

- 一部環境では `vllm/vllm-openai:gemma4-cu130` 等の専用イメージが必要
- `google/gemma-4-*` は HF ゲートあり（要 `HF_TOKEN`）

## ベンチマーク手順

```bash
# 拡張候補のみ（LFM + Qwen3.6 + Gemma4）
MODELS="LiquidAI/LFM2.5-1.2B-Instruct Qwen/Qwen3.6-35B-A3B google/gemma-4-E4B-it" \
  ./vllm/benchmark/scripts/compare_models.sh

# プロファイル JSON から全拡張候補
COMPARE_PROFILES=vllm/benchmark/model-profiles.json \
  ./vllm/benchmark/scripts/compare_models.sh
```

プロファイル定義: [model-profiles.json](../benchmark/model-profiles.json)

## 選定フロー（PDCA）

1. **Plan** — 本マトリクスで VRAM 適合を確認
2. **Do** — `compare_models.sh` または CI workflow で JSON 取得
3. **Check** — p50/p99/tok/s を [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) に記録
4. **Act** — kubeadm `model-patch.yaml` の採用モデルを更新（現行は Qwen2.5-1.5B 維持、実測上位で切替）

## 参考リンク

- [Liquid AI vLLM docs](https://docs.liquid.ai/deployment/gpu-inference/vllm)
- [Qwen3.6 collection](https://huggingface.co/collections/Qwen/qwen36)
- [Gemma 4 vLLM recipes](https://docs.vllm.ai/projects/recipes/en/latest/Google/Gemma4.html)
- [Hugging Face Gemma4 blog](https://huggingface.co/blog/gemma4)
