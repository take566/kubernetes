# Jenkins on Kubernetes (Helm + Argo CD)

Kubernetes 上で Jenkins を公式 Helm チャートで構築・管理する設定です。GitLab と同様に、リポジトリ内のラッパーチャート + Argo CD Application でデプロイします。

## 構成

- **Chart.yaml**: Jenkins 公式 Helm チャートの依存関係定義
- **values.yaml**: Jenkins のカスタマイズ設定（リソース、プラグイン、永続化）

## 前提条件

- Kubernetes クラスタが利用可能
- Argo CD がインストール済み（[docs/ARGOCD_SETUP.md](../docs/ARGOCD_SETUP.md)）
- Helm v3（ローカル検証・直接デプロイ時）
- 推奨: CPU 2 コア以上、メモリ 4GB 以上

## デプロイ方法

### 方法1: Argo CD 経由（推奨）

1. `argocd/apps/jenkins-app.yaml` の `repoURL` / `targetRevision` を環境に合わせて確認

2. Application を適用（**手動 sync** — stateful のため auto-sync なし）

   ```bash
   kubectl apply -f argocd/apps/jenkins-app.yaml -n argocd
   ```

3. Argo CD UI または CLI で sync

   ```bash
   argocd app sync jenkins
   argocd app get jenkins
   ```

4. 管理者パスワード取得（chart が Secret を生成した場合）

   ```bash
   kubectl exec --namespace jenkins -it svc/jenkins -c jenkins -- \
     /bin/cat /run/secrets/additional/chart-admin-password && echo
   ```

5. ポートフォワード

   ```bash
   kubectl --namespace jenkins port-forward svc/jenkins 8080:8080
   ```

   ブラウザで http://localhost:8080（ユーザー: `admin`）

### 方法2: Helm 直接デプロイ

```bash
helm repo add jenkinsci https://charts.jenkins.io
helm repo update
kubectl create namespace jenkins
cd jenkins
helm dependency update
helm install jenkins . --namespace jenkins -f values.yaml
```

## カスタマイズ

`values.yaml` を編集してリソース、永続ボリューム、プラグイン、Ingress 等を調整します。

```bash
helm show values jenkinsci/jenkins > jenkins-values-reference.yaml
```

## 削除

```bash
# Argo CD 管理の場合
argocd app delete jenkins

# Helm 直接の場合
helm uninstall jenkins --namespace jenkins
kubectl delete namespace jenkins
```

## 参考

- [Jenkins Helm Chart](https://github.com/jenkinsci/helm-charts)
- [Argo CD セットアップ](../docs/ARGOCD_SETUP.md)
