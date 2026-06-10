# Nexus Repository Manager

Kubernetes 上に Nexus Repository Manager をデプロイして、npm パッケージと Docker イメージを一元管理します。

## 📋 概要

- **Nexus Web UI**: アーティファクト管理とユーザー管理
- **npm Registry**: npm パッケージの管理（Hosted/Proxy/Group）
- **Docker Registry**: Docker イメージの管理（Hosted/Proxy/Group）

## 🚀 デプロイ方法

### 方法 1: kubectl 直接実行

#### Linux/macOS

```bash
# デプロイスクリプトで実行
chmod +x deploy.sh
./deploy.sh

# または手動で実行
kubectl apply -f namespace.yaml
kubectl apply -f nexus-pv.yaml
kubectl apply -f nexus-deployment.yaml
kubectl apply -f nexus-service.yaml
kubectl apply -f nexus-ingress.yaml
```

#### Windows (PowerShell)

```powershell
# 同じコマンドで実行可能
kubectl apply -f namespace.yaml
kubectl apply -f nexus-pv.yaml
kubectl apply -f nexus-deployment.yaml
kubectl apply -f nexus-service.yaml
kubectl apply -f nexus-ingress.yaml
```

### 方法 2: ArgoCD による管理（推奨）

```bash
# root-application を同期（nexus-app.yaml が自動的にデプロイされます）
argocd app sync root-application

# または Nexus Application を直接同期
argocd app sync nexus

# 状態確認
argocd app info nexus
```

**ArgoCD での管理の詳細は [ARGOCD_MANAGEMENT.md](ARGOCD_MANAGEMENT.md) を参照してください。**

## 🔑 初期設定

### 1. Pod の起動を確認

```bash
kubectl -n nexus get pods -w
```

Pod が `Running` になるまで待機（初回は数分かかる場合があります）

### 2. 管理者パスワード取得

```powershell
# Windows
./get-admin-password.ps1

# Linux/macOS
./get-admin-password.sh
```

または直接取得：

```bash
kubectl -n nexus exec <pod-name> -- cat /nexus-data/admin.password
```

### 3. ブラウザでアクセス

- **URL**: `http://nexus.local:8081`
- **ユーザー名**: `admin`
- **パスワード**: 上記で取得したパスワード

> **注**: `nexus.local` を使用するには、ホスト OS の `hosts` ファイルに以下を追加してください：
> ```
> 127.0.0.1 nexus.local docker-registry.local npm-registry.local
> ```

## 📦 リポジトリ設定

詳細な設定手順は [configure-registries.md](configure-registries.md) を参照してください。

### npm リポジトリの設定

```bash
npm config set registry http://npm-registry.local:8083/repository/npm-internal/
npm adduser --registry http://npm-registry.local:8083/repository/npm-internal/
npm publish --registry http://npm-registry.local:8083/repository/npm-internal/
```

### Docker リポジトリの設定

```bash
docker login -u admin docker-registry.local:8082
docker tag my-app:latest docker-registry.local:8082/my-app:latest
docker push docker-registry.local:8082/my-app:latest
```

## 🌐 アクセス方法

| 用途 | URL | ポート | 方式 |
|------|-----|--------|------|
| Nexus Web UI | http://nexus.local:8081 | 8081 | ClusterIP |
| npm Registry | npm-registry.local | 8083 | ClusterIP |
| Docker Registry | docker-registry.local | 8082 | ClusterIP |
| NodePort (Web UI) | http://<node-ip>:30081 | 30081 | NodePort |
| NodePort (Docker) | <node-ip>:30082 | 30082 | NodePort |
| NodePort (npm) | <node-ip>:30083 | 30083 | NodePort |

## 📊 ストレージ

- **PersistentVolume**: 100GB
- **マウント先**: `/nexus-data`
- **ホストパス**: `/data/nexus` (ノード上)

> **注**: hostPath 利用時は、各ノード上に `/data/nexus` を事前作成してください（本番・開発とも overlay / local-path を推奨）

## 🔍 トラブルシューティング

### Pod が起動しない

```bash
# ログ確認
kubectl -n nexus logs -f <pod-name>

# リソース確認
kubectl -n nexus describe pod <pod-name>
```

### 権限エラーが発生する

```bash
# PersistentVolume の権限確認
kubectl -n nexus describe pvc nexus-pvc

# ホスト側の権限確認 (hostPath 利用時)
```

### メモリ不足エラー

Deployment のリソース設定を確認し、必要に応じて増加させてください：

```yaml
resources:
  requests:
    memory: "4Gi"  # 増加
  limits:
    memory: "8Gi"  # 増加
```

## 📚 参考資料

- [Nexus Repository Documentation](https://help.sonatype.com/repomanager3)
- [Kubernetes PersistentVolumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [npm Registry](https://docs.npmjs.com/cli/v8/commands/npm-adduser)
- [Docker Registry](https://docs.docker.com/registry/)

## 🛠️ ファイル構成

```
nexus/
├── namespace.yaml              # Kubernetes Namespace
├── nexus-pv.yaml              # PersistentVolume と PersistentVolumeClaim
├── nexus-deployment.yaml       # Nexus Deployment
├── nexus-service.yaml         # Service (ClusterIP と NodePort)
├── nexus-ingress.yaml         # Ingress
├── deploy.sh                  # デプロイスクリプト (Linux/macOS)
├── get-admin-password.ps1     # パスワード取得スクリプト (PowerShell)
├── configure-registries.md    # リポジトリ設定ガイド
└── README.md                  # このファイル
```

## ⚡ クイックコマンド

```bash
# デプロイ確認
kubectl -n nexus get all

# Pod の詳細確認
kubectl -n nexus describe pod <pod-name>

# ログ確認
kubectl -n nexus logs -f nexus-0

# Port Forward (ローカルアクセス用)
kubectl -n nexus port-forward svc/nexus 8081:8081

# Pod に接続
kubectl -n nexus exec -it <pod-name> -- /bin/bash
```

---

**作成日**: 2026年1月
**バージョン**: 1.0
