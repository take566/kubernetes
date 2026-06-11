## Summary

`local-path` が default StorageClass。本番 HA / vLLM 永続化向けに **Longhorn Kustomize overlay + vLLM kubeadm overlay 切替**をリポジトリ化する。

## Acceptance Criteria

- [ ] `kubeadm/addons/longhorn/` Kustomize（バージョン pin）
- [ ] `apply-addons.sh --with-longhorn`
- [ ] `vllm/overlays/kubeadm/longhorn-storage-patch.yaml`
- [ ] `vllm/overlays/kubeadm/README.md` に local-path vs longhorn 選択表
- [ ] 最低 3 worker の注記

## Dependencies

- HA control-plane (#2)

## Files to Touch

- `kubeadm/addons/longhorn/`
- `vllm/overlays/kubeadm/`
- `scripts/validate.sh`
