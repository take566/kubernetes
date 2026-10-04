# 補足ドキュメント

ルートの [readme.md](../readme.md) がリポジトリ全体の索引です。以下は個別トピックの詳細ガイドです。

| ドキュメント | 内容 |
|-------------|------|
| [kubeadm-cluster-design.md](kubeadm-cluster-design.md) | kubeadm クラスタ目標アーキテクチャ・Bootstrap・GitOps 設計書 |
| [kubeadm-connect.md](kubeadm-connect.md) | Windows/WSL から kubeadm クラスタへ kubectl 接続 |
| [LOCAL_GPU_SETUP_WINDOWS.md](LOCAL_GPU_SETUP_WINDOWS.md) | Windows ローカル GPU（RX 5700 等）ML スタック構築 |
| [ARGOCD_SETUP.md](ARGOCD_SETUP.md) | Argo CD セットアップ完了後の運用メモ |
| [argocd-helm-install.md](argocd-helm-install.md) | Helm による Argo CD インストール手順（概要） |
| [cert-manager.md](cert-manager.md) | cert-manager Helm インストール |
| [rancher.md](rancher.md) | Rancher Helm インストール |
| [REDESIGN.md](REDESIGN.md) | ゼロベース再設計の分析レポート（参考） |
| [legacy/rancher-install.bat](legacy/rancher-install.bat) | 旧 Windows 用 Rancher セットアップスクリプト（非推奨） |

**GitOps の正:** アプリケーション定義は [argocd/apps/](../argocd/apps/) を参照。Argo CD 本体の手順は [argocd/README.md](../argocd/README.md) を優先してください。

## Claude Code 起動時の自動 pull

Claude Code のセッション開始時（`startup`）に SessionStart フック [.claude/hooks/git-auto-pull.sh](../.claude/hooks/git-auto-pull.sh) が実行されます（設定は [.claude/settings.json](../.claude/settings.json)）。

- 現在のブランチの upstream の remote（無ければ `origin`）を `git fetch --prune` します（タイムアウト 20 秒。オフライン時や認証が必要な場合はプロンプトを出さずに終了）
- 現在のブランチに upstream があり、作業ツリーがクリーンで、ローカルコミットが無い場合のみ `git merge --ff-only --no-overwrite-ignore` で取り込みます（ignored ファイルは上書きしません）
- dirty / diverged / detached HEAD / upstream なしの場合は pull せず、理由を 1 行表示します。セッション開始を妨げないよう常に正常終了します

無効化するには環境変数 `GIT_AUTO_PULL` に `0` / `false` / `no` / `off` のいずれかを設定してから Claude Code を起動してください。
