## Summary

README §5 は `kubectl apply -k nginx/` または Argo CD 手動。**kubeadm bootstrap フローに Ingress NGINX を組み込む**。

## Acceptance Criteria

- [ ] `kubeadm/addons/ingress-nginx/` Kustomize
- [ ] `apply-addons.sh --with-ingress` または `bootstrap.sh --with-ingress`
- [ ] kubeadm 向け: DaemonSet+hostPort または MetalLB LoadBalancer
- [ ] default IngressClass `nginx`
- [ ] `scripts/validate.sh` に追加

## Dependencies

- unified bootstrap (#3)
- MetalLB（任意, #1）

## Files to Touch

- `kubeadm/addons/ingress-nginx/`
- `kubeadm/addons/apply-addons.sh`
- `kubeadm/bootstrap.sh`
- `kubeadm/README.md`
