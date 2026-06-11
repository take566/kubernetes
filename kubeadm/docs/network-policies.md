# NetworkPolicy ベースライン（opt-in）

Calico 互換の最小 NetworkPolicy セットです。デフォルトでは適用されません。

## 適用方法

```bash
# ingress-nginx / Argo CD 等の namespace 作成後
./kubeadm/addons/apply-addons.sh --with-network-policies

# または直接
kubectl apply -k kubeadm/addons/network-policies/
```

`bootstrap.sh --with-network-policies` でも init 時に適用できます。

## ポリシー概要

| ファイル | 内容 |
|----------|------|
| `default-deny.yaml` | `argocd`, `ingress-nginx`, `longhorn-system`, `kube-system` で ingress 全拒否 |
| `allow-dns.yaml` | 上記 namespace から kube-dns への egress 53/udp,tcp + kube-system 内 DNS ingress 許可 |
| `allow-ingress-controller.yaml` | `ingress-nginx` コントローラへ 80/443/8443 ingress 許可 |

## 前提

- CNI が NetworkPolicy をサポートすること（Calico 推奨）
- 対象 namespace がクラスタに存在すること（未作成の場合は apply が失敗）
- 追加の通信（Argo CD UI、Longhorn UI 等）は別途 allow ポリシーを追加すること

## 検証

```bash
./scripts/validate.sh
kubectl get networkpolicy -A
```

## カスタマイズ

新しい namespace を保護する場合は、同パターンで `default-deny-ingress` と `allow-dns-egress` を追加してください。
