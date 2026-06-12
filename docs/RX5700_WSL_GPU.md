# AMD Radeon RX 5700 (gfx1010 / RDNA1) と WSL2 GPU

調査日: 2026-06-11  
環境: Windows 11 + WSL2 Ubuntu 24.04, RX 5700, ドライバ `32.0.21043.12001`

## 結論（正直な判定）

**RX 5700 を WSL2 内で ROCm 計算 GPU として使う公式・実用的な経路は現時点では存在しません。**

| 層 | 状態 | 意味 |
|---|---|---|
| `/dev/dxg` | 存在する | WSL の GPU パラバーチャル化は有効 |
| `/dev/kfd`, `/dev/dri` | **存在しない** | Windows が compute アダプタを公開していない |
| `rocminfo` | `No WDDM adapters found` | WSL ROCm ランタイムが GPU を検出できない |
| `HSA_OVERRIDE_GFX_VERSION` | **無効** | WDDM アダプタが無い段階では gfx 偽装も効かない |
| `hsa-runtime-rocr4wsl-amdgpu` | インストール済みでも無意味 | Linux 側パッケージだけではアダプタは出ない |

**推奨経路:** Windows ネイティブ **Ollama**（**Vulkan バックエンド**）→ WSL/K8s から HTTP ブリッジ。  
手順: [LOCAL_GPU_SETUP_WINDOWS.md](LOCAL_GPU_SETUP_WINDOWS.md)、`scripts/setup-ollama-rx5700.ps1`。GPU 経路の詳細は後述「[2026-06-12 追記](#2026-06-12-追記-windows-側-gpu-経路の確定事実rdna1--vulkan)」参照。

ベアメタル Linux なら `HSA_OVERRIDE_GFX_VERSION=10.3.0` でコミュニティ運用は可能（非公式・不安定）。WSL とは別問題です。

---

## 公式サポートマトリクス

AMD ROCm 7.2.1 WSL の [GPU support matrix](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/wsl/wsl_compatibility.html) は **RDNA3 以降の特定 SKU のみ**（RX 7900/7700/9000 系など）。**RX 5700 / gfx1010 / RDNA1 は含まれない。**

ROCm 7.2.1 以降、WSL ではレガシー `roc4wsl` パッケージの代わりに **ROCDXG (librocdxg)** が本番経路だが、**対象ハードは同じマトリクスに拘束される**（[WSL How-to](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installrad/wsl/howto_wsl.html)）。

> 注: ROCm の WSL サポート対象は将来拡大しうるため、ROCm メジャーリリース時に本制約を再評価すること。

---

## 実機で試したことと結果

自動再現:

```bash
./scripts/try-rx5700-wsl-gpu-experimental.sh
./scripts/diagnose-wsl-gpu.sh
```

### 1. デバイスノード

```
/dev/dxg   OK
/dev/kfd   MISSING
/dev/dri   MISSING
```

### 2. dmesg（dxgk ioctl 失敗）

```
misc dxg: dxgk: dxgkio_is_feature_enabled: Ioctl failed: -22
misc dxg: dxgk: dxgkio_query_adapter_info: Ioctl failed: -22
```

`-22` (EINVAL) は Windows 側が WSL に **compute 用 WDDM アダプタ情報を返さない** ときの典型パターン。

### 3. ROCm パッケージ

- `hsa-runtime-rocr4wsl-amdgpu` — インストール済み（ROCm 7.2 WSL スタック）
- `rocminfo` — `No WDDM adapters found` / `hsa_init Failed`
- `amd-smi` — `Unable to detect any GPU devices`（WSL では amdgpu モジュール非使用のため想定内）

### 4. HSA_OVERRIDE_GFX_VERSION

| 値 | 結果 |
|---|---|
| `10.3.0` | 変化なし（No WDDM adapters） |
| `10.1.0` | 同上 |
| `9.0.6` | 同上 |

この環境変数は **アダプタ検出後の gfx ターゲット偽装**用。WSL でアダプタ自体が無い場合は無効。

### 5. Windows ドライバ

- 検出: `AMD Radeon RX 5700`, `32.0.21043.12001`
- WSL ROCm 7.2 が要求する **「Adrenalin Edition for WSL2」**（例: 26.1.1 系）とは別系統の表示ドライバの可能性が高い
- 仮に WSL 用ドライバを入れても、**RX 5700 はマトリクス外のため compute アダプタは公開されない**と判断（コミュニティでも RX 5700 で `/dev/kfd` 成功例なし）
- **2026-06-12 訂正:** `32.0.21043.12001` は「古い」のではなく **RDNA1 向け最新ドライバそのもの**。詳細は次節。

### 6. GPU compute vs パラバーチャル化

| 機能 | RX 5700 での状態 |
|---|---|
| WSL GPU パラバーチャル化 (`/dev/dxg`) | 有効 |
| DirectX / 一部グラフィックス API | Windows ドライバ経由で可 |
| ROCm / HIP / OpenCL compute (WSL) | **不可**（WDDM compute アダプタなし） |
| `.wslconfig` の `gpuSupport=false` | 無効化すると `/dev/dxg` も消える — 本環境では未設定 |

---

## なぜ Linux ネイティブとは違うのか

| | ベアメタル Linux | WSL2 |
|---|---|---|
| ドライバ | `amdgpu` カーネルモジュール | Windows Adrenalin + dxg ブリッジ |
| デバイス | `/dev/kfd`, `/dev/dri` | 本来 `/dev/dxg`（compute は WDDM 経由） |
| gfx1010 | `HSA_OVERRIDE_GFX_VERSION` で非公式動作報告多数 | **Windows が SKU を許可リスト化** — RX 5700 は対象外 |
| Ollama / vLLM | ROCm ビルド + override | WSL ROCm 非対応 → Windows Ollama 推奨 |

---

## ユーザーが試せること（自己責任・実験的）

完全な成功は期待しないでください。

1. **AMD Software: Adrenalin Edition for WSL2** を [公式手順](https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html) から導入
2. WSL 内: `sudo ./scripts/install-wsl-rocm.sh`
3. **手動で** `wsl --shutdown` → WSL 再起動（全 WSL セッションが閉じる）
4. `./scripts/try-rx5700-wsl-gpu-experimental.sh` で再診断

成功基準: `rocminfo` に Agent が表示される、または `/dev/kfd` が出現。

レガシー ROCm 6.x WSL + 旧 roc4wsl の組み合わせは、ROCm 7.2 の ROCDXG 移行後は非推奨・再現困難。

---

## 2026-06-12 追記: Windows 側 GPU 経路の確定事実（RDNA1 = Vulkan）

実機検証で以下が確定した。**以前の「Adrenalin を build 31000+ に更新せよ」という前提は誤りだったため撤回する。**

### 1. RX 5700 (RDNA1) は HIP7 / build 31000+ に構造的に到達不可能

Adrenalin 26.x は **2 ブランチ構成**:

| ブランチ | 対象 | Driver / WMI 表記 | HIP |
|---|---|---|---|
| variant A | **RDNA1/2** | Driver 25.10.43.12 = WMI `32.0.21043.12001` | HIP6 のみ |
| variant B | RDNA3/4 | build 31019 系（例 `32.0.31019.x`） | **HIP7 同梱** |

現在の `32.0.21043.12001` は **RDNA1 向け最新そのもの**であり正常。RDNA1 に build 31000+ は配布されず、HIP7 (`amdhip64_7.dll`) は永遠に来ない。

### 2. RX 5700 の GPU 経路は Vulkan バックエンド

- Ollama 0.30.x の Windows **フルインストーラ**は `lib\ollama\vulkan\ggml-vulkan.dll` を標準バンドル
- `OLLAMA_VULKAN` は**デフォルト有効**（`0` で無効化）
- 実測: RX 5700 が `Vulkan0` として検出され **100% GPU オフロード（25/25 layers）、~157 tok/s（CPU 比 3.4 倍）**
- 注意: この構成でも `ollama ps` の PROCESSOR 列は「100% CPU」と**誤表示**されることがある。真偽は server.log の `inference compute ... library=Vulkan` と `offloaded N/N layers to GPU` で判定する

### 3. 既知の障害: Ollama 自己アップデートによる Vulkan ディレクトリ欠落

Ollama の自己アップデートが **exe のみ置換し `lib\ollama\vulkan\` を欠落させる**ことがある（実際に発生し CPU フォールバックの真因だった）。

**修復:** 公式 [OllamaSetup.exe](https://ollama.com/download/OllamaSetup.exe) を再実行（`/VERYSILENT` 可）。Adrenalin の更新は不要・無関係。

### 4. ROCm の "AMD driver is too old" 警告について

Ollama の ROCm 検出（amd.go）が出す "AMD driver is too old" は **RDNA1 では恒常的に出るが、Vulkan 経路には無関係**。無視してよい。

診断は `scripts/update-adrenalin-gpu.ps1` で自動化済み（Vulkan DLL 存在 → log の `library=Vulkan` → `ollama ps` + オフロード実績の順に検査）。

### 5. ベンチマーク時の罠: WSL 側 Ollama による 127.0.0.1:11434 横取り

- WSL 側にも古い Ollama（0.24.0 等）が居ると、wslrelay.exe が `127.0.0.1:11434` を横取りして CPU インスタンスに飛ぶことがある。GPU 計測時は `-BaseUrl 'http://[::1]:11434/v1'` を指定するか WSL 側 Ollama を停止する（`scripts/bench_ollama_openai.ps1` のデフォルトは 127.0.0.1）。クラスタ経由（WSL gateway IP）は Windows 側に直達するため影響なし。
- 実測: クラスタ経由 E2E warm 0.33s（CPU 時代 2.33s、約 7 倍）、ローカル p50 681ms（CPU 1273ms）、193.6 tok/s（CPU 87）。

---

## リポジトリ内ツール

| スクリプト | 用途 |
|---|---|
| `scripts/try-rx5700-wsl-gpu-experimental.sh` | 既知の回避策を一括試行し判定 |
| `scripts/diagnose-wsl-gpu.sh` | 一般 WSL AMD GPU 診断（RX 5700 専用ガイダンス付き） |
| `scripts/fix-wsl-gpu-passthrough.ps1` | Windows 側チェック（`wsl --shutdown` は自動実行しない） |
| `scripts/setup-ollama-rx5700.ps1` | **推奨** Windows GPU 推論 |
| `scripts/update-adrenalin-gpu.ps1` | Ollama Vulkan GPU 経路診断（vulkan DLL / server.log / `ollama ps`）。欠落時は OllamaSetup.exe 修復を案内。Adrenalin build 31000+ チェックは RDNA3/4 のみ |

---

## kind クラスタからの利用

kind-dev からは Windows ネイティブ Ollama を `ollama-external.vllm:11434` で利用します。手順・制約（proxy 403 / GPU 化条件など）は [vllm/components/windows-ollama-external/README.md](../vllm/components/windows-ollama-external/README.md) を参照。`vllm/overlays/kind/amd` は適用禁止（永久 Pending — [vllm/README.md](../vllm/README.md) の警告参照）。

---

## 参考リンク

- [WSL support matrices (ROCm 7.2.1)](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/wsl/wsl_compatibility.html)
- [WSL How-to (ROCDXG)](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installrad/wsl/howto_wsl.html)
- [ROCm #3734 — /dev/kfd は WSL では通常無い（7900 XT）](https://github.com/ROCm/ROCm/issues/3734)
- [ROCm #5007 — WSL では amdgpu モジュール不要、amd-smi 制限](https://github.com/ROCm/ROCm/issues/5007)
- [ROCm gfx1010 非公式 Linux 議論](https://github.com/ROCm/ROCm/issues/2527)
