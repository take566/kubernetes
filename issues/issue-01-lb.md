## Summary

`kubeadm-config.yaml` の `controlPlaneEndpoint: cp.example.com:6443` はプレースホルダのみで、実際の VIP / LB 構築手順がリポジトリにない。HA control-plane の前提として、**外部 LB（keepalived/haproxy/nginx）** または **MetalLB L2** による API Server エンドポイント安定化をコード化する。

## Background

- 現状: README に DNS/LB 推奨の記述のみ
- `controlPlaneEndpoint` は init 前に確定必須
- クラウド外（ベアメタル / homelab）では MetalLB または自前 VIP が現実的

## Acceptance Criteria

- [ ] **Option A（外部 LB）**: `kubeadm/docs/load-balancer-external.md` に haproxy + keepalived 例（TCP 6443）
- [ ] **Option B（MetalLB）**: `kubeadm/addons/metallb/` Kustomize overlay
- [ ] `kubeadm/scripts/00-configure-lb.sh` で endpoint IP/DNS を検証・出力
- [ ] `kubeadm-config.yaml` に LB 前提コメントを明記
- [ ] `scripts/validate.sh` に metallb kustomize build を追加
- [ ] README に「LB 構築 → init」の順序を追記

## Files to Touch

- `kubeadm/addons/metallb/`
- `kubeadm/scripts/00-configure-lb.sh`
- `kubeadm/docs/load-balancer-external.md`
- `kubeadm/kubeadm-config.yaml`
- `kubeadm/README.md`
- `kubeadm/addons/apply-addons.sh` (`--with-metallb`)
- `scripts/validate.sh`

## Related

- 設計書: `docs/kubeadm-cluster-design.md`
