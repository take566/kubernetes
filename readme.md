# kubectl
 ```
$ curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
$ chmod +x kubectl
$ sudo mv ./kubectl /usr/local/bin/
$ kubectl version --client
 ```
# minikube インストール
```
$ curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
$ sudo install minikube-linux-amd64 /usr/local/bin/minikube
```
```
sudo usermod -aG docker $USER && newgrp docker
minikube config set driver docker
minikube start --driver=docker
```
# argocd
 ```
kubectl apply -f ingress.yml -n argocd
 ```

## ArgoCDのログインページにログイン
 ```
# kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# argocd account update-password
*** Enter current password:
*** Enter new password:
*** Confirm new password:
 ```
 
 
## ArgoCD CLIの導入
```
# wget https://github.com/argoproj/argo-cd/releases/download/v2.0.5/argocd-linux-amd64

# wget https://github.com/argoproj/argo-cd/releases/download/v2.0.5/argocd-util-linux-amd64

# install argocd-linux-amd64 /usr/local/bin/argocd

# install argocd-util-linux-amd64 /usr/local/bin/argocd-util
 ```

# gitlab
## GitLabのインストール
```
$ helm repo add gitlab https://charts.gitlab.io/
"gitlab" has been added to your repositories
$ helm repo update
```
## GitLabをデプロイ
```
$ NAMESPACE=gitlab
$ helm upgrade --install gitlab gitlab/gitlab \
  --namespace $NAMESPACE \
  --version=2.1.0 \
  --values gitlab_config.yaml
```
## podが起動しているか確認
```
$ kubectl get --namespace $NAMESPACE pods
```

## 初期ユーザとパスワードを確認
```
 kubectl get secret gitlab-gitlab-initial-root-password \
  --namespace $NAMESPACE \
  -ojsonpath='{.data.password}' | base64 --decode ; echo
```