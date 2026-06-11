## Summary

Bootstrap が 01→02→03→05→addons と手動チェーン。統一エントリポイントで role とオプションを指定できるようにする。

## Progress

- [x] `kubeadm/bootstrap.sh` MVP 実装済み（init / join-worker / join-cp stub）
- [ ] HA join-cp 実装後に bootstrap 統合
- [ ] `--with-ingress`, `--with-metallb`, `--with-longhorn` フラグ拡張
- [ ] CI で `bash -n` / dry-run 検証

## Acceptance Criteria (残)

- [ ] `bootstrap.sh --role join-cp` が 03b を呼び出す
- [ ] 追加 addon フラグのパススルー
- [ ] ルート `readme.md` クイックリンク更新
- [ ] 失敗時 exit code 区分のテスト

## Related

- 設計書: `docs/kubeadm-cluster-design.md`
