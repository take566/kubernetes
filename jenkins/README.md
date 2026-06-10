# Jenkins on Kubernetes (Helm)

Kubernetes 上で Jenkins を Helm チャートで構築・管理する手順です。

> 本リポジトリの GitOps 対象外。参考ドキュメントとして `jenkins/` に配置しています。

## 前提条件

- Kubernetes クラスタが利用可能
- `kubectl` がクラスタに接続済み
- Helm v3 がインストール済み

## 構築手順

### 1. クラスタ確認

```bash
kubectl cluster-info
```

### 2. Helm リポジトリ追加

```bash
helm repo add jenkinsci https://charts.jenkins.io
helm repo update
```

### 3. Namespace 作成とインストール

```bash
kubectl create namespace jenkins
helm install jenkins jenkinsci/jenkins --namespace jenkins
```

### 4. 管理者パスワード取得

```bash
kubectl exec --namespace jenkins -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo
```

### 5. ポートフォワード

```bash
kubectl --namespace jenkins port-forward svc/jenkins 8080:8080
```

ブラウザで http://localhost:8080 にアクセス（ユーザー: `admin`、パスワード: 手順 4）。

## カスタマイズ

```bash
helm show values jenkinsci/jenkins > jenkins-values.yaml
# 編集後
helm upgrade jenkins jenkinsci/jenkins --namespace jenkins -f jenkins-values.yaml
```

## 削除

```bash
helm delete jenkins --namespace jenkins
kubectl delete namespace jenkins
```
