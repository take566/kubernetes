# shellcheck shell=bash
# #20 HA control-plane（stacked etcd 3 台）: etcd のメンバー数、LB 経由の API（00-configure-lb.sh --strict）、
# 1 台を止めても書き込みが通り、2 台止めると過半数を失って失敗し、戻すと回復することを検証する。
# ノードコンテナを docker pause するので kind 専用。
# 設計: docs/design/k8s-native-backlog-redesign.md「#20」
SUITE_ISSUE="#20"
SUITE_DESC="HA control-plane: etcd 3 メンバー / LB 経由の API / 1 台停止で継続・2 台停止で書き込み不可・復旧"
SUITE_CLUSTER_CONFIG="${E2E_ROOT}/kind/test-cluster-ha.yaml"
SUITE_KIND_WAIT=300s
SUITE_TARGETS="kind"
SUITE_TARGETS_REASON="pauses control-plane node containers"
SUITE_DUMP_NAMESPACES=(kube-system)

_wait_until() {
  local timeout="$1" start=${SECONDS}
  shift
  until "$@"; do
    (( SECONDS - start >= timeout )) && return 1
    sleep 3
  done
}

_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

_ready_cps() {
  e2e::kubectl get nodes -l node-role.kubernetes.io/control-plane -o json \
    | jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length'
}
_all_cps_ready() { [[ "$(_ready_cps)" -eq 3 ]]; }
_readyz_ok() { [[ "$(e2e::kubectl --request-timeout=10s get --raw /readyz 2>/dev/null)" == ok ]]; }

# kind ネットワーク上のコンテナで 00-configure-lb.sh を実行する（Docker Desktop でも CI でも同じ）
_check_lb() {  # <cp-ip> <endpoint>
  docker run --rm --network kind -v "${E2E_ROOT}/kubeadm/scripts:/s:ro" alpine:3.20 sh -c \
    "apk add -q --no-cache bash curl >/dev/null && CONTROL_PLANE_IP=$1 CONTROL_PLANE_DNS=$2 bash /s/00-configure-lb.sh --check-api --strict" \
    >/dev/null 2>&1
}

PAUSED=()
_unpause_all() {
  local c
  for c in "${PAUSED[@]+"${PAUSED[@]}"}"; do docker unpause "${c}" >/dev/null 2>&1 || true; done
  PAUSED=()
}

suite_main() {
  trap _unpause_all EXIT
  local cp1="${E2E_CLUSTER}-control-plane" cp2="${E2E_CLUSTER}-control-plane2" cp3="${E2E_CLUSTER}-control-plane3"
  local lb="${E2E_CLUSTER}-external-load-balancer"

  _wait_until 300 _all_cps_ready
  e2e::assert_eq "control-plane nodes Ready" "$(_ready_cps)" 3

  local members
  members="$(e2e::kubectl -n kube-system exec "etcd-${cp1}" -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key member list -w json | jq '.members | length')"
  e2e::assert_eq "etcd members (stacked)" "${members}" 3

  local cp_ip lb_ip
  cp_ip="$(_ip "${cp1}")"
  lb_ip="$(_ip "${lb}")"
  e2e::log "cp1=${cp_ip} lb=${lb_ip}"
  _check_lb "${cp_ip}" "${lb_ip}" \
    && e2e::check "00-configure-lb.sh --check-api --strict via LB" true "${lb_ip}:6443" \
    || e2e::check "00-configure-lb.sh --check-api --strict via LB" false
  # 使われていない IP（サブネット末尾）では --strict が失敗する
  if _check_lb "${cp_ip}" "${lb_ip%.*}.254"; then
    e2e::check "00-configure-lb.sh --strict fails for an unreachable endpoint" false
  else
    e2e::check "00-configure-lb.sh --strict fails for an unreachable endpoint" true
  fi

  e2e::log "pause ${cp2} (1 of 3): quorum must hold"
  docker pause "${cp2}" >/dev/null && PAUSED+=("${cp2}")
  if _wait_until 60 _readyz_ok; then
    e2e::check "1 CP paused: API /readyz ok via LB" true
  else
    e2e::check "1 CP paused: API /readyz ok via LB" false
  fi
  e2e::kubectl --request-timeout=20s -n default create configmap "e2e-ha-1cp-${RANDOM}" >/dev/null 2>&1 \
    && e2e::check "1 CP paused: write succeeds (etcd quorum 2/3)" true \
    || e2e::check "1 CP paused: write succeeds (etcd quorum 2/3)" false

  e2e::log "pause ${cp3} too (2 of 3): quorum lost"
  docker pause "${cp3}" >/dev/null && PAUSED+=("${cp3}")
  sleep 10
  if e2e::kubectl --request-timeout=15s -n default create configmap "e2e-ha-2cp-${RANDOM}" >/dev/null 2>&1; then
    e2e::check "2 CP paused: write fails (quorum lost)" false
  else
    e2e::check "2 CP paused: write fails (quorum lost)" true
  fi

  e2e::log "unpause both: cluster must recover"
  _unpause_all
  if _wait_until 300 _readyz_ok && _wait_until 300 _all_cps_ready; then
    e2e::check "recovered: /readyz ok and 3 CP Ready within 5 min" true
  else
    e2e::check "recovered: /readyz ok and 3 CP Ready within 5 min" false "ready CPs: $(_ready_cps)"
  fi
  e2e::kubectl --request-timeout=20s -n default create configmap "e2e-ha-recovered-${RANDOM}" >/dev/null 2>&1 \
    && e2e::check "recovered: write succeeds" true || e2e::check "recovered: write succeeds" false
}
