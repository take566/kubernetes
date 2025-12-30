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

## アプリケーション管理

このリポジトリには、App of Appsパターンを使用したArgoCDアプリケーション管理設定が含まれています。

### アプリケーション構成

`apps/`ディレクトリには以下のアプリケーション定義が含まれています：

- **root-application.yaml**: すべてのアプリケーションを管理するルートアプリケーション（App of Apps）
- **elk-stack-app.yaml**: ELK Stackアプリケーション（ネームスペース: `elk-stack`）
- **prometheus-app.yaml**: Prometheusアプリケーション（ネームスペース: `monitoring`）
- **nginx-app.yaml**: Nginxアプリケーション（ネームスペース: `default`）
- **cert-manager-app.yaml**: Cert-Managerアプリケーション（ネームスペース: `cert-manager`）
- **gitlab-app.yaml**: GitLabアプリケーション（ネームスペース: `gitlab`）

### セットアップ手順

1. GitリポジトリのURLを設定

   各アプリケーションファイル内の`repoURL`を実際のGitリポジトリURLに変更してください：

   ```yaml
   source:
     repoURL: https://github.com/your-org/kubernetes  # 実際のURLに変更
     targetRevision: main  # ブランチ名を確認して変更
   ```

2. GitリポジトリをArgoCDに登録

   ArgoCD UIまたはCLIを使用してGitリポジトリを登録します：

   ```bash
   argocd repo add https://github.com/your-org/kubernetes
   ```

3. ルートアプリケーションをデプロイ

   ```bash
   kubectl apply -f argocd/apps/root-application.yaml -n argocd
   ```

   または、個別のアプリケーションをデプロイする場合：

   ```bash
   kubectl apply -f argocd/apps/elk-stack-app.yaml -n argocd
   kubectl apply -f argocd/apps/prometheus-app.yaml -n argocd
   kubectl apply -f argocd/apps/nginx-app.yaml -n argocd
   kubectl apply -f argocd/apps/cert-manager-app.yaml -n argocd
   kubectl apply -f argocd/apps/gitlab-app.yaml -n argocd
   ```

4. アプリケーションの状態を確認

   ArgoCD UIでアプリケーションの状態を確認するか、CLIを使用：

   ```bash
   argocd app list
   argocd app get <app-name>
   ```

### 同期ポリシー

各アプリケーションには以下の同期ポリシーが設定されています：

- **自動同期**: 有効（Gitリポジトリの変更を自動的にクラスターに反映）
- **自己ヒーリング**: 有効（手動で変更されたリソースを自動的に元の状態に戻す）
- **Prune**: 有効（Gitリポジトリから削除されたリソースを自動的に削除）
- **CreateNamespace**: 有効（必要なネームスペースを自動的に作成）

### トラブルシューティング

アプリケーションが同期されない場合：

1. GitリポジトリのURLと認証情報を確認
2. ターゲットネームスペースが存在するか確認
3. ArgoCDのログを確認：

   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
   ```

## 参考リンク

- [Argo CD 公式ドキュメント](https://argo-cd.readthedocs.io/)
- [Argo CD Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [App of Apps パターン](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)