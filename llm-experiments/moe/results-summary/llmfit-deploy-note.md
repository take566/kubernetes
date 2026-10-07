# llmfit MoE サーベイ — deploy-note (2026-10-07)

- **ツール:** llmfit v1.1.16 (`x86_64-unknown-linux-gnu` tarball, sha256 `27fad93d…c6be7f1` を公開 `.sha256` と照合済み) → `~/.local/bin/llmfit`
- **ホスト:** deploy-note WSL Ubuntu 24.04, i7-12650H (WSL 8 vCPU), RAM 19.5 GB (WSL), GTX 1650 4 GB (CUDA)
- **実行:** `HOST_LABEL=deploy-note scripts/llmfit_survey.sh`（生 JSON は `results/llmfit-deploy-note-*.json`, gitignore 対象）
- **フラグ:** `--memory/--ram/--cpu-cores` は **グローバルフラグ** (`llmfit --memory=1G fit --json`)。サブコマンドの後ろに置くと clap が拒否する。`--force-runtime` は v1.1.16 に存在しないため、各行の `runtime` フィールドを jq で `llama.cpp` に絞った。
- **DB:** 9,872 モデル。MoE (`is_moe == true` かつ `fit_level != "Too Tight"`, runtime=llama.cpp) は vram0g 497 / vram1g 459 / vram4g 925 行。

| プロファイル | フラグ | 想定 |
|---|---|---|
| vram0g | `--memory=0G --ram=19G --cpu-cores=8` | CPU 推論（窓の外）。llmfit は 0G でも `CPU+GPU` と表示し GPU 帯域ルーフラインで見積もるので参考値 |
| vram1g | `--memory=1G --ram=19G --cpu-cores=8` | 本番 vLLM 稼働中の空き VRAM (~0.9 GB) |
| vram4g | `--memory=4G --ram=19G --cpu-cores=8` | vLLM 窓（GPU 全開放） |

## 選定と結果

上位はコミュニティの派生（量子化再配布・fine-tune）が占めるため、**公式ベンダー版 + Ollama で入手できる**ものから選んだ。RAM 制約: Windows 側 Ollama が使える空き RAM は実測 4.5–6 GB（WSL の vmmem が ~15 GB 保持）なので、モデル ≤ ~4.5 GB に限定。

| HF モデル | Ollama タグ | 総/活性 | vram0g fit / 予測 tok/s | vram1g fit / 予測 tok/s | vram4g fit / 予測 tok/s | 判定 |
|---|---|---|---|---|---|---|
| ibm-granite/granite-3.1-3b-a800m-instruct | `granite3.1-moe:3b` (Q4_K_M, 2.0 GB) | 3.3B / 0.8B | Good / 44.5 (Q8_0) | Marginal / 56.7 (MoE offload) | Perfect / 75.4 (Q6_K) | **計測済み** |
| ibm-granite/granite-4.0-h-tiny | `granite4:tiny-h` (Q4_K_M, 4.2 GB) | 6.9B / 1B | Good / 36.5 (Q8_0) | Good / 46.5 (MoE offload) | Marginal / 61.1 (Q2_K) | **計測済み** |
| ibm-granite/granite-3.0-1b-a400m-instruct | `granite3-moe:1b` (Q4_K_M, 0.8 GB) | 1.3B / 0.4B | Good / 91.7 | Good / 150.1 (GPU) | Perfect / 144.9 | **ロード失敗**（下記） |
| (granite-3.1-1b-a400m-instruct) | `granite3.1-moe:1b` (Q8_0, 1.4 GB) | 1.3B / 0.4B | — (llmfit DB は base 版のみ) | — | — | **ロード失敗**（下記） |
| LiquidAI/LFM2-8B-A1B | (`lfm2:8b-a1b` は Ollama に無い) | 8.3B / 1B | Good / 23.5 | Marginal / 29.9 | Too Tight | 未計測: llmfit の ollama_name が誤り、hf.co GGUF Q4 ~5 GB は RAM 余裕不足 |
| openai/gpt-oss-20b | `gpt-oss:20b` (13.8 GB) | 21B / 3.6B | Good / 18.8 | Good / 18.8 | Good / 14.4 | 未計測: 13 GB 上限超 + Windows 空き RAM 不足 |
| Qwen/Qwen3-30B-A3B-Instruct-2507 | `qwen3:30b-a3b` (~18 GB) | 30B / 3B | Too Tight | Too Tight | Good / 15.2 | 未計測: RAM 不足（llmfit は WSL 19 GB を前提にしており Windows 側 Ollama の空きを知らない） |

**ロード失敗:** Windows ネイティブ Ollama 0.35.1 (llama-server バックエンド) で granite **1B-A400M** 系 (`granite3-moe:1b` Q4_K_M, `granite3.1-moe:1b` Q8_0) は CPU 専用 (`num_gpu 0`) でも GPU でも `common_params_fit_impl` 中に `ggml-impl.h:330: fatal error` → `0xc0000409` で落ちる。同じ granitemoe の 3B-A800M は動くのでモデル形状依存の llama.cpp 側の問題とみられる。LoRA ベース (granite-3.1-1b-a400m-instruct) の評価は transformers (`eval_quality.py --hf-model`) で行う。

## 実測との比較（CPU, 窓の外）

| Ollama タグ | llmfit 予測 (vram0g / vram1g) | 実測 decode tok/s (単発 /api/generate) | 実測 tok/s (並列2, /v1) | p50 / p99 (ms, 64 tok) | QA 正答 |
|---|---|---|---|---|---|
| `granite3.1-moe:3b-cpu` | 44.5 / 56.7 | **45.9** | 45.4 | 1454 / 1496 | 27/30 (90.0%)、初回 25/30 |
| `granite4:tiny-h-cpu` | 36.5 / 46.5 | **25.5** | 24.4 | 2683 / 2787 | 29/30 (96.7%)、初回 29/30 |

llmfit の vram0g 予測は Q8_0 前提、実測は Q4_K_M。granite3.1-moe はほぼ予測どおり、granite4 (Mamba-2 ハイブリッド) は予測の 7 割にとどまった。

## 注意

- **GPU オフロードは窓の外では使わない:** Windows 側から見た GPU 空きは 3.2 GiB（WSL の vLLM 使用分が見えない、`torch.cuda.mem_get_info()` も同様に 3294 MiB と誤報）。nvidia-smi (WSL) の実値は 885 MiB 空き。Ollama 既定タグは GPU に載せに行くため、CPU 専用タグ (`<tag>-cpu`, `PARAMETER num_gpu 0`) を作って計測した。
