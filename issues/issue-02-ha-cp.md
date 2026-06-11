## Summary

現状 `03-init-control-plane.sh` は単一 CP の `kubeadm init` のみ。README は「3 ノード HA 推奨」と記載するが、**2台目・3台目 CP の join 手順・証明書アップロード・join-config テンプレート**が未整備。

## Acceptance Criteria

- [ ] `kubeadm/scripts/03b-join-control-plane.sh` — CP join（`--control-plane --certificate-key`）
- [ ] `kubeadm/join-config.yaml.example` に CP join 例を追記
- [ ] `03-init-control-plane.sh` で `--upload-certs` 出力の保存手順を明示
- [ ] `kubeadm/docs/ha-control-plane.md` — 3 ノード構築 Runbook
- [ ] 全 CP Ready + etcd メンバー 3 を確認

## Dependencies

- #1: `controlPlaneEndpoint` が LB/VIP で到達可能

## Files to Touch

- `kubeadm/scripts/03b-join-control-plane.sh`
- `kubeadm/join-config.yaml.example`
- `kubeadm/docs/ha-control-plane.md`
- `kubeadm/README.md`

## Related

- 設計書: `docs/kubeadm-cluster-design.md`
