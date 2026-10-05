# 実機前提 backlog の k8s ネイティブ再設計（kind で検証する）

- 対象 issue: #9 #10 #11 #14 #15 #17 #18 #19 #20 #23 #28 #30
- 状態: 設計案（未実装）。この文書のコマンドとスクリプト名は**これから作るもの**を含む。既存ファイルには「既存」と書く
- 作成日: 2026-10-05

## 0. 要約

| # | 元の前提 | k8s での代替 | 判定 | 規模 | CI（kind） |
|---|---------|-------------|------|------|-----------|
| #9 | GPU 1 枚で compare_models.sh | kind + CPU 推論（Ollama CPU または vLLM CPU）で 0.5B 級を比較。出力の形式と比較の流れだけを検証する | 部分的に可 | M | YES（Ollama CPU、約 15 分） |
| #10 | 24GB+ GPU で LFM/Qwen3.6/Gemma4 | CPU で動く小型モデル（LFM2.5-350M など）だけ kind で実測。大型モデルは「プロファイルの妥当性」と「OOM を記録できる経路」までに限る | 部分的に可 | M | 条件付き（小型のみ、nightly 扱い） |
| #11 | Windows の RX 5700 + ROCm | k8s では意味がない（特定 GPU とドライバの問題） | 対象外。クローズを推奨 | - | NO |
| #14 | Serena ログの Logstash 分岐 | kind の ELK にモックイベントを送り、ES の索引先を assert する | 再設計可 | S | YES（約 10 分） |
| #15 | Windows ホストの Collector | collector.py を Pod にし、サイドカーが Serena 形式のログを書き出す | 部分的に可（Windows 固有部分は残る） | M | YES（約 12 分） |
| #17 | 実データが ES に入っていること | シード Job で 60 件投入し、kind overlay の手動 Job で JSONL を作る | 再設計可 | S | YES（約 12 分） |
| #18 | Windows Ollama + GPU vLLM | Ollama CPU Pod（nomic-embed-text）+ teacher-stub または小型 chat モデル | 再設計可 | M | YES（約 15〜20 分） |
| #19 | ベアメタルの VIP/LB | kind の Docker ネットワーク上で MetalLB L2、kind HA の haproxy LB で endpoint を検査 | 部分的に可 | M | YES（約 10 分） |
| #20 | 3 台の実 CP ノード | kind の 3 control-plane（stacked etcd + haproxy LB は kind が自動で用意） | 部分的に可（03b スクリプト自体は通らない） | M | YES（約 10〜15 分） |
| #23 | 3 worker と iSCSI | 静的検証 + local-path での PVC 契約テスト。Longhorn 実動作は Linux ランナーでの実験 spike に限る | 部分的に可（主目的は実機に残る） | L | 部分的（静的と PVC 契約は YES、Longhorn 実動作は実験） |
| #28 | Windows の AMD Adrenalin ドライバ | k8s とは無関係 | 対象外。クローズを推奨 | - | NO |
| #30 | WSL kubeadm + Calico | kind（`disableDefaultCNI`）+ Calico で NetworkPolicy の回帰テスト。旧ポリシーで失敗することも確かめる | 再設計可（WSL 固有要因は残る） | M | YES（約 12 分） |

## 1. 全体方針

### 1.1 原則

1. **判定は機械的にする**。受け入れ条件は `kubectl wait`、`curl` の HTTP ステータスや JSON の値、スクリプトの exit 0 で判定する。目視（Kibana 画面など）は受け入れ条件にしない
2. **kind で検証できる範囲と実機の範囲を分ける**。issue ごとに「kind 受け入れ条件」と「実機フォローアップ」を書き、実機の分は別 issue（ラベル `needs-hardware`）に切り出す
3. **陰性テストを入れる**。「壊れた設定で失敗する」ことも確かめ、テストが常に通るだけになっていないことを示す（#30 の旧 NetworkPolicy、#18 の埋め込みフォールバック検出など）
4. **GPU を前提にしない**。kind は Docker 内で動くので、ホスト GPU は Pod から見えない（既存の `kind/scripts/load-images.sh` のコメントのとおり）。推論は CPU 実装か teacher-stub（既存 `vllm/components/teacher-stub/`）で代える

### 1.2 共通の kind テストハーネス（新規）

```
kind/
  test-cluster.yaml            # 新規: 1 CP + 2 worker。hostPort なし（既存 kind-config.yaml の 80/443 と衝突しない）
  test-cluster-ha.yaml         # 新規: 3 CP + 2 worker（#19 #20）
  test-cluster-calico.yaml     # 新規: disableDefaultCNI: true, podSubnet 192.168.0.0/16（#30。kubeadm/kubeadm-config.yaml と同じ値）
  addons/metallb/              # 新規: kubeadm/addons/metallb を参照し、IPAddressPool を kind サブネット用に差し替える overlay
scripts/e2e/
  lib.sh                       # 新規: 共通関数
  run.sh                       # 新規: 入口。./scripts/e2e/run.sh <suite> [--keep] [--cluster-config ...]
  suites/
    elk-serena-ingest.sh       # #14
    serena-collector.sh        # #15
    serena-export.sh           # #17
    serena-rag.sh              # #18
    llm-cpu-compare.sh         # #9 #10
    metallb-l2.sh              # #19
    ha-control-plane.sh        # #20
    storage-pvc-contract.sh    # #23
    calico-netpol-dns.sh       # #30
  fixtures/
    serena-sample-mcp.txt      # SERENA_LOG_FORMAT のサンプル行
    seed-serena-events.py      # ES/Logstash 向けシード生成（#17 #18 で共有）
.github/workflows/e2e-kind.yaml  # 新規: suite を matrix で回す
```

**命名規約**: スイート名は機能名（`<領域>-<対象>`）にし、issue 番号はスイート先頭のコメントと `run.sh --list` の出力に書く。issue をクローズしたあとも回帰テストとして残すので、番号ではなく機能名にする。

**入口**: リポジトリに Makefile はない（確認済み）。Windows では make が標準で入っていないため、入口は `scripts/e2e/run.sh`（bash。Git Bash / WSL / CI で動かす）にする。Makefile は作らない。

**`lib.sh` が提供する関数（案）**

| 関数 | 内容 |
|------|------|
| `e2e::cluster_up <config> [name]` | `kind create cluster`。同名のクラスタがあれば再利用。既存の `kind/scripts/create-cluster.sh` は addons も入れるので、テストではクラスタ作成だけを lib で行う |
| `e2e::cluster_down` | `--keep` が無ければ `kind delete cluster`（trap で必ず実行） |
| `e2e::load_image <img>` | `docker pull` + `kind load docker-image` |
| `e2e::build_distill_image` | `vllm/components/distill/Dockerfile` から `distill-collector:3.11-aiohttp` を build して load（既存手順は `vllm/overlays/kind/README.md` にある） |
| `e2e::deploy_elk` | `kubectl apply -k elk-stack/overlays/kind`（既存）→ ES/Logstash の rollout を待つ |
| `e2e::deploy_ollama_cpu <models...>` | 新規 component（1.3 節）を適用し、`ollama pull` を Job で実行 |
| `e2e::incluster_curl <url>` | 一時 Pod（`curlimages/curl`）から curl する。port-forward を使わず、Windows でも同じに動かす |
| `e2e::es_count <index> <query-json>` | 一時 Pod から `_count` を叩き、件数を返す |
| `e2e::assert_eq / assert_ge / assert_contains` | 失敗時は `e2e-results/<suite>.json` に記録し、exit 1 |
| `e2e::dump_on_fail <ns...>` | 失敗時に `kubectl get all,events`、`describe`、ログを `e2e-results/` に保存（CI の artifact になる） |

**結果の形式**: 各スイートは `e2e-results/<suite>.json`（`{suite, issue, passed, checks:[{name, ok, detail}]}`）を出す。CI は artifact として保存する。

### 1.3 issue 間で共有する部品

| 部品 | 使う issue | 状態 |
|------|-----------|------|
| ELK on kind（`elk-stack/overlays/kind`） | #14 #15 #17 #18 | 既存。`docs/DISTILL_VERIFICATION.md` によれば kind-dev での起動実績あり |
| Serena シード生成（`scripts/e2e/fixtures/seed-serena-events.py`） | #14 #17 #18 | 新規。既存 `scripts/test-serena-mock-ingest.sh` のペイロードを一般化し、N 件・レベル混在・セッション複数にする |
| Ollama CPU component（`ollama/k8s/` または `vllm/components/ollama-cpu/`） | #9 #10 #18 | 新規。リポジトリに Ollama の Deployment マニフェストはない（`ollama/` には Modelfile だけがある。確認済み）。`ollama/ollama` イメージ + モデル保存用 PVC（local-path）+ pull Job で作る |
| teacher-stub（`vllm/components/teacher-stub/`） | #18、#9 の経路検証 | 既存。OpenAI 互換の応答を固定で返すので、CI で結果が揺れない |
| ingest 用 NetworkPolicy | #14 #15 | 既存の `elk-stack/logstash-distill-networkpolicy.yaml` は「vllm 名前空間 かつ `app=distill-collector`」からしか 5000 番を許可しない。テストの Pod はこのラベルを付けるか、新しく `logstash-allow-serena-ingest` を追加する（後者を推奨）。同様に ES も、`elasticsearch-allow-serena-export` などが Ingress を「elk-stack 名前空間」と vllm の特定ラベルだけに絞っている（確認済み）。そのため `e2e::es_count` の一時 Pod と #18 の RAG Job は **elk-stack 名前空間で動かす**か、ES 用の許可ポリシーを追加する |
| CPU 推論の比較ランナー | #9 #10 | 既存 `vllm/benchmark/scripts/compare_models.sh` は `OVERLAY` と `COMPARE_PROFILES` を環境変数で受け取る。CPU 用プロファイル `vllm/benchmark/model-profiles.cpu.json`（新規）を足す |

### 1.4 CI（`.github/workflows/e2e-kind.yaml`、新規）

- トリガー: `pull_request`（paths フィルタでスイートごとに絞る）、`workflow_dispatch`（suite を指定）、`schedule`（重い #9 #10 #23 spike は nightly）
- ジョブ: `matrix.suite`。各ジョブで `helm/kind-action`（または kind バイナリの直接インストール）→ `scripts/e2e/run.sh ${{ matrix.suite }}`
- ランナー資源の目安: 公開リポジトリ（`take566/kubernetes` は PUBLIC。確認済み）の ubuntu-latest は 4 vCPU / 16 GB RAM / 空きディスク 14 GB 前後とされる（**未確認。最初の実行で `nproc`、`free -g`、`df -h` をログに出す**）
- ディスク対策: ELK の 3 イメージで数 GB、vLLM CPU イメージはさらに大きい（サイズ未確認）。必要に応じて先頭で不要なツールチェーンを削除するステップを入れる
- 既存 `validate.yaml`（yamllint + kustomize build + kubeconform）は残す。e2e は追加のジョブにする

### 1.5 ローカル（Windows 11 + Docker Desktop）での注意

- Docker Desktop は 16 CPU / 約 31 GiB（`docker info` で実測）。資源は足りる
- **Docker Desktop では kind ノードのコンテナ IP にホストから直接届かない**（WSL2 VM の中にあるため）。MetalLB の IP や LB コンテナへの到達確認は、`docker run --rm --network kind curlimages/curl ...` のように kind ネットワーク上のコンテナから行う。CI（Linux）ではホストから直接届くが、スクリプトは両方で同じにするため、常に kind ネットワーク上のコンテナから確認する
- kind バイナリは WinGet で入っている（`.../WinGet/Links/kind`）。`kind version` の実測は **v0.33.0**（反証レビューで確認）
- スクリプトは bash 前提。PowerShell 版は作らない

## 2. 実装順序（依存関係と ROI 順）

| 順 | 作業 | 規模 | 依存 | 理由 |
|----|------|------|------|------|
| 0 | ハーネス（`lib.sh`、`run.sh`、`test-cluster.yaml`、workflow の雛形） | M | なし | 全スイートの前提 |
| 1 | #14 elk-serena-ingest | S | 0 | 実装は既存（`logstash-configmap.yaml` の 197 行目付近に `serena.log` 分岐あり）。assert を足すだけなので ROI が最も高い |
| 2 | #30 calico-netpol-dns | M | 0 | 実害があった不具合の回帰テスト。ELK と独立しているので 1 と並行できる |
| 3 | #15 serena-collector | M | 1 | collector.py は既存。Pod 化とサイドカーが新規 |
| 4 | #17 serena-export | S | 1（シード生成） | component と kind overlay は既存。シードと assert だけ |
| 5 | #18 serena-rag | M | 1, 4, Ollama CPU | Ollama CPU component がここで初めて必要 |
| 6 | #9 llm-cpu-compare | M | Ollama CPU | 5 で作った component を再利用 |
| 7 | #19 metallb-l2 | M | 0 | `test-cluster-ha.yaml` を 8 と共用 |
| 8 | #20 ha-control-plane | M | 7 | 同じ HA クラスタで続けて回せる |
| 9 | #10 llm-cpu-compare（extended の小型分） | M | 6 | 小型モデルだけ。nightly |
| 10 | #23 storage-pvc-contract + Longhorn spike | L | 0 | spike は時間を区切り、失敗してもよい |
| - | #11 #28 | - | - | k8s 再設計の対象外。クローズまたは `needs-hardware` に移す |

見積もりの目安: S = 0.5 日以内、M = 1〜2 日、L = 3 日以上または結果が読めない spike を含む。

## 3. issue ごとの再設計

### #9 推論モデル選定（Qwen2.5 採用）

**元の前提と止まっている理由**: 残っている受け入れ条件は「GPU ノードで compare_models.sh を実行し JSON を記録」だけ。GPU クラスタがないので実行できない。kustomize の出力（kubeadm で 1.5B、kind で 0.5B）は既存のファイルで満たしている（`vllm/overlays/kubeadm/model-patch.yaml` と `vllm/overlays/kind/model-patch.yaml` で確認済み）。

**k8s での代替**

- 既存 `vllm/overlays/kind/` は teacher-stub に差し替えているので、実際には推論しない（`teacher-stub-patch.yaml`）。そこで実推論の経路を 2 つ用意する
  - (a) **Ollama CPU**（推奨。CI 向け）: 新規 component に `qwen2.5:0.5b` と `qwen2.5:1.5b` を pull する。対応表は既存の `vllm/benchmark/ollama-model-map.json` を使う
  - (b) **vLLM CPU**（ローカル向け）: 既存 `vllm/overlays/kind/cpu/`（`openeuler/vllm-cpu:0.20.1-oe2403sp3`）。x86_64 で動くか、`--dtype float16` が x86 CPU で使えるかは**未確認**。最初に spike で確かめ、駄目なら bfloat16 / float32 に変える
- 比較の流れ: 既存 `compare_models.sh` は `vllm-config` を patch → rollout restart → `vllm/benchmark` Job の順で動く。(b) ではこれをそのまま `OVERLAY=kind/cpu COMPARE_PROFILES=vllm/benchmark/model-profiles.cpu.json` で使う。(a) では Ollama の OpenAI 互換 API（`/v1/chat/completions`）に `bench_vllm.py` を向ける（`bench_vllm.py` は `base_url` を受け取って `chat/completions` を叩く作りなので、接続先は変えられる。起動待ちの `wait_for_health` は、`base_url` が `/v1` で終わると `/api/tags` を叩くので、Ollama にも対応済み。確認済み）
- 新規: `vllm/benchmark/model-profiles.cpu.json`（`--gpu-memory-utilization` などの GPU 専用引数を除いたもの）、`scripts/e2e/suites/llm-cpu-compare.sh`

**kind 受け入れ条件**

- [ ] `kubectl kustomize vllm/overlays/kubeadm | grep -q 'Qwen/Qwen2.5-1.5B-Instruct'` と `kubectl kustomize vllm/overlays/kind | grep -q 'Qwen/Qwen2.5-0.5B-Instruct'` が exit 0（既存の状態を固定する回帰テスト）
- [ ] `./scripts/e2e/run.sh llm-cpu-compare` が exit 0。中で次を確かめる
  - [ ] Ollama Pod が `kubectl wait --for=condition=Ready pod -l app=ollama -n llm --timeout=300s` で Ready
  - [ ] 候補 2 つ以上で、`e2e-results/llm-cpu-compare/<model>.json` に `p50_ms`、`p99_ms`、`tokens_per_s` が数値で入る（`jq -e '.p50_ms > 0'`）
  - [ ] 存在しないモデル ID を 1 つ混ぜると、その候補が `status: "failed"` と記録される（失敗を記録できることの確認）。**注意**: 既存の `compare_models.sh` は、失敗した候補の JSON を書かない。また `CONTINUE_ON_ERROR=true` でも、失敗が 1 件あれば最後に exit 1 になる（160〜167 行目。確認済み）。この条件を満たすには、失敗時に `{model, status, reason}` を書く改修と、スイート側で「期待した失敗だけなら成功」と扱う判定が必要になる。新規の作業として見積もりに入れる
- [ ] `python vllm/benchmark/scripts/validate_model_profiles.py vllm/benchmark/model-profiles.cpu.json` が exit 0

**CI**: YES。Ollama CPU で 0.5B と 1.5B を回して 10〜15 分と見込む（モデル取得込み、未測定）。数値はランナーで揺れるので、**CI では数値の大小を判定せず、形式だけを見る**。

**実機フォローアップ（`needs-hardware` に切り出す）**: GPU での p50/p99/tok/s の実測、`VLLM_EXTRA_ARGS` の再チューニング、7B 級向け overlay。CPU の数値から GPU 上の順位は推定できないため、**採用モデルの最終判断は実機で行う**。

### #10 拡張候補（LFM / Qwen3.6 / Gemma4）のベンチ

**元の前提と止まっている理由**: Qwen3.6-35B-A3B は約 22 GiB、Gemma4-E4B は約 10 GiB の VRAM を前提にしている（issue 本文の推定値）。24GB+ の GPU がない。

**k8s での代替**

- CPU で現実的に回せるのは `LiquidAI/LFM2.5-350M`、`LiquidAI/LFM2.5-1.2B-Instruct` 程度（Ollama のタグは `ollama-model-map.json` で `sam860/LFM2:350m` などのコミュニティ版。公式でない点に注意）
- 大型候補は kind では**起動しない**前提で、次の 2 つだけを検証する
  1. `model-profiles.json` の各プロファイルが vLLM の引数として正しいか（既存 `validate_model_profiles.py` を CI で実行。`validate.yaml` に `model-profiles` ジョブが既にある）
  2. OOM や起動失敗を **JSON に記録できる経路**: メモリ上限を小さくした Pod で意図的に OOMKilled を起こし、compare 側が `status: "oom"` を書くことを確かめる（擬似 OOM。実際の VRAM の OOM とは別物）。`status` を書く機能は既存の `compare_models.sh` に**ない**（#9 の注記を参照）ので、新規実装になる。MVP では削ってよい
- Gemma4 は HF ゲートつき。CI に HF_TOKEN を入れない限り取得できないため、kind では対象外とする

**kind 受け入れ条件**

- [ ] `COMPARE_SET=extended-cpu ./scripts/e2e/run.sh llm-cpu-compare` が exit 0 で、LFM2.5-350M の結果 JSON に `p50_ms`、`p99_ms`、`tokens_per_s` がある
- [ ] メモリ上限 256Mi の候補が `status: "oom"`（または `"failed"` と理由 `OOMKilled`）で記録される（`jq -e`）
- [ ] `validate_model_profiles.py` が extended の全プロファイルで exit 0

**CI**: 条件付き YES。LFM 小型のみで nightly（`schedule`）。PR では回さない。20 分前後（未測定）。

**実機フォローアップ**: issue の受け入れ条件 4 つ（LFM2.5-1.2B の 1 GPU 起動、Qwen3.6 の 24GB 起動か OOM 記録、Gemma4 text-only、3 ファミリの GPU 実測）は**すべて実機に残る**。この issue は「CPU 経路の整備」と「GPU 実測」に分割することを推奨する。

### #11 Windows AMD RX 5700 の ML スタック未整備

**元の前提**: 特定のローカル GPU（RX 5700 / gfx1010。ROCm の公式サポート外）で ROCm / Docker / k8s GPU を整える。

**判定: k8s 再設計の対象外。クローズを推奨**

- 中身はホストの GPU ドライバとランタイムの整備で、kind ではホスト GPU が見えないため、k8s で再現する意味がない
- issue の目的の「ベンチを回せない」は、#9 #10 の CPU 経路（kind）で CI 上は解消できる
- 残っているユーザー作業（WSL への ROCm 導入、Linux GPU ノード）は、ハードウェアの個人環境の作業である。必要なら `needs-hardware` の issue を 1 つにまとめ、この issue はクローズする
- 補足: Windows で GPU 推論する経路は、既存 `scripts/update-adrenalin-gpu.ps1` の冒頭コメントによると Ollama の Vulkan バックエンドが前提になっている（ROCm ではない）。issue の前提自体が古くなっている可能性がある

### #14 Logstash の serena.log 分岐

**元の前提と止まっている理由**: 実装はほぼ終わっている（`elk-stack/logstash-configmap.yaml` に `if [event][kind] == "serena.log" or [serena][stream]` の分岐あり）。ただし受け入れ条件の確認が `scripts/test-serena-mock-ingest.sh` の送信だけで、ES に入ったことを**自動で確かめていない**（スクリプトは確認用の curl を表示して終わる）。

**k8s での代替**

- kind で `elk-stack/overlays/kind` を適用し、シード生成から次の 4 種類を送る
  1. 通常の serena イベント（INFO）
  2. パスとメールアドレスを含む serena イベント（PII マスクの確認）。Logstash のパスのマスクは Windows 形式（`X:\Users\...`）だけが対象なので（確認済み）、シードのパスは `C:\Users\alice\...` の形にする
  3. `api_key=` を含む serena イベント（`sensitive_pattern` フラグの確認）
  4. serena 以外のイベント（従来の `logstash-*` に入ることの確認）
- 送信元の Pod には新しい NetworkPolicy `logstash-allow-serena-ingest`（`app=serena-collector` からの 5000 番を許可）を当てる。kindnet は kind v0.24.0 から NetworkPolicy を実装している（kind のリリースノートで確認。ローカルは v0.33.0）。したがって**ポリシーは効く**。既存の `logstash-allow-distill-ingest` が Logstash を選択しているため、許可ポリシーのない送信元からの 5000 番は落ちる。新しい許可ポリシーは必須である

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh elk-serena-ingest` が exit 0。中で次を確かめる（ES `_refresh` のあと `_count` / `_search`）
  - [ ] `logs-serena` に 1〜3 の 3 件が入る（`session_id` で絞る）
  - [ ] 2 の `message` に元のメールアドレスとパスが**含まれず**、`[EMAIL]` と `[USER_HOME]` が**含まれる**（`jq -e '(.message | test("@example.com") | not) and (.message | contains("[EMAIL]")) and (.message | contains("[USER_HOME]"))'`。「含まれない」だけを見ると、message が空でも通ってしまう）
  - [ ] 1 の `serena.quality.score` が数値で、0 以上 1 以下
  - [ ] 3 の `serena.quality.flags` に `sensitive_pattern` が入る
  - [ ] 4 が `logs-serena` に**入らず**、`logstash-*` に入る
- [ ] Logstash のログに `serena` イベント由来の mapping エラー（HTTP 400）が出ていない（`kubectl logs deploy/logstash | grep -c 'status=>400'` が 0）。Logstash 9.x のログで 400 がどう表記されるか（`"status"=>400` など）は**未検証**である。初回に、わざと 400 を起こしてパターンを固定する。そうしないと、パターンが合わずに常に 0 になる偽陽性になる

**CI**: YES。ELK の起動待ちを含めて 8〜10 分（未測定）。ES のメモリ上限は 2Gi（`elasticsearch-deployment.yaml`）なので、16 GB のランナーで足りる。

**実機フォローアップ**: なし（この issue は kind で閉じられる）。

### #15 Windows Serena Log Collector

**元の前提と止まっている理由**: Windows ホストで `~/.serena/logs/**/mcp_*.txt` を tail し、port-forward 経由で Logstash に送る。Kibana で表示されるかを目視で確かめる受け入れ条件になっている。

**k8s での代替**

- `elk-stack/design/serena-collector/collector.py`（既存。inode とサイズでローテーションを検知する実装がある）をそのまま Pod で動かす
  - Pod 構成: `collector` コンテナ（`python:3.11-slim-bookworm` + requirements）と `writer` サイドカーで `emptyDir` を共有する
  - `writer` は `fixtures/serena-sample-mcp.txt`（SERENA_LOG_FORMAT の行）を `/serena-home/logs/<date>/mcp_A.txt` に少しずつ追記し、途中で `mcp_B.txt` を新しく作る（ローテーションの再現）。health-check も `/proj1/.serena/logs/health-checks/` と `/proj2/...` の 2 か所に書く。collector が探すのは `logs/*/mcp_*.txt`（1 階層）と `health-checks/health_check_*.log` なので（確認済み）、ファイル名はこの形に合わせる
  - 設定は `collector-config.example.yml` と同じ形の ConfigMap にする（`logstash.host: logstash.elk-stack.svc.cluster.local`、`projects` を 2 つ）
- 新規: `elk-stack/overlays/kind-collector/`（Pod / ConfigMap / NetworkPolicy）、`scripts/e2e/suites/serena-collector.sh`
- 「Kibana に表示」は「ES に入った」に置き換える（Kibana は ES を読むだけなので、ES で確かめれば十分と判断した）

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh serena-collector` が exit 0。中で次を確かめる
  - [ ] `kubectl wait --for=condition=Ready pod/serena-collector -n elk-stack --timeout=120s`
  - [ ] writer が書いた行数 N と、`logs-serena` の `serena.stream: mcp.file` の件数が一致する（ローテーション前後とも。重複も欠落もない）。一致を求めるのは、**Logstash を止めない段階だけ**にする。collector は TCP の `sendall` が成功した時点で送信済みとみなす（at-most-once。確認済み）。そのため、Logstash の再起動中に送った行は失われることがある
  - [ ] `serena.stream: health_check` の件数が 2 プロジェクト分あり、`serena.project` が 2 種類
  - [ ] パースしたフィールド（`serena.logger`、`serena.function`、`serena.line`、`log.level`）が固定のサンプル行の期待値と一致する
  - [ ] Logstash を `kubectl rollout restart` しても、Collector が再接続し（`reconnect_delay`）、**再起動が終わったあとに書いた行**が全件 ES に入る（再起動中の行の欠落は許容し、件数を記録するだけにする）
- [ ] `collector.py` の単体テスト（新規 `elk-stack/design/serena-collector/test_collector.py`。パース、ローテーション検知）が `pytest` で exit 0（クラスタ不要）
- ~~README に Task Scheduler の登録手順の節がある~~（`elk-stack/design/serena-collector/README.md` の 70 行目に `## Task Scheduler 登録` が既にある。常に通る条件なので、受け入れ条件から外した）

**CI**: YES。ELK + Collector で 10〜12 分（未測定）。pytest はクラスタなしで 1 分以内。

**実機フォローアップ**: Windows 固有の部分は k8s で再現できない。NTFS での `st_ino` の挙動、Windows のパス区切りと `%USERPROFILE%` の展開、Task Scheduler での常駐、port-forward が切れたときの再接続、実際の Serena が出すログ。これらは実機のチェックリストとして残す。

### #17 serena-export Job（ES から JSONL）

**元の前提と止まっている理由**: 実データ（Windows の Collector から来た Serena ログ）が ES にある前提。component（`vllm/components/serena-export/`）と kind overlay（`vllm/overlays/kind/serena-export/`。CronJob が `suspend: true`）は既にある。

**k8s での代替**

- シード生成で `logs-serena` に 60 件を入れる。**配分を見直した**: 通常 55 件、`sensitive_pattern` を 5 件にする（旧案は「quality 0.6 以上を 55 件、0.6 未満を 3 件、`sensitive_pattern` を 2 件」）
  - 理由: Logstash の採点（`logstash-configmap.yaml` 213〜233 行目）は、1.0 から始めて 20 文字未満で −0.3、`api_key|password|secret` を含むと −0.8 にする。したがって Logstash を通すと、0.6 未満になるのは `sensitive_pattern` を含むものだけで、20 文字未満でも 0.7 になる。「sensitive ではない 0.6 未満」は Logstash 経由では作れない
  - 品質の境界も見たい場合は、score を指定して ES に直接 bulk で入れる。ただし `logs-serena` のテンプレートは `dynamic: strict` なので、フィールドを Logstash の出力と揃える必要がある
  - `serena_export.py` は `message` が 8 文字未満の行を捨てる（確認済み）。シードの本文は 8 文字以上にする
- 既存の手順どおり `kubectl create job -n vllm --from=cronjob/serena-export serena-export-e2e` で実行する
- 出力先の PVC `vllm-finetune-dataset`（`vllm/overlays/kind/finetune-pvc` にある既存のもの）を読む一時 Pod で、行数と形式を確かめる
- `MARK_EXPORTED=true` で実行し、`serena.exported: true` に更新されたかを確かめる（`serena_export.py` に `mark_exported` が既にある）
- ES 側の NetworkPolicy は既存の `elasticsearch-serena-export-networkpolicy.yaml` を使う

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh serena-export` が exit 0。中で次を確かめる
  - [ ] `kubectl kustomize vllm/overlays/kind/serena-export | yq 'select(.kind=="CronJob").spec.suspend'` が `true`
  - [ ] `kubectl wait --for=condition=complete job/serena-export-e2e -n vllm --timeout=300s`
  - [ ] JSONL がちょうど 55 行（sensitive の 5 件が除かれる）。元の条件「50 行以上」も満たす。`serena_export.py` は最後に `return 0 if exported >= 0 else 1` を返すため、0 件でも exit 0 になる（確認済み）。Job が完了したことだけでは合否にならず、この行数の確認が判定の本体になる
  - [ ] 全行が `jq -e 'has("text") and (.text | length > 0)'` を満たす（`train_lora.py` が読む `{"text": ...}` 形式）
  - [ ] `MARK_EXPORTED=true` のとき、`serena.exported: true` が 55 件
  - [ ] 2 回目の実行の扱いを決めて固定する。現在の `serena_export.py` の検索条件（97〜110 行目）は `serena.exported` で除外して**いない**（確認済み）ので、2 回目も 55 行が出る。重複を避けるなら `must_not` に `{"term": {"serena.exported": true}}` を足して「2 回目は 0 行」を条件にする。足さないなら「2 回目も 55 行」を条件にし、文書にその旨を書く。出力ファイル名は `serena-export-<UTC の日付>.jsonl` で、同じ日に 2 回目を実行すると**上書き**になる（`open(..., "w")`。確認済み）

**CI**: YES。ELK 起動 + Job で 10〜12 分（未測定）。

**実機フォローアップ**: 本番の分量（数万件）での scroll の性能。kubeadm の PVC での永続性。実データでの quality スコアの妥当性（教師データとして使えるかは人が判断する）。

### #18 RAG ログ分析 CLI（Ollama 埋め込み + vLLM chat）

**元の前提と止まっている理由**: Windows の Ollama（`nomic-embed-text`）と GPU の vLLM Teacher、ES の実データが前提。

**k8s での代替**

- Ollama CPU component に `nomic-embed-text` を pull する（埋め込みモデルは CPU でも実用的な速さと見込む。未測定）
- chat 側は 2 通り
  - CI: teacher-stub（既存）を `--vllm` に指定する。応答が固定なので結果が安定する
  - ローカル: Ollama CPU の `qwen2.5:0.5b` を `--ollama-model` に指定する
- `scripts/serena-rag-query.py`（既存）を Job として kind 内で動かす（`--es-url http://elasticsearch.elk-stack:9200 --ollama http://ollama.llm:11434`）。ES の NetworkPolicy があるので、Job は **elk-stack 名前空間**に置く（1.3 節）
- データは #17 と同じシードに、ERROR / WARNING を session ごとに混ぜたものを使う

**注意（既存実装の性質）**: `serena-rag-query.py` は埋め込みに失敗すると警告を出して**キーワード順位付けに切り替え、処理を続ける**（61〜70 行目付近）。そのため「exit 0 = 埋め込みが動いた」にはならない。テストでは stderr に `falling back to keyword ranking` が**ない**ことを条件にするか、`--require-embeddings` オプションを足す（推奨）。

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh serena-rag` が exit 0。中で次を確かめる
  - [ ] `curl -s http://ollama.llm:11434/api/embeddings -d '{"model":"nomic-embed-text","prompt":"x"}' | jq -e '.embedding | length > 0'`
  - [ ] RAG の Job が完了し、stderr に `falling back to keyword ranking` が出ない（または `--require-embeddings` 付きで exit 0）
  - [ ] 出力の Sources 節（`N. session_id=... score=...` の行。253 行目付近で決まった形で出力される）に、シードで入れた ERROR の `session_id` が 1 つ以上ある
  - [ ] teacher-stub を chat に使った回で、要約の本文が空でなく、stderr に `vLLM chat failed` が**出ない**。`generate_summary` は vLLM が失敗すると Ollama の chat に切り替える（206〜211 行目。確認済み）。そのため、本文が空でないことだけでは teacher-stub を通った証明にならない
- [ ] 陰性テスト: Ollama の Service を消した状態で `--require-embeddings` を付けると exit が 0 以外になる
- [ ] `docs/design/elk-stack-serena-logs-llm.md` の RAG 節に kind での実行例がある（`grep -q 'run.sh serena-rag'`）

**CI**: YES。ELK + Ollama（nomic-embed-text は約 270MB と認識している。未確認）で 15〜20 分。Ollama のモデルは PVC に入れても CI では毎回消えるので、`actions/cache` でモデルのディレクトリを保存するかを検討する。

**実機フォローアップ**: 本物の vLLM Teacher（GPU）での回答の質。LLM の本文に session_id の引用が入るかどうか（小型モデルや stub では判定できない）。回答の質は人が評価する。

### #19 MetalLB / 外部 LB による controlPlaneEndpoint

**元の前提と止まっている理由**: ベアメタル LAN の VIP（`ipaddresspool.yaml` は `192.168.1.240-250` で固定）と、keepalived/haproxy の実機。なお成果物は既にある（`kubeadm/addons/metallb/`、`kubeadm/scripts/00-configure-lb.sh`、`kubeadm/docs/load-balancer-external.md`、`apply-addons.sh --with-metallb`。すべて確認済み）。止まっているのは**動作確認**。

**k8s での代替**

- **MetalLB（Option B）**: kind の Docker ネットワーク `kind` のサブネット（`docker network inspect kind` で取得。例: 172.18.0.0/16）の末尾の範囲（例: `.255.200-.255.250`）を IPAddressPool にする。新規 `kind/addons/metallb/` は `kubeadm/addons/metallb` を resources に取り、プールを patch する。CI でサブネットが変わる場合に備えて、`run.sh` で値を求めて `kustomize edit` か envsubst で差し込む
  - 注意: `kubeadm/addons/metallb` は、native manifest（CRD と webhook）と `IPAddressPool` を 1 つの kustomization にまとめている。1 回の `apply -k` で入れると、CRD と webhook の準備ができる前に CR が拒否されうる。既存の `kubeadm/addons/apply-addons.sh` も、待ってから確認している。lib では「manifest → webhook の Ready を待つ → pool」の 2 段階で入れる
  - 注意: kind は control-plane ノードに `node.kubernetes.io/exclude-from-external-load-balancers` ラベルを付ける。MetalLB の speaker はこのノードから広告しない。worker があれば問題ない（`test-cluster.yaml` は worker 2 台）
- **controlPlaneEndpoint の検査（Option A の代わり）**: `test-cluster-ha.yaml` で作ると、kind は haproxy の LB コンテナ（`<cluster>-external-load-balancer`）を自動で作る。このコンテナの IP を `CONTROL_PLANE_DNS` にして、`00-configure-lb.sh --check-api` を kind ネットワーク上のコンテナから実行する
  - 既存スクリプトの問題点: `--check-api` は届かなくても `warn` を出すだけで **exit 0 で終わる**（確認済み）。またポートは 6443 に固定されている。テストで判定できるように、`--strict`（届かなければ exit 1）と `CONTROL_PLANE_PORT` を足す変更を提案する
- haproxy + keepalived の構成（Option A）そのものは kind では作らない。VIP の切り替わり（VRRP）は Docker の bridge 上では検証の意味が薄いため

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh metallb-l2` が exit 0。中で次を確かめる
  - [ ] `kubectl wait -n metallb-system --for=condition=Available deploy/controller --timeout=180s` と、speaker DaemonSet が全ノードで Ready
  - [ ] `type: LoadBalancer` の nginx Service に、プール内の `status.loadBalancer.ingress[0].ip` が 60 秒以内に割り当てられる
  - [ ] `docker run --rm --network kind curlimages/curl -s -o /dev/null -w '%{http_code}' http://<IP>/` が `200`
  - [ ] プールの外の IP を `spec.loadBalancerIP`（または MetalLB のアノテーション）で要求すると、割り当てられない（陰性テスト）
- [ ] `CONTROL_PLANE_IP=<cp1 の IP> CONTROL_PLANE_DNS=<LB の IP> ./kubeadm/scripts/00-configure-lb.sh --check-api --strict` が kind ネットワーク上のコンテナで exit 0。存在しない IP では exit 1
- [ ] `kind/addons/metallb` が `kubectl kustomize` でビルドでき、kubeconform を通る。`scripts/kubeconform-validate.sh` は `kustomization.yaml` を自動で探すので（確認済み）、ディレクトリを置けば自動で対象になる。「対象一覧を grep する」は意味のない条件なので、この形に改めた。リポジトリに置く IPAddressPool は、プレースホルダの状態でも有効な IP 範囲にしておく

**CI**: YES。HA クラスタの作成（3 CP で数分）+ MetalLB で 10 分前後（未測定）。Linux ランナーではホストから直接 IP に届くが、スクリプトは kind ネットワーク上のコンテナから確かめる形に揃える。

**実機フォローアップ**: 実 LAN での L2 の ARP 広告（スイッチ、DHCP の範囲との衝突）、keepalived の VIP 切り替え、ノードの外のクライアントからの到達。

### #20 HA control-plane（3 ノード stacked etcd）

**元の前提と止まっている理由**: 実機の CP 3 台。成果物（`kubeadm/scripts/03b-join-control-plane.sh`、`kubeadm/docs/ha-control-plane.md`）は既にある。止まっているのは「全 CP Ready、etcd メンバー 3」の確認。

**k8s での代替**

- `kind/test-cluster-ha.yaml`（3 control-plane + 2 worker）。kind は stacked etcd の HA を作り、前段に haproxy の LB を自動で置く
- 確かめること: ノード、etcd メンバー、1 台の CP を止めたときの API の継続
- **限界**: kind は自分で kubeadm を呼んで join するので、`03b-join-control-plane.sh` は**通らない**。このスクリプトについては、既存の `scripts/test-kubeadm-bootstrap.sh` と同じやり方（`bash -n`、引数の解析、`--help`、`--dry-run` の出力）で静的テストする。03b には現在 dry-run がない（確認済み）ので、`--dry-run`（実行する `kubeadm join` コマンドを表示して終わる）を足すことを提案する。**注意**: 03b は引数を解析する前の 15 行目で `require_root` を呼ぶため、root ではない CI では `--help` も die する（確認済み）。`require_root` は `--join` と `--config` の分岐の中に移す。なお `bash -n` は、既存の `test-kubeadm-bootstrap.sh` が `kubeadm/*.sh` の全体に対して既に行っている。既存の `--print-command` は、コマンドを表示せずに使い方を表示するだけである

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh ha-control-plane` が exit 0。中で次を確かめる
  - [ ] `kubectl wait --for=condition=Ready node -l node-role.kubernetes.io/control-plane --timeout=300s` で 3 台が Ready
  - [ ] `kubectl -n kube-system exec etcd-<cp1> -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list -w json | jq '.members | length'` が 3
  - [ ] `docker pause <cluster>-control-plane2` のあと、LB 経由で `kubectl get --raw /readyz` が 60 秒以内に `ok` を返し、新しい ConfigMap を作れる（書き込みも通る = etcd の過半数が残っている）
  - [ ] 2 台目も止めると、`kubectl --request-timeout=15s create configmap ...` が失敗する（過半数を失う。陰性テスト。タイムアウトを指定しないと、失敗するまで長く待つ）。そのあと `docker unpause` で 2 台を戻すと、5 分以内に 3 台 Ready に戻る
  - 注: `docker stop` / `start` ではなく `pause` / `unpause` を使う。kind は HA クラスタのノードコンテナの再起動を正式にはサポートしておらず、再起動でコンテナ IP が変わると etcd や証明書が壊れることがある（kind の既知の制約として扱う。**未検証**）。pause なら IP は変わらない。ただし pause はプロセスの凍結であり、ネットワーク断の模擬にはならない
- [ ] `bash scripts/test-kubeadm-bootstrap.sh` 相当の静的テストに 03b を加えたものが exit 0（`--help` と `--dry-run`）

**CI**: YES。3 CP + 2 worker は 4 vCPU / 16 GB のランナーで作れる見込み（kind の HA は数分かかる。未測定）。止める・戻すを入れて 12〜15 分。#19 と同じクラスタでスイートを続けて回すと作成時間を節約できる。

**実機フォローアップ**: `03b-join-control-plane.sh` で実際に join する手順、`--upload-certs` の証明書キーの期限（2 時間）を含む運用、実機の電源断や NIC 障害、#19 の実 LB との組み合わせ。

### #23 Longhorn ストレージ overlay

**元の前提と止まっている理由**: worker 3 台以上、各ノードに `open-iscsi`（iscsid と `iscsi_tcp` カーネルモジュール）、本番 HA。成果物（`kubeadm/addons/longhorn/`。v1.7.2 に固定、`apply-addons.sh --with-longhorn`、`vllm/overlays/kubeadm/longhorn-storage-patch.yaml`）は既にある。

**kind での制約（正直な評価）**

- Longhorn v1 のデータエンジンはノードに iSCSI のイニシエータが必要。kindest/node のイメージには `iscsiadm` が入っていない（と認識している。未確認）。ノードのコンテナに apt で入れられても、`iscsi_tcp` はホストのカーネルにある必要がある
- ローカルの Docker Desktop（WSL2 カーネル `6.18.40.1-microsoft-standard-WSL2`）に `iscsi_tcp` があるかは**未確認**。ないと考えておくのが安全
- GitHub の ubuntu-latest は通常の Ubuntu カーネルなので `modprobe iscsi_tcp` はできる見込み。ただし Longhorn がネストしたコンテナの中で動くか（mount propagation、`/dev` の扱い）は**未確認**
- よって kind 上の Longhorn の動作は**受け入れ条件にせず、時間を区切った spike** とする

**k8s での代替**

1. **静的検証**（すぐできる）: `kubeadm/addons/longhorn` と、longhorn パッチを有効にした vLLM kubeadm overlay を kustomize build + kubeconform にかける。既存の `vllm/overlays/kubeadm/kustomization.yaml` ではパッチがコメントアウトされている（16〜17 行目。確認済み）ので、`vllm/overlays/kubeadm/longhorn/`（パッチを有効にした overlay）を新しく作り、検証の対象にする
2. **PVC 契約テスト**（kind の local-path で実施）: 新規 `scripts/e2e/suites/storage-pvc-contract.sh`。`STORAGE_CLASS` を引数にとる。書き込み → Pod 削除 → 再作成 → 読み出しで一致、を確かめる。kind では `standard`（local-path）で回し、実機では `STORAGE_CLASS=longhorn` で**同じスクリプト**を回す。vLLM のモデルキャッシュ PVC（`vllm-model-cache`）の要求（サイズ、accessMode）が StorageClass を変えても満たせるかも確かめる
3. **Longhorn spike**（nightly、`continue-on-error: true`）: ubuntu-latest でホストに `open-iscsi` を入れて `modprobe iscsi_tcp`、各 kind ノードに `docker exec ... apt-get install -y open-iscsi` を行い、Longhorn を適用する。`longhorn-manager` の DaemonSet が Ready になり、PVC が Bound になるかを記録する。成功しても**本番の判断材料にはしない**（レプリカ 3 の意味が Docker 上のノードでは薄いため）

**kind 受け入れ条件**

- [ ] `scripts/kubeconform-validate.sh` が `kubeadm/addons/longhorn` と `vllm/overlays/kubeadm/longhorn` を含めて exit 0
- [ ] `kubectl kustomize vllm/overlays/kubeadm/longhorn | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="vllm-model-cache").spec.storageClassName'` が `longhorn`
- [ ] `STORAGE_CLASS=standard ./scripts/e2e/run.sh storage-pvc-contract` が exit 0（書き込み → 再スケジュール → 読み出しで sha256 が一致）
- [ ] `vllm/overlays/kubeadm/README.md` に local-path と longhorn の選択表、worker 3 台以上の注記がある（grep で確認）
- [ ] （spike。合否に含めない）結果を `e2e-results/longhorn-spike.json` に `{iscsi_module, manager_ready, pvc_bound}` として残す

**CI**: 静的検証と PVC 契約テストは YES（5〜8 分）。Longhorn spike は実験扱いで nightly のみ、20〜30 分（未測定）。

**実機フォローアップ**: Longhorn の主目的（レプリカ 3 によるノード障害への耐性、ノードを落としたときのボリューム再接続、性能）は**実機でしか検証できない**。`STORAGE_CLASS=longhorn` で PVC 契約テストを実機で回すことを実機チェックリストに入れる。

### #28 AMD Adrenalin ドライバの更新（RX 5700）

**元の前提**: Windows の Ollama が「AMD driver is too old」で CPU に落ちる。ドライバの更新を案内する。

**判定: k8s 再設計の対象外。クローズを推奨**

- Windows ホストのドライバの問題で、k8s（kind を含む）とは関係がない
- 既存 `scripts/update-adrenalin-gpu.ps1` の冒頭コメントには「RDNA1 の最新ドライバは 32.0.21043.12001 で、それより新しいビルドは RDNA3/4 向け。RX 5700 では Ollama の Vulkan バックエンドが正しい経路で、実測で 100% GPU オフロードを確認」と書かれている。この内容が正しければ、issue の前提（ドライバを更新すれば直る）は成り立たない。スクリプトの記述どおりに解決済みなら、そのことを書いてクローズする。未解決なら `needs-hardware` の Windows 作業として残す
- この判断はスクリプトのコメントだけに基づいている。**実機で Ollama のログに Vulkan0 が出るかは確かめていない**

### #30 WSL 単一ノード kubeadm での CoreDNS / Calico の不安定

**元の前提と止まっている理由**: WSL 上の kubeadm 単一ノード（`~/.kube/config-kubeadm-wsl`）でしか再現しない前提。根本原因（kube-system に当てた全体の `allow-dns-egress` が、CoreDNS と calico-kube-controllers から API への通信を止めていた）は `kubeadm/docs/cluster-dns-troubleshooting.md` に記録済みで、修正は commit `4dfc38f` で入っている。診断スクリプト `kubeadm/scripts/diagnose-cluster-dns.sh` もある。止まっているのは、**修正が効いていることを繰り返し確かめる手段**がないこと。

**k8s での代替**

- `kind/test-cluster-calico.yaml`: `networking.disableDefaultCNI: true`、`podSubnet: 192.168.0.0/16`（`kubeadm/kubeadm-config.yaml` と同じ）。Calico は `kubeadm/scripts/05-install-cni.sh` と同じ `v3.27.3` の manifest を入れる
- 既存 `kubeadm/addons/network-policies/` を適用する。このポリシーは `argocd`、`ingress-nginx`、`longhorn-system`、`kube-system` を対象にしている（確認済み）。kind にはこのうち 3 つの名前空間がないので、先に作る
- 確かめること: CoreDNS が Ready、kube-dns の Endpoints がある、テスト Pod から `kubernetes.default.svc` が引けて `https://10.96.0.1:443` に届く、calico-kube-controllers が Running
- **陰性テスト（反証）**: 修正前の**ポリシー一式**に置き換え、同じテストが**失敗する**ことを確かめる。これで「このテストは原因を検出できる」ことを示す
  - 手順: `git archive 4dfc38f^ kubeadm/addons/network-policies` を展開して `kubectl apply -k` する。そのうえで、修正で追加された `allow-kube-system-addon-egress.yaml` の 3 ポリシー（`allow-coredns-egress`、`allow-calico-controllers-egress`、`allow-calico-node-egress`）を**削除**する
  - 理由: NetworkPolicy は許可の和集合である。旧 `allow-dns.yaml` だけを上から当てても、`egress: {}` の addon 用ポリシーが残っているので**失敗しない**。4dfc38f の差分は、allow-dns.yaml から kube-system の節を消し、addon-egress を足したものである（`git show` で確認済み）
  - 観測対象は **kube-system の中の Pod** にする。旧ポリシーは kube-system の `podSelector: {}` に効くので、default 名前空間の一時 Pod から API への curl は旧ポリシーの下でも成功してしまう
  - CoreDNS の `ready` は起動時に API と同期したかを見る。既に Ready の Pod は、API を失っても NotReady に戻らない可能性がある（**未検証**）。そこで CoreDNS を `rollout restart` し、新しい Pod が Ready にならないことで判定する
- `diagnose-cluster-dns.sh` を kind に対して実行し、exit 0 になることを確かめる（KUBECONFIG を環境変数で渡せる作りになっている）

**kind 受け入れ条件**

- [ ] `./scripts/e2e/run.sh calico-netpol-dns` が exit 0。中で次を確かめる
  - [ ] `kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=kube-dns --timeout=180s`
  - [ ] `kubectl get endpointslices -n kube-system -l kubernetes.io/service-name=kube-dns -o json | jq -e '[.items[].endpoints[]] | length >= 1'`
  - [ ] network-policies を適用したあと、一時 Pod で `nslookup kubernetes.default.svc.cluster.local` が成功し、`curl -sk -o /dev/null -w '%{http_code}' https://10.96.0.1:443/version` が `200` か `401` か `403`（届いていればよい）
  - [ ] `kubectl -n kube-system get deploy calico-kube-controllers -o jsonpath='{.status.readyReplicas}'` が 1
  - [ ] 陰性テスト: 旧ポリシー一式（addon-egress は削除）を当てると、kube-system の一時 Pod から API への curl がタイムアウトし、`rollout restart` した CoreDNS が 120 秒以内に Ready にならない。現行の一式に戻すと回復する
- [ ] `kind get kubeconfig --name <cluster> > "$tmp"` で書き出し、`KUBECONFIG="$tmp" ./kubeadm/scripts/diagnose-cluster-dns.sh` を実行して、出力を artifact に残す。`kind get kubeconfig-path` は kind v0.6 で廃止済みなので使わない
  - **exit 0 は合否に使わない**。このスクリプトが非 0 になるのは `kubectl get nodes` が失敗したときだけで、Endpoints がないときも CoreDNS が Ready でないときも `warn` を出すだけである（確認済み）。合否に使うなら、warn で exit 1 にする `--strict` を先に足す

**CI**: YES。Calico の導入を含めて 10〜12 分（未測定）。

**実機フォローアップ**: WSL 固有の要因（WSL の NAT、`/etc/resolv.conf` の自動生成、Windows 再起動のあとの IP の変化、kubelet の復旧。既存の `kubeadm/scripts/recover-wsl-kubelet.sh` の領域）は kind では再現できない。根本原因が NetworkPolicy だけなら kind で十分だが、WSL 固有の要因が他にもあったかは、この文書では判断できない。

## 4. 前提として置いた仮定

1. ~~kind のバージョンは v0.24 以上~~ → **解消**。ローカルは v0.33.0（実測）で、kindnet の NetworkPolicy は v0.24.0 から入っている（リリースノートで確認）。その結果、#14 #15 #17 #18 のテスト用 Pod は、既存の Logstash / ES の NetworkPolicy に**阻まれる**。許可ポリシーを置くか、Pod の名前空間を合わせることが前提になる。CI でも kind の版を固定する（`helm/kind-action` の `version`）
2. **GitHub の ubuntu-latest（公開リポジトリ）は 4 vCPU / 16 GB / 空き 14 GB 程度**。ELK + Ollama を同時に動かす #18 が最も重く、ここが足りない場合はスイートを分けるか、ELK を ES だけにする
3. **Ollama CPU で 0.5B〜1.5B 級と nomic-embed-text が CI の時間内に動く**。モデルの取得（数百 MB〜1 GB 程度）が毎回入る前提で時間を見積もった
4. **ELK on kind は既存の `elk-stack/overlays/kind` でそのまま起動する**。`docs/DISTILL_VERIFICATION.md`（2026-06-11）の実績に頼っている。ES の hostPath PV（`/data/elasticsearch`、`local-storage`）は複数ノードの kind で Pod がどのノードに乗っても動く、と仮定した
5. **CI で数値の大小は判定しない**。ベンチの数値は記録だけにし、合否は形式と経路で決める
6. **Kibana の目視を ES の照会で代えてよい**（#15）

## 5. 未確認の事項

| 項目 | 関係する issue | 確かめ方 |
|------|---------------|---------|
| `openeuler/vllm-cpu:0.20.1-oe2403sp3` に x86_64 版があるか、`--dtype float16` が x86 CPU で動くか | #9 #10 | `docker manifest inspect`、kind で起動して試す |
| ~~`bench_vllm.py` の起動待ちが Ollama で通るか~~ → 解消。`/v1` で終わる URL では `/api/tags` を叩く（確認済み） | #9 #10 | - |
| kind の HA のノードを pause / unpause したあとに復旧するか（stop / start は非対応の可能性がある） | #20 | spike で 3 回繰り返す |
| CoreDNS が Ready のまま API を失ったときに NotReady へ戻るか | #30 | 陰性テストの初回実行で観測する |
| Logstash 9.x の HTTP 400 のログ表記 | #14 | わざと strict 違反のイベントを送る |
| kindest/node に `iscsiadm` があるか、WSL2 カーネルと ubuntu-latest に `iscsi_tcp` があるか | #23 | `docker exec <node> which iscsiadm`、`modprobe -n iscsi_tcp` |
| kind の既定 StorageClass `standard` と、`kind/addons` が入れる local-path が衝突しないか | #17 #23 | `kubectl get sc` で既定が 2 つにならないか確かめる |
| ubuntu-latest の実際の資源と、ELK + Ollama のイメージの合計サイズ | 全体 | 最初の CI 実行で `nproc`、`free -g`、`df -h` を出す |
| 各スイートの実際の所要時間 | 全体 | この文書の分数はすべて推定。初回の実測で置き換える |
| `update-adrenalin-gpu.ps1` のコメント（RX 5700 は Vulkan で GPU 推論できる）が実機で正しいか | #28 #11 | Windows で Ollama のログを見る（実機作業） |

## 6. issue 運用への提案

- 部分的に可の issue（#9 #10 #15 #19 #20 #23 #30）は、本文の受け入れ条件を「kind 受け入れ条件」と「実機フォローアップ」に分ける。実機分は `needs-hardware` ラベルの子 issue に移し、親は kind の条件を満たしたらクローズできるようにする
- 対象外の issue（#11 #28）は、上の理由を書いてクローズするか、`needs-hardware` の Windows 作業 1 件にまとめる
- ハーネス（2 節の順 0）は独立した issue にして最初に入れる。各スイートはそれぞれの issue の PR に入れる

## 反証レビュー記録

レビュー担当: Red Team Reviewer。レビュー日: 2026-10-05。方法: 設計書が「既存」「確認済み」とした主張を、grep、Read、`git show` でソースと突き合わせた。kind の仕様はリリースノートとローカル実測で確かめた。

| # | 重大度 | 指摘 | 根拠 | 対応 |
|---|-------|------|------|------|
| R1 | 高 | #30 の陰性テストが原因を検出できない。旧 `allow-dns.yaml` だけを適用しても、現行の `allow-kube-system-addon-egress.yaml`（`egress: {}`）が残るので CoreDNS も Calico も遮断されない | NetworkPolicy は許可の和集合。`git show 4dfc38f` の差分は、allow-dns の kube-system の節を削除し、addon-egress を追加したもの | 修正済み（旧ポリシー一式を適用し、addon-egress を削除する手順にした） |
| R2 | 高 | #30 の陰性テストで、観測する Pod の名前空間が誤っている。default 名前空間の一時 Pod は旧ポリシーの対象外なので、API への curl は常に成功する。CoreDNS は、Ready になったあとに API を失っても NotReady に戻らない可能性がある | 旧ポリシーは `namespace: kube-system` の `podSelector: {}` に効く | 修正済み（kube-system の Pod で観測し、CoreDNS を rollout restart して判定する）。CoreDNS の挙動は未検証として明記した |
| R3 | 高 | `diagnose-cluster-dns.sh` は、問題があっても exit 0 になる（偽陽性）。また `kind get kubeconfig-path` は存在しない | スクリプトの末尾は `warn` だけで、`die` するのは `kubectl get nodes` が失敗したときだけ。kubeconfig-path は kind v0.6 で廃止され、ローカルは v0.33.0 | 修正済み（exit 0 を合否から外し、`--strict` を提案した。`kind get kubeconfig --name` に置き換えた） |
| R4 | 高 | #17 のシードの配分「0.6 未満を 3 件（sensitive 以外）」は、Logstash 経由では作れない | Logstash の採点では、20 文字未満でも 0.7 になり、0.6 未満になるのは `sensitive_pattern`（−0.8）を含むものだけ | 修正済み（通常 55 件、sensitive 5 件にした。直接 bulk する案と、その場合の strict テンプレートの注意も残した） |
| R5 | 高 | #9 の「失敗した候補を `status: "failed"` と記録し、`CONTINUE_ON_ERROR=true` で exit 0」は、既存の挙動と矛盾する。#10 の `status: "oom"` も既存にない機能 | `compare_models.sh` は失敗した候補の JSON を書かず、`FAILED>0` なら最後に exit 1 | 修正済み（新規の改修であると明記した。#10 の OOM 経路は MVP では削ってよいとした） |
| R6 | 高 | kindnet の NetworkPolicy を「効かなくても結果は変わらない」としていたが、実際には効く。Logstash の 5000 番と ES の 9200 番は既存のポリシーで絞られており、テスト用 Pod や RAG Job からの通信は遮断される | kind v0.24.0 のリリースノートに、kube-network-policies による NetworkPolicy 対応がある。ローカルの kind は v0.33.0。`logstash-allow-distill-ingest` と `elasticsearch-allow-serena-export` の内容 | 修正済み（1.3 節、#14、#18、4 節。許可ポリシーの追加か、elk-stack 名前空間での実行を必須にした） |
| R7 | 中 | #18 で「要約の本文が空でない」だけを見ると偽陽性になる。vLLM（teacher-stub）が失敗すると Ollama の chat にフォールバックする | `serena-rag-query.py` の 206〜211 行目 | 修正済み（stderr に `vLLM chat failed` がないことを条件に加えた） |
| R8 | 中 | #14 の PII の確認が「含まれない」だけになっている。また、パスのマスクは Windows 形式だけが対象 | gsub の正規表現は `[A-Za-z]:\Users\...` | 修正済み（`[EMAIL]` と `[USER_HOME]` が含まれることも確かめ、シードは Windows 形式のパスにした） |
| R9 | 中 | #14 の `grep -c 'status=>400'` の表記が未検証で、常に 0 件の偽陽性になりうる | Logstash 9.x のログ形式を確かめていない | 未検証として明記した（初回に、わざと 400 を起こして固定する） |
| R10 | 中 | #15 の「重複も欠落もない」は、Logstash を再起動する段階では保証できない | collector は `sendall` が成功したら送信済みとみなす（at-most-once） | 修正済み（件数の一致は再起動しない段階に限定した） |
| R11 | 中 | #15 の Task Scheduler の README 条件は、既に満たされていて常に通る | README の 70 行目に `## Task Scheduler 登録` がある | 修正済み（受け入れ条件から削除した） |
| R12 | 中 | #20 の `docker stop` / `start` による復旧は、kind の HA では不安定になりうる。また 2 台停止時の書き込み失敗は、タイムアウトを指定しないと長く待つ | kind は HA ノードの再起動を正式にサポートしていない（IP が変わる） | 修正済み（`pause` / `unpause` と `--request-timeout=15s` にした）。復旧の可否は未検証として 5 節に追加した |
| R13 | 中 | #20 の 03b の静的テストで、`--help` が root ではない CI で失敗する | 15 行目の `require_root` が引数解析より前にある | 修正済み（`require_root` を分岐の中に移す改修を明記した） |
| R14 | 低 | #19 の「kubeconform の対象一覧を grep」は意味がない | `kubeconform-validate.sh` は `kustomization.yaml` を自動で探す | 修正済み（ビルドできることと、プレースホルダの IP が有効であることを条件にした） |
| R15 | 低 | MetalLB の CRD と CR を 1 回の apply で入れると失敗しうる | `kubeadm/addons/metallb/kustomization.yaml` が両方を含む | 修正済み（2 段階で適用すると明記した） |
| R16 | 低 | `bench_vllm.py` のヘルスチェックを「未確認」としていたが、既に Ollama に対応している | `wait_for_health` は `/v1` で終わる URL では `/api/tags` を叩く | 修正済み（確認済みにし、5 節から外した） |
| R17 | 低 | #17 の 2 回目の実行は、同じ日なら出力ファイルの上書きになる。`serena_export.py` は 0 件でも exit 0 | 出力ファイル名に日付を含み、`open(...,"w")` で開く。最後は `return 0 if exported >= 0` | 修正済み（追記した） |

### 事実確認で正しかった主張（反論して維持）

- `00-configure-lb.sh --check-api` が、届かなくても warn だけで exit 0 になり、ポートが 6443 に固定されていること。`serena_export.py` の検索条件が `serena.exported` で除外していないこと。`logstash-distill-networkpolicy.yaml` の許可範囲（vllm 名前空間かつ `app=distill-collector`）。`vllm/overlays/kubeadm/kustomization.yaml` の 16〜17 行目の longhorn パッチがコメントアウトされていること。Calico v3.27.3 と podSubnet 192.168.0.0/16。`update-adrenalin-gpu.ps1` の冒頭コメントの内容。リポジトリに Makefile も Ollama の Deployment もないこと。いずれも記述どおりだった
- kind の HA（3 CP と haproxy の `external-load-balancer` の自動作成）、Calico に `disableDefaultCNI` が必要なこと、Docker Desktop のホストからコンテナ IP に届かないこと、Longhorn v1 に iSCSI が必要なこと、公開リポジトリの ubuntu-latest が 4 vCPU / 16 GB / SSD 14 GB であること、nomic-embed-text が約 270MB であること。いずれも妥当と判断した
- etcd の quorum（3 台中 1 台停止で継続、2 台停止で書き込み不可）。原理として正しい。ただし R12 のとおり、手段を pause に変えた
- #11 と #28 を「対象外・クローズ推奨」とした判定。妥当なので維持する。補足として、#28 の受け入れ条件 1〜2（ドライバの検出スクリプトと文書）は、既存の `update-adrenalin-gpu.ps1` で満たされている可能性がある。クローズのコメントに対応表を書くとよい。#11 の AMD overlay（`vllm/overlays/kubeadm/amd/`）の kustomize の静的検証は、既存の kubeconform-validate.sh の自動探索で既にカバーされている。k8s で検証できる部分の見落としはない

### スコープ過大の指摘（MVP で削れる部分）

- #10: 擬似 OOM の経路（`compare_models.sh` に status を書く改修が要る）。MVP では外し、LFM2.5-350M の 1 件だけにする
- #19: プール外の IP を要求する陰性テストと、`00-configure-lb.sh --strict` の改修。MetalLB の割り当てと到達性の確認だけで十分
- #23: Longhorn の spike は、受け入れ条件に入らないのに nightly の CI の枠を消費する。手動の `workflow_dispatch` だけにする
- #15: Logstash の再起動テストは不安定になりやすい（R10）。最初の PR から外す
- ハーネス: `e2e-results/<suite>.json` の独自スキーマと `actions/cache` によるモデルのキャッシュは後回しにし、最初は exit code と `dump_on_fail` だけにする
- #9 と #10: vLLM CPU（経路 b）は CI に入れない。spike の結果が出るまで、文書には「ローカル任意」とだけ書く

### 残った論点

- CoreDNS が Ready になったあとに API を失ったときの挙動（R2）、kind の HA の pause 後の復旧（R12）、Logstash 9.x の 400 のログ表記（R9）、ES の hostPath PV（`/data/elasticsearch`）を複数ノードの kind で使ったときの権限（4 節の仮定 4）。いずれも初回の実行でしか確かめられない
- #18 の Sources 節の判定は、シードが 60 件程度で `--search-size` の既定が 50 だと、埋め込みがなくても ERROR の session が上位に来やすく、判別力が弱い。シードに、クエリと無関係な INFO を増やすことを推奨する（未反映）
