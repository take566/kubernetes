# GitLab CE (Omnibus 単一コンテナ)

tmf-desktop 向けの軽量 GitLab。issue #115。

## 構成

- `base/` : Namespace `gitlab`、StatefulSet `gitlab`(`gitlab/gitlab-ce:19.5.1-ce.0`)、Service
  - Service `gitlab-nodeport`: http 30080 / ssh 30022
  - PVC: config 1Gi / logs 2Gi / data 20Gi (`local-path`)
- `overlays/tmf-desktop/` : base + `replicas: 0`(既定で停止)
- `secret.example.yaml` : root 初期パスワード Secret の例(実値は置かない)

メモリ削減設定(puma worker 0、sidekiq 5、prometheus/registry/pages/kas 無効)を
`GITLAB_OMNIBUS_CONFIG` で指定。requests 4GiB / limits 6GiB。**起動時は実際に 3GB 前後使う**ので、
空きメモリを確認してから起動すること。

## 起動

```bash
kubectl -n gitlab create secret generic gitlab-initial-root-password \
  --from-literal=password="$(openssl rand -base64 24)"   # 初回のみ(初回起動時にだけ使われる)
kubectl apply -k gitlab/overlays/tmf-desktop
kubectl -n gitlab scale statefulset gitlab --replicas=1
kubectl -n gitlab get pod gitlab-0 -w    # 初回は最大 15 分(migration)
```

Argo CD 管理下では scale が戻されるので、overlay の `count` を 1 にして commit する。

## 停止

```bash
kubectl -n gitlab scale statefulset gitlab --replicas=0
```

データ(PVC)は残る。

## アクセス

- WSL(NAT モード)では NodePort が Windows から届かないので、WSL 内で port-forward する:
  ```bash
  kubectl -n gitlab port-forward --address 127.0.0.1 svc/gitlab-nodeport 30080:80
  ```
  その上で Windows のブラウザから `http://localhost:30080`(`external_url` も `http://localhost:30080`)。
- NodePort が届く環境なら `http://<node-ip>:30080` / SSH は `ssh://git@<node-ip>:30022`。
- ユーザー `root`、パスワードは Secret `gitlab-initial-root-password`。
  Secret が無い場合は `kubectl -n gitlab exec gitlab-0 -- cat /etc/gitlab/initial_root_password`
  (24 時間で削除される)。

## Helm chart をやめた理由

公式 Helm chart は webservice / sidekiq / gitaly / redis / postgres 等を別 Pod で立てるため
最低でも 8GB 級のメモリが必要で、tmf-desktop では常駐できない。Omnibus 単一コンテナなら
約 4〜6GiB で、止めたい時は replicas 0 で済む。
