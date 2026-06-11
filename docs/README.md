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
