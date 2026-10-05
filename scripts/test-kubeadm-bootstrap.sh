#!/bin/bash
# kubeadm/bootstrap.sh の静的検証とテスト（クラスタ不要）。
#   1. kubeadm/ 配下の全 .sh を bash -n で構文チェック
#   2. 実行ビット（run_phase はスクリプトを直接実行する）
#   3. --dry-run でのフェーズ順序・addon フラグのパススルー
#   4. 終了コード区分（2=引数エラー、フェーズ失敗はそのフェーズの終了コード）
#      ※ 4 の一部は root か passwordless sudo が必要。無ければ SKIP する
# Usage: bash scripts/test-kubeadm-bootstrap.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/kubeadm/bootstrap.sh"
FAILED=0
OUT=""
EC=0

pass() { echo "  OK:   $*"; }
fail() { echo "  FAIL: $*"; FAILED=1; }
skip() { echo "  SKIP: $*"; }

run() {
  OUT="$("$@" 2>&1)"
  EC=$?
}

expect_ec() {
  local want="$1" desc="$2"
  if [[ "${EC}" -eq "${want}" ]]; then
    pass "${desc} (exit ${EC})"
  else
    fail "${desc}: exit ${EC}, want ${want}"
    echo "${OUT}" | sed 's/^/        /'
  fi
}

expect_out() {
  local pattern="$1" desc="$2"
  if grep -qE -- "${pattern}" <<<"${OUT}"; then
    pass "${desc}"
  else
    fail "${desc}: /${pattern}/ not found in output"
    echo "${OUT}" | sed 's/^/        /'
  fi
}

echo "--- bash -n ---"
while IFS= read -r f; do
  if bash -n "${REPO_ROOT}/${f}"; then pass "${f}"; else fail "syntax: ${f}"; fi
done < <(cd "${REPO_ROOT}" && git ls-files -- 'kubeadm/*.sh')

echo "--- executable bit ---"
while read -r mode _ _ f; do
  if [[ "${mode}" == "100755" ]]; then pass "${f}"; else fail "not executable in git (${mode}): ${f}"; fi
done < <(cd "${REPO_ROOT}" && git ls-files -s -- 'kubeadm/*.sh' ':!kubeadm/scripts/common.sh')

echo "--- dry-run phases ---"
run bash "${BOOTSTRAP}" --role init --dry-run --with-ingress --with-metallb --with-longhorn --with-network-policies
expect_ec 0 "init --dry-run"
expect_out "Phase: 01-prerequisites" "init runs 01"
expect_out "Phase: 03-init-control-plane" "init runs 03"
expect_out "Phase: 05-install-cni" "init runs 05"
expect_out "apply-addons.sh --with-ingress --with-metallb --with-longhorn --with-network-policies" "addon flags pass through"

run bash "${BOOTSTRAP}" --role init --dry-run --skip-prerequisites
expect_ec 0 "init --dry-run --skip-prerequisites"
if grep -q "Phase: 01-prerequisites" <<<"${OUT}"; then fail "01 should be skipped"; else pass "01 skipped"; fi

run bash "${BOOTSTRAP}" --role join-worker --dry-run --join-command 'kubeadm join x'
expect_ec 0 "join-worker --dry-run"
expect_out "Phase: 04-join-worker" "join-worker runs 04"

run bash "${BOOTSTRAP}" --role join-cp --dry-run --join-command 'kubeadm join x' --certificate-key k
expect_ec 0 "join-cp --dry-run"
expect_out "Phase: 03b-join-control-plane" "join-cp runs 03b"

echo "--- exit code: usage errors = 2 ---"
run bash "${BOOTSTRAP}" --dry-run;                                   expect_ec 2 "missing --role"
run bash "${BOOTSTRAP}" --role init --dry-run --bogus;               expect_ec 2 "unknown argument"
run bash "${BOOTSTRAP}" --role init --dry-run --with-cni flannel;    expect_ec 2 "invalid CNI"
run bash "${BOOTSTRAP}" --role nope --dry-run;                       expect_ec 2 "invalid role"
run bash "${BOOTSTRAP}" --role join-worker --dry-run;                expect_ec 2 "join-worker without --join-command"
run bash "${BOOTSTRAP}" --role join-cp --dry-run --join-command x;   expect_ec 2 "join-cp without --certificate-key"
run bash "${BOOTSTRAP}" --help;                                      expect_ec 0 "--help"

echo "--- exit code: phase failure propagates (stub phases) ---"
SUDO=()
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO=(sudo -n)
  else
    SUDO=(none)
  fi
fi
if [[ "${SUDO[0]:-}" == "none" ]]; then
  skip "phase failure tests need root or passwordless sudo"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  mkdir -p "${TMP}/kubeadm/scripts" "${TMP}/kubeadm/addons"
  cp "${BOOTSTRAP}" "${TMP}/kubeadm/bootstrap.sh"
  cp "${REPO_ROOT}/kubeadm/scripts/common.sh" "${TMP}/kubeadm/scripts/common.sh"
  for s in 01-prerequisites 02-install-kubeadm 03-init-control-plane 05-install-cni; do
    printf '#!/bin/bash\nexit 0\n' > "${TMP}/kubeadm/scripts/${s}.sh"
  done
  printf '#!/bin/bash\nexit 0\n' > "${TMP}/kubeadm/addons/apply-addons.sh"
  chmod +x "${TMP}"/kubeadm/scripts/*.sh "${TMP}"/kubeadm/addons/*.sh

  run "${SUDO[@]}" bash "${TMP}/kubeadm/bootstrap.sh" --role init
  expect_ec 0 "all stub phases succeed"

  printf '#!/bin/bash\nexit 7\n' > "${TMP}/kubeadm/scripts/03-init-control-plane.sh"
  run "${SUDO[@]}" bash "${TMP}/kubeadm/bootstrap.sh" --role init
  expect_ec 7 "failing phase exit code is propagated"
  expect_out "Phase failed: 03-init-control-plane \(exit 7\)" "failure message names the phase"
  if grep -q "Phase: 05-install-cni" <<<"${OUT}"; then fail "phases after failure must not run"; else pass "stops after failed phase"; fi
fi

echo "--- 00-configure-lb.sh --check-api (#19) ---"
LB="${REPO_ROOT}/kubeadm/scripts/00-configure-lb.sh"
# 127.0.0.1:1 は待ち受けが無い（届かない endpoint）
run env CONTROL_PLANE_IP=127.0.0.1 CONTROL_PLANE_PORT=1 bash "${LB}" --check-api
expect_ec 0 "unreachable API without --strict only warns"
expect_out "127.0.0.1:1" "CONTROL_PLANE_PORT is used in the endpoint"
run env CONTROL_PLANE_IP=127.0.0.1 CONTROL_PLANE_PORT=1 bash "${LB}" --check-api --strict
expect_ec 1 "unreachable API with --strict fails"
run env CONTROL_PLANE_IP=999.1.1.1 bash "${LB}"
expect_ec 1 "invalid CONTROL_PLANE_IP fails"

echo "--- 03b-join-control-plane.sh (#20; root 不要の経路) ---"
CP="${REPO_ROOT}/kubeadm/scripts/03b-join-control-plane.sh"
JOIN='kubeadm join lb.example:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:deadbeef'
run bash "${CP}" --help
expect_ec 0 "--help works without root"
run bash "${CP}" --join "${JOIN}" --certificate-key SECRETKEY --dry-run
expect_ec 0 "--join --dry-run"
expect_out "--control-plane" "dry-run adds --control-plane"
expect_out "--certificate-key \*\*\*" "dry-run masks the certificate key"
if grep -qE "SECRETKEY|abcdef\.0123|deadbeef" <<<"${OUT}"; then fail "secrets leaked in dry-run output"; else pass "no secrets in dry-run output"; fi
run env -u CERTIFICATE_KEY bash "${CP}" --join "${JOIN}" --dry-run
expect_ec 1 "--join without certificate key fails"
run bash "${CP}"
expect_ec 1 "no arguments prints usage and fails"

echo
if [[ "${FAILED}" -ne 0 ]]; then
  echo "kubeadm bootstrap tests FAILED"
  exit 1
fi
echo "kubeadm bootstrap tests passed"
