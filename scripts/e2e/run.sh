#!/bin/bash
# kind 上の e2e スイートの入口。
# Usage:
#   ./scripts/e2e/run.sh --list
#   ./scripts/e2e/run.sh <suite> [--target existing|kind] [--context CTX] [--keep] [--cluster-name NAME]
#     --target        existing（既定）: 既存クラスタ（WSL の kubeadm 等）/ kind: kind を作る（CI）
#     --context       kubeconfig の context（existing。省略時は現在の context）
#     --keep          終了後も e2e のリソース（kind ならクラスタ）を残す
#     --cluster-name  kind クラスタ名（既定: e2e）
#   WSL 例: wsl -u root -- env KUBECONFIG=/etc/kubernetes/admin.conf bash scripts/e2e/run.sh <suite>
# 終了コード: 0=全チェック成功 / 1=チェック失敗 / 2=引数エラー
# 設計: docs/design/k8s-native-backlog-redesign.md
#
# スイート（scripts/e2e/suites/<name>.sh）の規約:
#   SUITE_ISSUE="#N"                 対応 issue
#   SUITE_DESC="..."                 1 行説明
#   SUITE_CLUSTER_CONFIG=path        kind 設定（既定 kind/test-cluster.yaml）
#   SUITE_DUMP_NAMESPACES=(ns ...)   失敗時に診断情報を保存する名前空間
#   suite_main()                     本体。e2e::check / assert_* で条件を記録する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITES_DIR="${SCRIPT_DIR}/suites"

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

list_suites() {
  local f
  for f in "${SUITES_DIR}"/*.sh; do
    printf '%-24s %-6s %s\n' "$(basename "${f}" .sh)" \
      "$(sed -n 's/^SUITE_ISSUE="\(.*\)"/\1/p' "${f}")" \
      "$(sed -n 's/^SUITE_DESC="\(.*\)"/\1/p' "${f}")"
  done
}

SUITE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_suites; exit 0 ;;
    --keep) export E2E_KEEP=true; shift ;;
    --target)
      case "${2:-}" in existing|kind) export E2E_TARGET="$2" ;; *) echo "--target must be existing or kind" >&2; exit 2 ;; esac
      shift 2 ;;
    --context) export E2E_CONTEXT="${2:?--context needs a value}"; shift 2 ;;
    --cluster-name) export E2E_CLUSTER="${2:?--cluster-name needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [[ -z "${SUITE}" ]] || { echo "only one suite at a time" >&2; exit 2; }; SUITE="$1"; shift ;;
  esac
done
[[ -n "${SUITE}" ]] || { usage >&2; exit 2; }
[[ -f "${SUITES_DIR}/${SUITE}.sh" ]] || { echo "unknown suite: ${SUITE} (try --list)" >&2; exit 2; }

required=(kubectl jq)
[[ "${E2E_TARGET:-existing}" == kind ]] && required+=(kind docker)
for cmd in "${required[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "required command not found: ${cmd}" >&2; exit 1; }
done

export E2E_SUITE="${SUITE}"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

SUITE_CLUSTER_CONFIG="${E2E_ROOT}/kind/test-cluster.yaml"
SUITE_DUMP_NAMESPACES=()
# shellcheck disable=SC1090
source "${SUITES_DIR}/${SUITE}.sh"
E2E_ISSUE="${SUITE_ISSUE:-}"

trap 'e2e::cluster_down' EXIT

e2e::log "suite=${SUITE} issue=${E2E_ISSUE} cluster=${E2E_CLUSTER}"
e2e::cluster_up "${SUITE_CLUSTER_CONFIG}"

set +e
( set -euo pipefail; suite_main )
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  e2e::check "suite_main completed" false "exit ${rc}"
fi

if ! e2e::finish; then
  [[ ${#SUITE_DUMP_NAMESPACES[@]} -gt 0 ]] && e2e::dump_on_fail "${SUITE_DUMP_NAMESPACES[@]}"
  exit 1
fi
