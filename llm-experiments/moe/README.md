# MoE モデル選定・ベンチマーク・LoRA 実験 (#90)

[llmfit](https://github.com/AlexsJones/llmfit) (AlexsJones/llmfit v1.1.16) でハードウェアに合う **MoE (Mixture-of-Experts)** モデルを選び、推論ベンチマークと最初の LoRA ファインチューニングを 2 台で一通り動かすための実験ディレクトリ。目的は「パイプラインが一度通ること」で、本番向けチューニングではない。本番 vLLM の manifest (`vllm/base`, `vllm/overlays`) には触れない。

| マシン | ハードウェア | 推論 | 学習 |
|---|---|---|---|
| deploy-note | i7-12650H, WSL 19 GB, GTX 1650 4 GB (Turing, fp16 のみ) | Windows ネイティブ Ollama 0.35.1 (`localhost:11434`, WSL から mirrored networking で到達) | CUDA + TRL/PEFT (`train_lora_cuda.sh`)、**vLLM 窓の中だけ** |
| tmf-m3 | Apple Silicon (Mac15,3) | MLX (`mlx_lm.generate` / `mlx_lm.server`) / Ollama | MLX (`train_lora_mlx.sh`) |

結果の表は [vllm/docs/BENCHMARK_RESULTS.md](../../vllm/docs/BENCHMARK_RESULTS.md) に、llmfit の選定メモは [results-summary/](results-summary/) に置く。生 JSON は `results/`（gitignore）。

## ディレクトリ

| パス | 内容 |
|---|---|
| `scripts/llmfit_survey.sh` | `llmfit system/fit --json` をプロファイル別に保存し、MoE 行 (`is_moe`) を jq で抽出 |
| `scripts/bench_ollama.sh` | 既存 [`scripts/bench_ollama_openai.sh`](../../scripts/bench_ollama_openai.sh) (→ `bench_vllm.py`) を固定設定で呼ぶ薄いラッパ。単発 `/api/generate` の decode tok/s と `/api/ps` の VRAM 比率も保存 |
| `scripts/eval_quality.py` | 30 問固定 QA の正答率。OpenAI 互換 API モードと `--hf-model`（transformers generate、`--adapter` で LoRA をマージ、`--heldout` で held-out loss） |
| `scripts/train_lora_cuda.sh` | 既存 [`train_lora.py`](../../vllm/components/finetune/scripts/train_lora.py) を fp16 / r=8 / q,k,v,o / 1 epoch / seq 1024 で実行。**空き VRAM < 3 GiB なら起動拒否** |
| `scripts/run_train_lora.py` | `train_lora.py` を無改変のまま現行 TRL 1.x / transformers 5.x で動かすためのランチャ（下記） |
| `scripts/train_lora_mlx.sh` | tmf-m3 用。`mlx_lm.lora` で同等設定、before/after の held-out loss、fuse |
| `scripts/vllm_window.sh` | deploy-note の GPU を空ける時間窓 `start|stop|status`（下記） |
| `scripts/fetch_sft_data.py` | `data/sft_*.jsonl` の再生成 |
| `data/eval_qa.jsonl` | 評価 30 問（日本語一般・算数 15 + Kubernetes/Linux/ネットワーク 15）。正規化（NFKC・小文字・空白/記号除去）後の部分一致で採点 |
| `data/sft_train.jsonl` / `data/sft_heldout.jsonl` | SFT 300 行 / held-out 50 行（chat 形式 `{"messages": [...]}`） |

### SFT データの出典とライセンス

- [kunishou/oasst1-chat-44k-ja](https://huggingface.co/datasets/kunishou/oasst1-chat-44k-ja) — **Apache-2.0**（[OpenAssistant/oasst1](https://huggingface.co/datasets/OpenAssistant/oasst1) (Apache-2.0) の日本語訳）。
- datasets-server の `/rows` API で先頭から読み、1 往復（human → gpt）かつ質問 ≤ 300 字・回答 ≤ 600 字の行だけを順に採用（先頭 1,200 行を走査）。先頭 300 行を train、次の 50 行を held-out。決定的なので `python3 scripts/fetch_sft_data.py` で再現できる。

## 再現手順 — deploy-note (WSL)

```bash
cd llm-experiments/moe

# 1. llmfit (sha256 は公開 .sha256 と照合)
base=https://github.com/AlexsJones/llmfit/releases/download/v1.1.16
f=llmfit-v1.1.16-x86_64-unknown-linux-gnu.tar.gz
curl -fsSLO "$base/$f" && curl -fsSLO "$base/$f.sha256"
[ "$(awk '{print $1}' "$f.sha256")" = "$(sha256sum "$f" | awk '{print $1}')" ] && echo OK
tar xzf "$f" && install -m0755 llmfit-v1.1.16-x86_64-unknown-linux-gnu/llmfit ~/.local/bin/

# 2. サーベイ (vram0g / vram1g / vram4g)
HOST_LABEL=deploy-note scripts/llmfit_survey.sh

# 3. 学習用 venv（現行版。GraniteMoe には新しい transformers が要る）
python3 -m venv ~/llm-exp/.venv
~/llm-exp/.venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cu126
~/llm-exp/.venv/bin/pip install transformers peft trl datasets accelerate bitsandbytes aiohttp

# 4. 推論ベンチ（窓の外 = CPU 専用タグ）
for m in granite3.1-moe:3b granite4:tiny-h; do
  curl -s localhost:11434/api/pull   -d "{\"model\":\"$m\",\"stream\":false}"
  curl -s localhost:11434/api/create -d "{\"model\":\"$m-cpu\",\"from\":\"$m\",\"parameters\":{\"num_gpu\":0},\"stream\":false}"
  scripts/bench_ollama.sh "$m-cpu" cpu-outside-window
  python3 scripts/eval_quality.py --model "$m-cpu" --output "results/eval-${m//:/_}-cpu.json"
  curl -s localhost:11434/api/generate -d "{\"model\":\"$m-cpu\",\"keep_alive\":0}"   # unload
done
```

- Ollama は **Windows ネイティブ 0.35.1** を使う。WSL 側の `ollama` unit は起動しない（ポート競合）。
- **窓の外では GPU オフロードしない。** Windows から見た GPU 空きは 3.2 GiB だが、実際は vLLM が ~3 GiB 使用中（WSL の nvidia-smi で 885 MiB 空き）。Ollama 既定タグは GPU に載せに行くため `num_gpu 0` の `-cpu` タグを作る。`torch.cuda.mem_get_info()` も WSL では同じく誤報する（3294 MiB 空きと表示）ので、空き VRAM の判定は必ず nvidia-smi で行う。
- Ollama 0.35.1 では granite **1B-A400M** 系 (`granite3-moe:1b`, `granite3.1-moe:1b`) が CPU/GPU どちらでも `ggml-impl.h:330: fatal error` (0xc0000409) でロードできない。1B-A400M の評価は transformers で行う。

### LoRA（vLLM 窓の中）

```bash
sudo scripts/vllm_window.sh start            # 90 分ガード付き
~/llm-exp/.venv/bin/python scripts/eval_quality.py --hf-model ibm-granite/granite-3.1-1b-a400m-instruct \
    --heldout data/sft_heldout.jsonl --label before --output results/eval-lora-before.json
scripts/train_lora_cuda.sh                   # OOM なら USE_4BIT=true scripts/train_lora_cuda.sh
~/llm-exp/.venv/bin/python scripts/eval_quality.py --hf-model ibm-granite/granite-3.1-1b-a400m-instruct \
    --adapter ~/llm-exp/adapters/<run> --heldout data/sft_heldout.jsonl --label after --output results/eval-lora-after.json
sudo scripts/vllm_window.sh stop             # 必ず実行（失敗時は非ゼロ終了、state を残す）
```

`run_train_lora.py` について: `train_lora.py` は `dataset_text_field` / `max_seq_length` / `packing` を `SFTTrainer()` に直接渡し、`TrainingArguments(warmup_ratio=...)` を使う。TRL 1.x はこれらを SFTConfig に移し（`max_seq_length` → `max_length`）、transformers 5.x は `warmup_ratio` を廃止したため、そのままでは `TypeError` になる。ランチャはこの 2 点だけを実行時にパッチし、chat 行を base モデルの chat template で `text` に変換してから `train_lora.py` を `runpy` で実行する。本番の `train_lora.py` と ConfigMap は変更しない。終了時に学習時間・ピーク VRAM・tokens/s を `train_stats.json` に書く。

## 再現手順 — tmf-m3 (MLX)

```bash
brew install llmfit   # または darwin tarball (aarch64-apple-darwin, sha256 照合)
HOST_LABEL=tmf-m3 scripts/llmfit_survey.sh     # 統合メモリなので autodetect 1 プロファイル
uv tool install mlx-lm
mlx_lm.server --model <mlx-model> --port 8090 &
python3 scripts/eval_quality.py --base-url http://127.0.0.1:8090/v1 --model <mlx-model>
scripts/train_lora_mlx.sh                      # 同じ Granite 1B-A400M / 同じデータ
```

Colima k3s / OpenClaw のワークロードがメモリ不足にならないよう、メモリプレッシャーを見ながら実行する。

## vLLM 窓 runbook（deploy-note） — `scripts/vllm_window.sh`

> **注意:** 本番の vLLM を一時停止する。オーケストレーターのみが実行する。**`stop` は必ず実行する**（失敗・中断時も）。

| コマンド | 動作 |
|---|---|
| `scripts/vllm_window.sh status` | 読み取りのみ（root 不要）。Application の automated / sync / health、deploy の replicas、生きている（Failed 以外の）vllm Pod 数、`/health`、GPU used/free、UID、学習 PID、窓の残り時間 |
| `sudo scripts/vllm_window.sh start` | ① state 記録（`vllm-kubeadm` **と tracking-id で辿った親 `root-application`** の syncPolicy、replicas、ns/PVC/Service の UID）② **書き込み前に** 90 分 watchdog を起動（期限後は `stop` が成功するまで 60 秒おきに最大 30 回）③ 親 → 子の順に `syncPolicy.automated` を削除 ④ `deploy/vllm` を 0 に、Failed 以外の vllm Pod が消えるまで待ち、nvidia-smi `memory.free >= 3072 MiB` まで待つ。③以降の失敗、または SIGINT/SIGTERM/SIGHUP で自動 `stop`（ロールバック。ロールバック中はシグナルを無視） |
| `sudo scripts/vllm_window.sh stop` | `train.pid` の学習プロセスが残っていれば終了（cmdline に `train_lora` を含む場合のみ）→ replicas を戻す → 記録した automated を子 → 親の順に復元し読み戻し確認 → rollout + `/health` 200（API サーバの service proxy 経由）→ UID 不変 → `vllm-kubeadm` Synced/Healthy。書き込みは 5 回 × 10 秒リトライ、途中が失敗しても後続の復元は必ず実行。どれか不一致なら非ゼロ終了し state を残す |

- `root-application` が `vllm-kubeadm` を selfHeal で管理しているため、子だけ automated を外すと数分で親に戻され、vLLM が勝手に復活する。だから親も一緒に止める。
- kubectl は `--kubeconfig /etc/kubernetes/admin.conf`（root 専用ファイル。読めなければ `sudo -n`）。上書きは `VLLM_WINDOW_KUBECONFIG`。state は固定の `/var/lib/vllm-window/`（`VLLM_WINDOW_STATE_DIR` で上書き）なので、start / stop / watchdog が誰の権限で動いても同じ場所を見る。
- `start` は `/var/lib/vllm-window/train.pid` を呼び出しユーザー所有で作り、`train_lora_cuda.sh` が自分の PID をそこに書く。期限の watchdog / `stop` はその学習を止めてから vLLM を戻す。
- 既存の Failed Pod `vllm-6df68b98cc-w59qx`（UnexpectedAdmissionError、GC されない）は Pod 待ちから除外している。
- `start`/`stop` とも冪等: 2 回目の `start` は最初に記録した値を保持し、state の無い `stop` は検証だけ行う。
- 既知のリスク: `deploy/vllm` は `vllm/vllm-openai:latest` + `imagePullPolicy: Always` なので、`stop` 時の再起動で**新しい vLLM イメージを pull しうる**。UID 検査はこれを捕まえないため、ログに出る imageID を確認する。
- 窓を開ける前に Ollama のモデルをアンロードしておく（空き VRAM の待ちが通らない）。
