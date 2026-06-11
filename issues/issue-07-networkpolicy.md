## Summary

kubeadm クラスタ全体の **namespace 間デフォルト deny + 明示 allow** ベースラインがない。

## Acceptance Criteria

- [ ] `kubeadm/addons/network-policies/` Kustomize bundle
- [ ] 対象: `kube-system`, `argocd`, `ingress-nginx`, `longhorn-system`
- [ ] DNS allow + default deny ingress
- [ ] `apply-addons.sh --with-network-policies`（opt-in）
- [ ] `kubeadm/docs/network-policies.md`

## Files to Touch

- `kubeadm/addons/network-policies/`
- `kubeadm/addons/apply-addons.sh`
- `scripts/validate.sh`
