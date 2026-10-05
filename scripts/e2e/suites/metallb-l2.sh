# shellcheck shell=bash
# #19 MetalLB（L2）: kubeadm/addons/metallb を kind の Docker ネットワーク上で動かし、
# LoadBalancer Service に IP が割り当てられて外（kind ネットワーク上のコンテナ）から届くことを検証する。
# クラスタ全体に MetalLB を入れるので kind 専用（稼働中の既存クラスタには入れない）。
# 設計: docs/design/k8s-native-backlog-redesign.md「#19」
SUITE_ISSUE="#19"
SUITE_DESC="MetalLB L2: LoadBalancer IP の割り当て / 外部から HTTP 200 / プール外の要求は割り当てない"
SUITE_TARGETS="kind"
SUITE_TARGETS_REASON="installs MetalLB cluster-wide and needs the kind docker network"
SUITE_DUMP_NAMESPACES=(metallb-system e2e-metallb)

ADDON_DIR="${E2E_ROOT}/kubeadm/addons/metallb"

_wait_until() {
  local timeout="$1" start=${SECONDS}
  shift
  until "$@"; do
    (( SECONDS - start >= timeout )) && return 1
    sleep 3
  done
}

# kind ネットワークの IPv4 サブネット（例 172.18.0.0/16）から、末尾の .255.200-.255.250 をプールにする
_pool_range() {
  local subnet a b
  subnet="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.')"
  [[ "${subnet}" == */16 ]] || { echo "unexpected kind subnet: ${subnet}" >&2; return 1; }
  IFS=. read -r a b _ <<<"${subnet}"
  echo "${a}.${b}.255.200-${a}.${b}.255.250"
}

_apply_pool() {  # <range>
  sed "s|192.168.1.240-192.168.1.250|$1|" "${ADDON_DIR}/ipaddresspool.yaml" | e2e::kubectl apply -f - >/dev/null 2>&1
}

_lb_ip() { e2e::kubectl -n e2e-metallb get svc "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null; }
_has_lb_ip() { [[ -n "$(_lb_ip "$1")" ]]; }

_in_range() {  # <ip> <a.b.c.lo-a.b.c.hi>
  local ip="$1" lo="${2%-*}" hi="${2#*-}"
  [[ "${ip%.*}" == "${lo%.*}" ]] && (( ${ip##*.} >= ${lo##*.} && ${ip##*.} <= ${hi##*.} ))
}

suite_main() {
  local url
  url="$(sed -n 's|^ *- \(https://.*metallb-native.yaml\)$|\1|p' "${ADDON_DIR}/kustomization.yaml")"
  [[ -n "${url}" ]] || { e2e::check "metallb manifest URL in kubeadm/addons/metallb" false; return 1; }
  e2e::log "install MetalLB: ${url}"
  e2e::kubectl apply -f "${url}" >/dev/null
  e2e::kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=300s >/dev/null \
    && e2e::check "controller Available" true || { e2e::check "controller Available" false; return 1; }
  e2e::kubectl -n metallb-system rollout status ds/speaker --timeout=300s >/dev/null \
    && e2e::check "speaker Ready on all nodes" true || e2e::check "speaker Ready on all nodes" false

  # CRD と webhook の準備ができるまで CR は拒否されるので、IPAddressPool は通るまで再試行する
  local range
  range="$(_pool_range)"
  e2e::log "IPAddressPool ${range}"
  _wait_until 120 _apply_pool "${range}" \
    && e2e::check "IPAddressPool applied (webhook ready)" true "${range}" \
    || { e2e::check "IPAddressPool applied (webhook ready)" false; return 1; }

  e2e::claim_namespace e2e-metallb
  e2e::kubectl -n e2e-metallb create deployment web --image=nginx:1.27-alpine --port=80 >/dev/null
  e2e::kubectl -n e2e-metallb expose deployment web --type=LoadBalancer --port=80 >/dev/null
  e2e::kubectl -n e2e-metallb rollout status deploy/web --timeout=180s >/dev/null

  local ip=""
  if _wait_until 60 _has_lb_ip web; then
    ip="$(_lb_ip web)"
  fi
  if [[ -n "${ip}" ]] && _in_range "${ip}" "${range}"; then
    e2e::check "LoadBalancer IP assigned from the pool within 60s" true "${ip}"
  else
    e2e::check "LoadBalancer IP assigned from the pool within 60s" false "ip=${ip:-<none>}"
    return 1
  fi

  # ホストではなく kind ネットワーク上のコンテナから確かめる（Docker Desktop でも CI でも同じ）
  local code
  code="$(docker run --rm --network kind curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${ip}/" || true)"
  e2e::assert_eq "HTTP from kind network to ${ip}" "${code}" 200

  e2e::log "negative: request an IP outside the pool"
  e2e::kubectl -n e2e-metallb apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web-outside
  annotations:
    metallb.universe.tf/loadBalancerIPs: 10.255.255.1
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
    - port: 80
EOF
  if _wait_until 30 _has_lb_ip web-outside; then
    e2e::check "IP outside the pool is NOT assigned" false "got $(_lb_ip web-outside)"
  else
    e2e::check "IP outside the pool is NOT assigned" true
  fi
}
