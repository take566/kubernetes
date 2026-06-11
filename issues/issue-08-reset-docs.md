## Summary

- `kubeadm reset` 手順がリポジトリにない
- README が 05-rocm / 07-register スクリプトを含まない

## Acceptance Criteria

- [ ] `kubeadm/scripts/99-reset-cluster.sh`（`--purge-data`, `--yes`）
- [ ] `kubeadm/README.md` に GPU フロー・全スクリプト一覧を同期
- [ ] `docs/GPU_WORKER_JOIN_AMD.md` 相互リンク
- [ ] ルート `readme.md` / `CLAUDE.md` 索引更新

## Files to Touch

- `kubeadm/scripts/99-reset-cluster.sh`
- `kubeadm/README.md`
- `docs/GPU_WORKER_JOIN_AMD.md`
- `readme.md`
