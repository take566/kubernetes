Kubernetes 上で Jenkins を構築し、Helm を使用して管理するための手順をご案内します。Helm は Kubernetes のパッケージマネージャであり、アプリケーションの定義、インストール、アップグレードを簡単にするツールです。

# 前提条件
* Kubernetes クラスタがセットアップされていること。
* kubectl がローカルマシンにインストールされており、クラスタに接続できること。
* Helm がローカルマシンにインストールされていること。
## ステップ 1: Helm リポジトリの追加
まず、Jenkins のチャートが含まれる Helm リポジトリを追加します。


helm repo add jenkinsci https://charts.jenkins.io
helm repo update
## ステップ 2: Jenkins のインストール
Jenkins をインストールするには、以下のコマンドを実行します。ここでは jenkins という名前の namespace に Jenkins をデプロイしますが、適宜変更してください。


kubectl create namespace jenkins
helm install jenkins jenkinsci/jenkins --namespace jenkins
## ステップ 3: Jenkins の設定
インストール後、Jenkins の管理パスワードを取得します。


printf $(kubectl get secret --namespace jenkins jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode);echo
次に、Jenkins にアクセスするためのポートフォワーディングを設定します。


kubectl --namespace jenkins port-forward svc/jenkins 8080:8080
このコマンドを実行後、ブラウザから http://localhost:8080 にアクセスして Jenkins のダッシュボードにログインできます。ログインには先ほど取得した管理パスワードを使用します。

## ステップ 4: Helm チャートのカスタマイズ
デフォルトの設定で Jenkins をデプロイした場合、追加の設定やプラグインのインストールが必要になるかもしれません。これを行うには、Helm チャートのカスタマイズが必要です。

まず、デフォルトの values.yaml ファイルをダウンロードします。


helm show values jenkinsci/jenkins > jenkins-values.yaml
このファイルを編集して、必要な設定（リソース制限、プラグインリスト、永続ボリュームの設定など）を行います。編集後、次のコマンドでアップデートを適用します。


helm upgrade jenkins jenkinsci/jenkins --namespace jenkins -f jenkins-values.yaml
ステップ 5: クリーンアップ
Jenkins のインスタンスを削除するには、以下のコマンドを実行します。


helm delete jenkins --namespace jenkins
kubectl delete namespace jenkins
これで Kubernetes 上に Jenkins を構築し、Helm で管理する基本的な手順を完了しました。具体的なカスタマイズや、より高度な設定については、Jenkins の公式ドキュメントや Helm チャートのドキュメントを参照してください。