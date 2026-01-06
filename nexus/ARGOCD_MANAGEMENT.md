# ArgoCD での Nexus 管理ガイド

## 概要

Nexus は ArgoCD の app-of-apps パターンで管理されます。`argocd/apps/nexus-app.yaml` によって、Nexus のすべてのリソース（Namespace、PersistentVolume、Deployment、Service、Ingress）が自動的にデプロイされます。

## セットアップ手順

### 1. Git リポジトリに追加

```bash
# Nexus ファイルが既に Git に含まれていることを確認
git add nexus/
git add argocd/apps/nexus-app.yaml
git commit -m "Add Nexus Repository Manager"
git push
```

### 2. ArgoCD で Application を確認

```bash
# ArgoCD にログイン
argocd login argocd.local

# Nexus Application を確認
argocd app list
# または
argocd app info nexus
```

### 3. Application の同期

**自動同期の場合** (デフォルト):
- `syncPolicy.automated.prune=true` で自動同期が有効です
- リポジトリの変更が自動的に反映されます

**手動同期の場合**:

```bash
# Nexus Application を同期
argocd app sync nexus

# 同期の完了を待つ
argocd app wait nexus
```

または PowerShell スクリプトを使用：

```powershell
./sync-argocd.ps1
```

## Application の詳細情報

### argocd/apps/nexus-app.yaml の設定

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nexus                    # Application 名
  namespace: argocd
  finalizers:                    # リソース削除時に自動クリーンアップ
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/kubernetes
    targetRevision: main         # 監視するブランチ
    path: nexus                  # Git 内のパス
  destination:
    server: https://kubernetes.default.svc
    namespace: nexus
  syncPolicy:
    automated:
      prune: true                # 削除されたリソースは Kubernetes から削除
      selfHeal: true             # Git との差分があれば自動修正
    syncOptions:
      - CreateNamespace=true     # Namespace がなければ自動作成
      - PrunePropagationPolicy=foreground
      - PruneLast=true
```

## 管理コマンド

### Application の状態確認

```bash
# Nexus Application の詳細情報
argocd app info nexus

# 同期状態の確認
argocd app get nexus

# リアルタイム監視
argocd app diff nexus

# ログ確認
argocd app logs nexus
```

### Application の同期制御

```bash
# 自動同期を無効化（手動同期のみにする）
argocd app set nexus --sync-policy none

# 自動同期を有効化
argocd app set nexus --sync-policy automated

# 強制同期（キャッシュをクリア）
argocd app sync nexus --hard-refresh

# Namespace 含めて削除
argocd app delete nexus --cascade=background
```

## トラブルシューティング

### Application が OutOfSync 状態

**原因**: Git のリポジトリと Kubernetes クラスタの状態が異なっている

**解決方法**:

```bash
# 差分確認
argocd app diff nexus

# 同期
argocd app sync nexus

# 強制同期（Git の状態をそのまま適用）
argocd app sync nexus --force
```

### Pod が起動しない

```bash
# Kubernetes Pod の状態確認
kubectl -n nexus get pods

# Pod のログ確認
kubectl -n nexus logs -f <pod-name>

# Pod の詳細情報
kubectl -n nexus describe pod <pod-name>

# Application のイベント確認
argocd app get nexus --show-operation-result
```

### PersistentVolume が作成されない

```bash
# PVC の状態確認
kubectl -n nexus get pvc

# PV の状態確認
kubectl get pv

# PVC の詳細情報
kubectl -n nexus describe pvc nexus-pvc

# ストレージクラス確認
kubectl get storageclass
```

### リソースが削除されない

```bash
# Finalizer を確認
kubectl -n nexus get pvc nexus-pvc -o yaml | grep finalizers

# Finalizer を手動削除（最後の手段）
kubectl -n nexus patch pvc nexus-pvc -p '{"metadata":{"finalizers":[]}}' --type=merge
```

## Git リポジトリの構成

```
.
├── argocd/
│   ├── apps/
│   │   ├── root-application.yaml    # App-of-apps のルート
│   │   ├── nexus-app.yaml          # ← 新しい Nexus Application
│   │   ├── gitlab-app.yaml
│   │   ├── prometheus-app.yaml
│   │   └── ...
│   └── ...
├── nexus/                           # ← Nexus リソース定義
│   ├── namespace.yaml
│   ├── nexus-pv.yaml
│   ├── nexus-deployment.yaml
│   ├── nexus-service.yaml
│   ├── nexus-ingress.yaml
│   ├── deploy.sh
│   ├── get-admin-password.ps1
│   ├── configure-registries.md
│   └── README.md
└── ...
```

## ArgoCD での監視設定

### Notifications の設定（オプション）

ArgoCD を Slack や email と連携させて、Application の同期状態を通知することができます。

```yaml
# argocd-notifications-cm ConfigMap の例
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: $slack-token
  template.app-sync-status: |
    message: |
      Application {{.app.metadata.name}} sync is {{.app.status.operationState.phase}}
      {{if eq .app.status.operationState.phase "Error"}}
      Errors:
      {{range $error := .app.status.conditions}}
      - {{$error.message}}
      {{end}}
      {{end}}
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error'] and app.status.operationState.finishedAt != ''
      send: [app-sync-status]
```

## ベストプラクティス

### 1. 環境ごとの管理

複数の環境がある場合は、Application を環境ごとに分ける：

```
argocd/
├── apps/
│   ├── root-application.yaml
│   ├── nexus-app.yaml          # 共通設定
│   └── ...
├── overlays/
│   ├── dev/
│   │   ├── nexus-app.yaml      # dev 環境専用
│   │   └── kustomization.yaml
│   └── prod/
│       ├── nexus-app.yaml      # prod 環境専用
│       └── kustomization.yaml
```

### 2. リソース制限の設定

```yaml
# nexus-deployment.yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

### 3. Health Check の設定

```yaml
# nexus-deployment.yaml
livenessProbe:
  httpGet:
    path: /service/metrics/healthcheck
    port: nexus-web
  initialDelaySeconds: 60
  periodSeconds: 30
```

### 4. Git ブランチの保護

- main ブランチは保護設定を有効化
- Pull Request による review の実施
- CI/CD パイプラインでの検証

## 参考資料

- [ArgoCD 公式ドキュメント](https://argo-cd.readthedocs.io/)
- [App of Apps パターン](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Nexus Repository ドキュメント](https://help.sonatype.com/repomanager3)

## FAQ

### Q: Application を削除するとどうなる？

A: `finalizers` に `resources-finalizer.argocd.argoproj.io` が設定されている場合、Application 削除時に対応する Kubernetes リソースもすべて削除されます（cascade delete）。

### Q: リポジトリが private の場合？

A: ArgoCD に SSH キーまたは personal access token を設定する必要があります。

```bash
argocd repo add https://github.com/your-org/kubernetes \
  --username <username> \
  --password <personal-access-token>
```

### Q: 異なるクラスタにデプロイしたい場合？

A: Application の `destination.server` を変更して、複数クラスタに対応できます。

```yaml
spec:
  destination:
    server: https://another-cluster:6443
    namespace: nexus
```

---

**最終更新**: 2026年1月
**バージョン**: 1.0
