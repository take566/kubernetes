# CoreDNS / Calico トラブルシューティング（kubeadm WSL）

## 症状

| 症状 | 例 |
|------|-----|
| CoreDNS `0/1` Ready | readiness probe `503` |
| `kube-dns` Endpoints 空 | `kubectl get endpoints -n kube-system kube-dns` |
| Pod ログ | `dial tcp 10.96.0.1:443: i/o timeout` |
| calico-kube-controllers | CrashLoopBackOff, datastore 初期化失敗 |
| ベンチマーク | FQDN 解決失敗（gateway IP 回避で動作） |

## 根本原因（2026-06-11 調査）

`kubeadm/addons/network-policies/` の **kube-system 向け blanket `allow-dns-egress`** が、namespace 内の全 Pod の egress を **DNS (53/tcp,udp) のみ** に制限していた。

- CoreDNS → Kubernetes API (`10.96.0.1:443`) への egress が遮断
- calico-kube-controllers → 同様に API 到達不可
- metrics-server は専用 NP で `egress: - {}` があり影響なし

kube-proxy / iptables は正常でも、**Calico NetworkPolicy が先に deny** するため ClusterIP へ到達できない。

## 診断

```bash
export KUBECONFIG=~/.kube/config-kubeadm-wsl
./kubeadm/scripts/diagnose-cluster-dns.sh
```

手動確認:

```bash
kubectl get networkpolicies -n kube-system
kubectl get endpoints -n kube-system kube-dns
# crictl でログ（kubectl logs が RBAC で拒否される場合）
sudo crictl ps --name coredns -q | head -1 | xargs -I{} sudo crictl logs --tail 20 {}
```

## 修正

NetworkPolicy を更新して適用:

```bash
kubectl apply -k kubeadm/addons/network-policies/
```

追加リソース:

- `allow-coredns-egress` — CoreDNS 全 egress 許可
- `allow-calico-controllers-egress` — calico-kube-controllers
- `allow-calico-node-egress` — calico-node

kube-system の誤った blanket `allow-dns-egress` は **削除**（allow-dns.yaml から除去）。

## 適用後の確認

```bash
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout restart deployment/calico-kube-controllers -n kube-system
kubectl wait -n kube-system --for=condition=ready pod -l k8s-app=kube-dns --timeout=120s
kubectl get endpoints -n kube-system kube-dns
```

成功基準:

- CoreDNS `1/1` Ready（2 レプリカ）
- `kube-dns` Endpoints に Pod IP が登録
- `kubectl run -it --rm dns-test --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default` が成功

## 関連

- GitHub issue #30
- `kubeadm/addons/network-policies/allow-kube-system-addon-egress.yaml`
- WSL ネットワーク: ノード `eth0` MTU 1280 — 通常は DNS/API とは無関係
