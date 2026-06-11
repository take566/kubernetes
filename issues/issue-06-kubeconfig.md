## Summary

`docs/kubeadm-connect.md` と `scripts/kubeadm-connect.ps1` は手動 scp + merge。自動化を強化する。

## Acceptance Criteria

- [ ] `kubeadm/scripts/08-export-kubeconfig.sh`（CP 上）
- [ ] `scripts/kubeadm-connect.sh`（Linux/WSL）
- [ ] `scripts/kubeadm-connect.ps1` に `fetch` アクション
- [ ] `docs/kubeadm-connect.md` をスクリプト中心に更新
- [ ] 秘密情報をログに出さない

## Files to Touch

- `kubeadm/scripts/08-export-kubeconfig.sh`
- `scripts/kubeadm-connect.sh`
- `scripts/kubeadm-connect.ps1`
- `docs/kubeadm-connect.md`
