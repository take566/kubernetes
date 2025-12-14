# ArgoCD セットアップ完了ガイド

## ✅ 現在のステータス

ArgoCDが正常にminikube上にインストールされました。

### サーバー情報
- **版**: ArgoCD v3.2.1
- **クラスター**: minikube (Kubernetes v1.34.0)
- **ネームスペース**: argocd
- **すべてのポッド**: Running ✓

## 🌐 アクセス方法

### 方法1: ポートフォワーディング（推奨）

ターミナルで以下のコマンドを実行してください：

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

その後、以下のURLにアクセスしてください：
```
https://localhost:8080
```

> 注意: 自己署名証明書の警告が表示されるかもしれません。ブラウザの詳細設定で続行を選択してください。

### 方法2: CLIでのログイン

```bash
# 初期パスワードを取得
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# CLIでログイン（Windows PowerShellの場合）
argocd login localhost:8080 --username admin --password <上記で取得したパスワード> --insecure
```

## 🔐 ログイン情報

| 項目 | 値 |
|------|-----|
| **ユーザー名** | admin |
| **パスワード** | 2mbAz1gAY9BuAMC8 |

## ⚙️ サービス確認コマンド

```bash
# すべてのポッドの確認
kubectl get pods -n argocd

# サービスの確認
kubectl get svc -n argocd

# Helmリリースの確認
helm list -n argocd
```

## 📋 トラブルシューティング

### ブラウザで表示されない場合

1. ターミナルでポートフォワーディングが実行されているか確認
2. https://localhost:8080 でアクセス（HTTPではなくHTTPSです）
3. 証明書エラーが表示された場合は「詳細設定」→「続行」を選択

### ポートが既に使用されている場合

```bash
# 別のポート（例：8081）を指定する
kubectl port-forward svc/argocd-server -n argocd 8081:443
```

## 🚀 次のステップ

1. UIにログインして、GitリポジトリをArgoCD に接続
2. アプリケーションを登録してデプロイ管理を開始
3. パスワードを変更（初期パスワードは変更を推奨）

## 📚 参考リンク

- [ArgoCD公式ドキュメント](https://argo-cd.readthedocs.io/)
- [ArgoCD Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
