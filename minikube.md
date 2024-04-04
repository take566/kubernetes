
```
minikube delete
```

```
minikube start --cpus 4 --memory 10240
```

## アドオンの有効化
minikubeは、基本設定とは別にいくつかの機能を扱います。このプロジェクトの開発には、Ingress にアクセスする必要があります：
```
minikube addons enable ingress
```