# shellcheck shell=bash
# #30 Calico + kubeadm/addons/network-policies の下で CoreDNS / API 疎通が保たれることの回帰テスト。
# 陰性テスト: 修正前（4dfc38f^）のポリシーでは kube-system から API に届かず、CoreDNS が Ready にならないこと。
# kube-system の NetworkPolicy と CNI を前提にするため kind 専用。
# 設計: docs/design/k8s-native-backlog-redesign.md「#30」
SUITE_ISSUE="#30"
SUITE_DESC="Calico + network-policies で CoreDNS / API 疎通（修正前ポリシーで失敗する陰性テスト付き）"
SUITE_CLUSTER_CONFIG="${E2E_ROOT}/kind/test-cluster-calico.yaml"
SUITE_KIND_WAIT=0
SUITE_TARGETS="kind"
SUITE_TARGETS_REASON="installs Calico and rewrites kube-system NetworkPolicies"
SUITE_DUMP_NAMESPACES=(kube-system)

CALICO_VERSION="${CALICO_VERSION:-v3.27.3}"   # kubeadm/scripts/05-install-cni.sh と同じ
NETPOL_DIR="${E2E_ROOT}/kubeadm/addons/network-policies"
PRE_FIX_DIR="${E2E_ROOT}/scripts/e2e/fixtures/netpol-pre-4dfc38f"
# 4dfc38f で追加された許可（修正前には存在しない）
ADDON_EGRESS=(allow-coredns-egress allow-calico-controllers-egress allow-calico-node-egress)

suite_bootstrap() {
  e2e::log "install Calico ${CALICO_VERSION}"
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    | e2e::kubectl apply --validate=false -f - >/dev/null
  e2e::kubectl -n kube-system rollout status ds/calico-node --timeout=600s
  e2e::kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=600s
}

# kube-system の一時 Pod から DNS と API への到達を調べ、JSON（{"dns":bool,"api":<code>|"unreachable"}）を出す。
# 修正前ポリシーは kube-system の podSelector: {} に効くので、観測は kube-system で行う
_probe_kube_system() {
  e2e::kubectl -n kube-system run "e2e-probe-${RANDOM}" --rm -i --quiet --restart=Never \
    --image=python:3.11-slim-bookworm --command -- python -c '
import json, socket, ssl, urllib.error, urllib.request
r = {}
try:
    socket.getaddrinfo("kubernetes.default.svc.cluster.local", 443)
    r["dns"] = True
except OSError:
    r["dns"] = False
try:
    urllib.request.urlopen("https://10.96.0.1:443/version", context=ssl._create_unverified_context(), timeout=8)
    r["api"] = 200
except urllib.error.HTTPError as e:
    r["api"] = e.code
except Exception:
    r["api"] = "unreachable"
print(json.dumps(r))
' 2>/dev/null | tail -1
}

# API に届いていれば 200/401/403 のどれでもよい
_api_reached() { jq -e '.api | . == 200 or . == 401 or . == 403' >/dev/null 2>&1 <<<"$1"; }

_coredns_restart_ready() {  # <timeout>
  e2e::kubectl -n kube-system rollout restart deploy/coredns >/dev/null
  e2e::kubectl -n kube-system rollout status deploy/coredns --timeout="$1" >/dev/null 2>&1
}

_apply_current_policies() {
  e2e::kubectl apply -k "${NETPOL_DIR}" >/dev/null
}

_apply_pre_fix_policies() {
  # 4dfc38f の差分は allow-dns.yaml の変更と addon-egress の追加だけなので、
  # 「旧 allow-dns.yaml を適用 + addon-egress を削除」で修正前の一式と同じ状態になる
  e2e::kubectl apply -f "${PRE_FIX_DIR}/allow-dns.yaml" >/dev/null
  e2e::kubectl -n kube-system delete networkpolicy "${ADDON_EGRESS[@]}" --ignore-not-found >/dev/null
}

_check_healthy() {  # <label>
  local label="$1" probe
  e2e::kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=180s >/dev/null 2>&1 \
    && e2e::check "${label}: CoreDNS Ready" true || e2e::check "${label}: CoreDNS Ready" false
  e2e::assert_ge "${label}: kube-dns endpoints" \
    "$(e2e::kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns -o json \
        | jq '[.items[].endpoints[]? | select(.conditions.ready)] | length')" 1
  probe="$(_probe_kube_system)"
  e2e::assert_eq "${label}: DNS resolves kubernetes.default" "$(jq -r '.dns' <<<"${probe}" 2>/dev/null)" true
  _api_reached "${probe}" && e2e::check "${label}: API reachable from kube-system" true "${probe}" \
    || e2e::check "${label}: API reachable from kube-system" false "${probe:-<no output>}"
  e2e::assert_eq "${label}: calico-kube-controllers ready" \
    "$(e2e::kubectl -n kube-system get deploy calico-kube-controllers -o jsonpath='{.status.readyReplicas}')" 1
}

suite_main() {
  e2e::kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=300s >/dev/null

  # ポリシーが対象にする名前空間（kind には無い）
  local ns
  for ns in argocd ingress-nginx longhorn-system; do
    e2e::kubectl create ns "${ns}" --dry-run=client -o yaml | e2e::kubectl apply -f - >/dev/null
  done

  e2e::log "current policies (kubeadm/addons/network-policies)"
  _apply_current_policies
  _coredns_restart_ready 180s && e2e::check "current: restarted CoreDNS becomes Ready" true \
    || e2e::check "current: restarted CoreDNS becomes Ready" false
  _check_healthy current

  e2e::log "negative: pre-fix policies (4dfc38f^) must break kube-system -> API"
  _apply_pre_fix_policies
  sleep 10
  local probe
  probe="$(_probe_kube_system)"
  if _api_reached "${probe}"; then
    e2e::check "pre-fix: API is NOT reachable from kube-system" false "${probe}"
  else
    e2e::check "pre-fix: API is NOT reachable from kube-system" true "${probe:-<no output>}"
  fi
  if _coredns_restart_ready 120s; then
    e2e::check "pre-fix: restarted CoreDNS does NOT become Ready in 120s" false
  else
    e2e::check "pre-fix: restarted CoreDNS does NOT become Ready in 120s" true
  fi

  e2e::log "restore current policies and verify recovery"
  _apply_current_policies
  e2e::kubectl -n kube-system rollout status deploy/coredns --timeout=300s >/dev/null 2>&1 \
    && e2e::check "recovered: CoreDNS rollout completes" true || e2e::check "recovered: CoreDNS rollout completes" false
  _check_healthy recovered

  # diagnose-cluster-dns.sh は警告でも exit 0 なので合否には使わず、出力を artifact に残す
  local kc
  kc="$(mktemp)"
  kind get kubeconfig --name "${E2E_CLUSTER}" > "${kc}"
  KUBECONFIG="${kc}" bash "${E2E_ROOT}/kubeadm/scripts/diagnose-cluster-dns.sh" \
    > "${E2E_RESULTS_DIR}/${E2E_SUITE}-diagnose.txt" 2>&1 || true
  rm -f "${kc}"
}
