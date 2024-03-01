
Kubernetes 上で Argo CD を構築し、Helm を使用して管理するプロセスは、以下の手順で行います。このプロセスを通じて、Argo CD を Kubernetes クラスターにデプロイし、Helm チャートを使用してその設定を管理する方法を学びます。

# 前提条件
Kubernetes クラスタがセットアップされ、kubectl コマンドラインツールがクラスタと通信できるように設定されていること。
Helm がローカルマシンにインストールされていること。
## 1. Argo CD の Helm チャートの追加
まず、Argo CD の Helm チャートを利用可能なリポジトリリストに追加します。このチャートは、Argo CD のインストールと設定を簡単にするためのものです。


helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
## 2. 名前空間の作成
Argo CD を分離された名前空間にデプロイすることを推奨します。これにより、セキュリティと管理が容易になります。


kubectl create namespace argocd
## 3. Argo CD のインストール
Helm を使用して、先ほど追加したリポジトリから Argo CD をインストールします。


helm install argocd argo/argo-cd --namespace argocd --version <version>
<version> には、インストールしたい Argo CD のバージョンを指定してください。特定のバージョンを指定しない場合は、最新バージョンがインストールされます。

## 4. Argo CD サーバーへのアクセス
Argo CD サーバーへのアクセスを設定するには、いくつかの方法がありますが、最も簡単なのはポートフォワーディングを使用する方法です。


kubectl port-forward svc/argocd-server -n argocd 8080:443
このコマンドを実行した後、ブラウザから http://localhost:8080 にアクセスして Argo CD の UI にアクセスできます。

## 5. Argo CD の初期パスワードの取得
Argo CD の初期インストール後、admin アカウントのパスワードは、argocd-server ポッドの名前として設定されています。このパスワードを取得するには、以下のコマンドを使用します。


kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2
## 6. Argo CD へのログイン
取得したパスワードを使用して、CLI または UI から Argo CD にログインします。CLI からログインするには、以下のコマンドを使用します。


argocd login localhost:8080 --username admin --password <初期パスワード>
これで、Kubernetes 上に Argo CD を構築し、Helm を使用して管理する基本的なセットアップが完了しました。Argo CD を使用してアプリケーションのデプロイ、管理、監視を行うことができます。