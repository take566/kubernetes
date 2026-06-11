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

**推奨経路:** Windows ネイティブ **Ollama**（DirectML）→ WSL/K8s から HTTP ブリッジ。  
手順: [LOCAL_GPU_SETUP_WINDOWS.md](LOCAL_GPU_SETUP_WINDOWS.md)、`scripts/setup-ollama-rx5700.ps1`

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

## リポジトリ内ツール

| スクリプト | 用途 |
|---|---|
| `scripts/try-rx5700-wsl-gpu-experimental.sh` | 既知の回避策を一括試行し判定 |
| `scripts/diagnose-wsl-gpu.sh` | 一般 WSL AMD GPU 診断（RX 5700 専用ガイダンス付き） |
| `scripts/fix-wsl-gpu-passthrough.ps1` | Windows 側チェック（`wsl --shutdown` は自動実行しない） |
| `scripts/setup-ollama-rx5700.ps1` | **推奨** Windows GPU 推論 |
| `scripts/update-adrenalin-gpu.ps1` | Adrenalin ドライバ build（HIP7 / 31000+）検査・更新誘導 |

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
