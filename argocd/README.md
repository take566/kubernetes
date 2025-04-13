# Argo CD インストールガイド

このリポジトリには、Helmを使用したArgo CDのインストール手順が含まれています。

## 前提条件

- Kubernetes クラスター
- Helm v3
- kubectl

## インストール手順

1. Argo CDのHelmリポジトリを追加

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

2. Argo CD用のネームスペースを作成

```bash
kubectl create namespace argocd
```

3. Helmを使用してArgo CDをインストール

```bash
helm install argocd argo/argo-cd --namespace argocd
```

4. インストールの確認

```bash
kubectl get pods -n argocd
```

すべてのポッドが`Running`状態になるまで待ちます。

## アクセス方法

### ポートフォワーディングを使用したアクセス

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0
```

ブラウザで http://localhost:8080 にアクセスしてください。

### 初期ログイン情報

- ユーザー名: admin
- パスワード: 以下のコマンドで取得できます

```bash
# Linux/Mac
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Windows (PowerShell)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
```

## 次のステップ

1. UIにログインして初期パスワードを変更する
2. アプリケーションを作成してGitリポジトリと連携する
3. 必要に応じてIngressを設定して外部からアクセスできるようにする

## 参考リンク

- [Argo CD 公式ドキュメント](https://argo-cd.readthedocs.io/)
- [Argo CD Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
