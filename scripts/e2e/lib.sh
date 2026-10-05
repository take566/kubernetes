#!/bin/bash
# e2e スイート共通関数。scripts/e2e/run.sh から source される（単体実行はしない）。
# 設計: docs/design/k8s-native-backlog-redesign.md 1.2 節
#
# 実行先（E2E_TARGET）:
#   existing  既存クラスタ（WSL の kubeadm 単一ノードなど）。現在の kubeconfig / --context を使う。
#             クラスタは作らず消さない。e2e が作った名前空間（ラベル e2e.k8s/managed=true）だけを後片付けする
#   kind      kind クラスタを作って使う（CI 用。Docker が必要）

E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_TARGET="${E2E_TARGET:-existing}"
E2E_CLUSTER="${E2E_CLUSTER:-e2e}"
E2E_CONTEXT="${E2E_CONTEXT:-}"
E2E_KEEP="${E2E_KEEP:-false}"
E2E_RESULTS_DIR="${E2E_RESULTS_DIR:-${E2E_ROOT}/e2e-results}"
E2E_SUITE="${E2E_SUITE:-unknown}"
E2E_ISSUE="${E2E_ISSUE:-}"
E2E_MANAGED_LABEL="e2e.k8s/managed"
# チェック結果は JSONL に追記する（suite_main をサブシェルで動かしても失われないように）
E2E_CHECKS_FILE="${E2E_RESULTS_DIR}/${E2E_SUITE}.checks.jsonl"
mkdir -p "${E2E_RESULTS_DIR}"
: > "${E2E_CHECKS_FILE}"

[[ "${E2E_TARGET}" == kind && -z "${E2E_CONTEXT}" ]] && E2E_CONTEXT="kind-${E2E_CLUSTER}"

e2e::log() { echo "[e2e $(date +'%H:%M:%S')] $*"; }

e2e::kubectl() {
  if [[ -n "${E2E_CONTEXT}" ]]; then kubectl --context "${E2E_CONTEXT}" "$@"; else kubectl "$@"; fi
}

e2e::cluster_up() {
  local config="${1:-${E2E_ROOT}/kind/test-cluster.yaml}"
  if [[ "${E2E_TARGET}" == kind ]]; then
    if kind get clusters 2>/dev/null | grep -qx "${E2E_CLUSTER}"; then
      e2e::log "reuse kind cluster ${E2E_CLUSTER}"
    else
      e2e::log "create kind cluster ${E2E_CLUSTER} (${config})"
      # SUITE_KIND_WAIT=0: CNI を自前で入れる構成（disableDefaultCNI）ではノードが Ready にならないので待たない
      local wait_args=(--wait "${SUITE_KIND_WAIT:-180s}")
      [[ "${SUITE_KIND_WAIT:-}" == 0 ]] && wait_args=()
      kind create cluster --name "${E2E_CLUSTER}" --config "${config}" "${wait_args[@]}"
    fi
    # ノードの Ready を待つ前に入れるもの（CNI など）
    if declare -F suite_bootstrap >/dev/null; then suite_bootstrap; fi
  else
    e2e::log "use existing cluster (context: ${E2E_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo '<kubeconfig default>')})"
    e2e::kubectl get --raw /readyz >/dev/null || { echo "cluster is not reachable" >&2; return 1; }
  fi
  e2e::kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

e2e::cluster_down() {
  if [[ "${E2E_KEEP}" == true ]]; then
    e2e::log "keep resources (--keep)"
    return 0
  fi
  if [[ "${E2E_TARGET}" == kind ]]; then
    kind delete cluster --name "${E2E_CLUSTER}" >/dev/null 2>&1 || true
    return 0
  fi
  local ns
  for ns in $(e2e::kubectl get ns -l "${E2E_MANAGED_LABEL}=true" -o name 2>/dev/null); do
    e2e::log "delete ${ns} (created by e2e)"
    e2e::kubectl delete "${ns}" --wait=true --timeout=180s >/dev/null 2>&1 || true
  done
  # 名前空間を消したあとでクラスタスコープのリソース（PV など）を消す
  e2e::kubectl delete pv -l "${E2E_MANAGED_LABEL}=true" --wait=false >/dev/null 2>&1 || true
  if declare -F suite_cleanup >/dev/null; then suite_cleanup || true; fi
}

# 名前空間を e2e 管理として確保する。e2e 以外が作った既存の名前空間なら中止する（既存環境を壊さない）
e2e::claim_namespace() {
  local ns="$1"
  if e2e::kubectl get ns "${ns}" >/dev/null 2>&1; then
    if [[ "$(e2e::kubectl get ns "${ns}" -o jsonpath="{.metadata.labels.e2e\.k8s/managed}")" != true ]]; then
      echo "namespace ${ns} already exists and is not managed by e2e; refusing to touch it" >&2
      return 1
    fi
  else
    e2e::kubectl create ns "${ns}" >/dev/null
  fi
  e2e::kubectl label ns "${ns}" "${E2E_MANAGED_LABEL}=true" --overwrite >/dev/null
}

# hostPath PV は fsGroup が効かないため、全ノードでディレクトリを作り所有者を合わせる（root の一時 Pod）
e2e::prepare_hostpath() {
  local path="$1" owner="${2:-1000:1000}" ns="${3:-default}" node i=0
  for node in $(e2e::kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    local pod="e2e-hostpath-${i}"
    i=$((i + 1))
    e2e::kubectl -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=true >/dev/null
    e2e::kubectl -n "${ns}" run "${pod}" --restart=Never --image=busybox:1.36 --overrides="$(jq -cn \
      --arg node "${node}" --arg path "${path}" --arg owner "${owner}" '{
        spec: {
          nodeName: $node,
          tolerations: [{operator: "Exists"}],
          containers: [{
            name: "c", image: "busybox:1.36",
            command: ["sh", "-c", ("chown -R " + $owner + " /target")],
            securityContext: {runAsUser: 0},
            volumeMounts: [{name: "t", mountPath: "/target"}]
          }],
          volumes: [{name: "t", hostPath: {path: $path, type: "DirectoryOrCreate"}}]
        }}')" >/dev/null
    e2e::kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=120s >/dev/null
    e2e::kubectl -n "${ns}" delete pod "${pod}" --wait=false >/dev/null
  done
}

# NetworkPolicy が実際に適用されるかを試す（bridge CNI などは適用しない）。結果は E2E_NETPOL_ENFORCED に入れる
e2e::probe_netpol() {
  [[ -n "${E2E_NETPOL_ENFORCED:-}" ]] && return 0
  local ns=e2e-netpol-probe
  e2e::claim_namespace "${ns}"
  e2e::kubectl -n "${ns}" run srv --labels=app=srv --image=python:3.11-slim-bookworm \
    --command -- python -m http.server 8080 >/dev/null
  e2e::kubectl -n "${ns}" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-srv
spec:
  podSelector:
    matchLabels:
      app: srv
  policyTypes: [Ingress]
EOF
  e2e::kubectl -n "${ns}" wait --for=condition=Ready pod/srv --timeout=180s >/dev/null
  local ip
  ip="$(e2e::kubectl -n "${ns}" get pod srv -o jsonpath='{.status.podIP}')"
  sleep 5
  if e2e::kubectl -n "${ns}" run cli --rm -i --restart=Never --image=python:3.11-slim-bookworm --command -- \
      python -c "import socket; socket.create_connection(('${ip}', 8080), timeout=5)" >/dev/null 2>&1; then
    E2E_NETPOL_ENFORCED=false
  else
    E2E_NETPOL_ENFORCED=true
  fi
  e2e::kubectl delete ns "${ns}" --wait=false >/dev/null 2>&1 || true
  e2e::log "NetworkPolicy enforced: ${E2E_NETPOL_ENFORCED}"
}

# elk-stack/overlays/kind を適用し、ES / Logstash と setup Job の完了を待つ
e2e::deploy_elk() {
  e2e::claim_namespace elk-stack
  # PV はクラスタスコープなので名前空間の削除では消えない。e2e 以外の既存 PV なら中止する
  if e2e::kubectl get pv elasticsearch-pv >/dev/null 2>&1 \
     && [[ "$(e2e::kubectl get pv elasticsearch-pv -o jsonpath='{.metadata.labels.e2e\.k8s/managed}')" != true ]]; then
    echo "pv/elasticsearch-pv already exists and is not managed by e2e; refusing to touch it" >&2
    return 1
  fi
  e2e::prepare_hostpath /data/elasticsearch
  # elk-stack/base は親ディレクトリのファイルを参照するため load-restrictor を外す（scripts/kubeconform-validate.sh と同じ）
  e2e::kubectl kustomize --load-restrictor LoadRestrictionsNone "${E2E_ROOT}/elk-stack/overlays/kind" \
    | e2e::kubectl apply -f - >/dev/null
  e2e::kubectl label pv elasticsearch-pv "${E2E_MANAGED_LABEL}=true" --overwrite >/dev/null
  e2e::kubectl -n elk-stack rollout status deploy/elasticsearch --timeout=600s
  e2e::kubectl -n elk-stack rollout status deploy/logstash --timeout=600s
  e2e::kubectl -n elk-stack wait --for=condition=complete job/elasticsearch-serena-setup --timeout=300s
}

# テスト用の常駐 Pod（python）。送信と ES 問い合わせを exec で行う。
# label は Serena collector と同じにし、NetworkPolicy の許可経路を通す
e2e::toolbox_up() {
  local ns="${1:-elk-stack}" label="${2:-app=serena-collector}"
  e2e::kubectl -n "${ns}" delete pod e2e-toolbox --ignore-not-found --wait=true >/dev/null
  e2e::kubectl -n "${ns}" run e2e-toolbox --labels="${label}" --restart=Never \
    --image=python:3.11-slim-bookworm --command -- sleep 3600 >/dev/null
  e2e::kubectl -n "${ns}" wait --for=condition=Ready pod/e2e-toolbox --timeout=180s >/dev/null
}

# toolbox で python を実行する（stdin にスクリプト、引数はそのまま渡す）
e2e::toolbox_py() {
  local ns="${E2E_TOOLBOX_NS:-elk-stack}"
  e2e::kubectl -n "${ns}" exec -i e2e-toolbox -- python - "$@"
}

# ES に HTTP リクエストを送り、本文を出力する: e2e::es <METHOD> <path> [json-body]
e2e::es() {
  local method="$1" path="$2" body="${3:-}"
  e2e::toolbox_py "${method}" "${path}" "${body}" <<'PY'
import sys, urllib.request
method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://elasticsearch.elk-stack.svc:9200" + path,
                             data=body.encode() if body else None, method=method,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
PY
}

# 条件を記録する。失敗しても続行し、最後に e2e::finish で集計する
e2e::check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "${ok}" == true ]]; then
    echo "  OK:   ${name}${detail:+ (${detail})}"
  else
    echo "  FAIL: ${name}${detail:+ (${detail})}"
  fi
  jq -cn --arg n "${name}" --argjson ok "${ok}" --arg d "${detail}" '{name:$n,ok:$ok,detail:$d}' >> "${E2E_CHECKS_FILE}"
}

# 実行先の制約で検証できない項目。合格には数えず、結果に skipped として残す
e2e::skip() {
  local name="$1" reason="$2"
  echo "  SKIP: ${name} (${reason})"
  jq -cn --arg n "${name}" --arg d "${reason}" '{name:$n,ok:true,skipped:true,detail:$d}' >> "${E2E_CHECKS_FILE}"
}

e2e::assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then e2e::check "${name}" true "${got}"; else e2e::check "${name}" false "got=${got} want=${want}"; fi
}

e2e::assert_ge() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" =~ ^[0-9]+$ ]] && (( got >= want )); then e2e::check "${name}" true "${got}"; else e2e::check "${name}" false "got=${got} want>=${want}"; fi
}

# 失敗時に診断情報を e2e-results/ に保存する（CI の artifact）
e2e::dump_on_fail() {
  local ns dir="${E2E_RESULTS_DIR}/${E2E_SUITE}-dump"
  mkdir -p "${dir}"
  for ns in "$@"; do
    e2e::kubectl -n "${ns}" get all,events -o wide > "${dir}/${ns}-get.txt" 2>&1 || true
    e2e::kubectl -n "${ns}" describe pods > "${dir}/${ns}-describe.txt" 2>&1 || true
    local p
    for p in $(e2e::kubectl -n "${ns}" get pods -o name 2>/dev/null); do
      e2e::kubectl -n "${ns}" logs "${p}" --all-containers --tail=300 > "${dir}/${ns}-${p##*/}.log" 2>&1 || true
    done
  done
  e2e::log "dump saved: ${dir}"
}

# 結果 JSON を書き、失敗があれば 1 を返す
e2e::finish() {
  local passed
  # 検証できたチェック（skipped 以外）が 1 件も無い場合も失敗扱い（何も検証せずに通るのを防ぐ）
  passed="$(jq -s '([.[] | select(.skipped | not)] | length > 0) and all(.ok)' "${E2E_CHECKS_FILE}")"
  jq -s --arg s "${E2E_SUITE}" --arg i "${E2E_ISSUE}" --arg t "${E2E_TARGET}" --argjson p "${passed}" \
    '{suite:$s, issue:$i, target:$t, passed:$p, skipped:([.[] | select(.skipped)] | length), checks:.}' \
    "${E2E_CHECKS_FILE}" > "${E2E_RESULTS_DIR}/${E2E_SUITE}.json"
  e2e::log "result: ${E2E_RESULTS_DIR}/${E2E_SUITE}.json (passed=${passed}, target=${E2E_TARGET})"
  [[ "${passed}" == true ]]
}
