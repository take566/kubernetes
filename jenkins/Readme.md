# Kubernetes上でのJenkins構築ガイド

このガイドでは、Kubernetes上でJenkinsを構築し、Helmを使用して管理する方法を説明します。

## 前提条件

* Kubernetesクラスタがセットアップされていること
* kubectlがローカルマシンにインストールされており、クラスタに接続できること
* Helmがローカルマシンにインストールされていること

## 構築手順

### 1. Kubernetesクラスタの確認

```bash
kubectl cluster-info
```

### 2. Helmリポジトリの追加

```bash
helm repo add jenkinsci https://charts.jenkins.io
helm repo update
```

### 3. Jenkins用のnamespaceの作成

```bash
kubectl create namespace jenkins
```

### 4. Helmを使用したJenkinsのインストール

```bash
helm install jenkins jenkinsci/jenkins --namespace jenkins
```

### 5. 管理者パスワードの取得

```bash
kubectl exec --namespace jenkins -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo
```

### 6. ポートフォワーディングの設定

```bash
kubectl --namespace jenkins port-forward svc/jenkins 8080:8080
```

### 7. ブラウザからJenkinsにアクセス

ブラウザで http://localhost:8080 にアクセスし、以下の情報でログインします：

- ユーザー名: admin
- パスワード: 上記の手順5で取得したパスワード

## Jenkinsへのアクセス情報

- URL: http://localhost:8080
- ユーザー名: admin
- パスワード: 手順5で取得したパスワード

**注意**: ポートフォワーディングは、実行したターミナルを開いている間のみ有効です。Jenkinsにアクセスするには、このターミナルを開いたままにしておく必要があります。

## Jenkinsのカスタマイズ

Jenkinsをカスタマイズする場合は、以下の手順に従ってください：

1. デフォルトの設定ファイルを取得

```bash
helm show values jenkinsci/jenkins > jenkins-values.yaml
```

2. 設定ファイルを編集して必要な設定（リソース制限、プラグインリスト、永続ボリュームの設定など）を行います。

3. 編集した設定ファイルを適用

```bash
helm upgrade jenkins jenkinsci/jenkins --namespace jenkins -f jenkins-values.yaml
```

## Jenkinsの削除

Jenkinsを削除する場合は、以下のコマンドを実行してください：

```bash
helm delete jenkins --namespace jenkins
kubectl delete namespace jenkins
```
