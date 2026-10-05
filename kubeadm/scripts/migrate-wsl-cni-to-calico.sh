#!/bin/bash
# WSL 単一ノード kubeadm の CNI を bridge（/etc/cni/net.d の *.conflist）から Calico に移行する（#63）。
# NetworkPolicy を効かせるのが目的（bridge CNI は NetworkPolicy を実装しない）。
#
# Usage (WSL, root):
#   sudo KUBECONFIG=/etc/kubernetes/admin.conf ./kubeadm/scripts/migrate-wsl-cni-to-calico.sh --dry-run
#   sudo KUBECONFIG=/etc/kubernetes/admin.conf ./kubeadm/scripts/migrate-wsl-cni-to-calico.sh --yes
#   sudo KUBECONFIG=/etc/kubernetes/admin.conf ./kubeadm/scripts/migrate-wsl-cni-to-calico.sh --rollback --yes
#
# 動作:
#   1. Calico（CALICO_VERSION）の manifest を取得し、IP プールを cluster の podSubnet に合わせる。
#      単一ノードなのでカプセル化（IPIP / VXLAN）は使わない
#   2. 適用して calico-node / calico-kube-controllers の Ready を待つ
#   3. Calico 以外の k8s 用 conflist を BACKUP_DIR に退避する（nerdctl-bridge.conflist は nerdctl 用なので残す）
#   4. hostNetwork 以外の稼働中 Pod を作り直して Calico の IP に移し、旧 bridge（cni0）を消す
#   5. CoreDNS と Pod からの DNS / API 疎通を確かめる
# 移行中は全ワークロードが数分止まる（PVC のデータには影響しない）。
#
# 終了コード: 0=成功 / 1=失敗 / 2=引数エラー

set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.32.2}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/cni-migration}"
DRY_RUN=false
ROLLBACK=false
YES=false

log() { echo "[$(date +'%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --rollback) ROLLBACK=true ;;
    --yes) YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
kubectl get --raw /readyz >/dev/null || die "cluster is not reachable (set KUBECONFIG=/etc/kubernetes/admin.conf)"
[[ "${DRY_RUN}" == true || "${YES}" == true ]] || die "this restarts every workload pod; pass --yes (or --dry-run first)"

NODES="$(kubectl get nodes -o name | wc -l)"
[[ "${NODES}" -eq 1 ]] || die "expected a single-node cluster (found ${NODES}); this script is for WSL single-node only"

POD_CIDR="$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' \
  | sed -n 's/^ *podSubnet: *//p' | head -1)"
[[ -n "${POD_CIDR}" ]] || die "podSubnet not found in kubeadm-config"

MANIFEST="$(mktemp --suffix=-calico.yaml)"
trap 'rm -f "${MANIFEST}"' EXIT

render_manifest() {
  log "download Calico ${CALICO_VERSION} manifest"
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o "${MANIFEST}"
  # 既定の 192.168.0.0/16（コメントアウトされている）を有効にして podSubnet に置き換え、IPIP を無効にする
  sed -i \
    -e 's|^\( *\)# - name: CALICO_IPV4POOL_CIDR|\1- name: CALICO_IPV4POOL_CIDR|' \
    -e 's|^\( *\)#   value: "192.168.0.0/16"|\1  value: "'"${POD_CIDR}"'"|' \
    "${MANIFEST}"
  sed -i '/- name: CALICO_IPV4POOL_IPIP/{n;s|value: "Always"|value: "Never"|}' "${MANIFEST}"
  # 置き換えが効いたことを確かめる（manifest の書式が変わったら止める）
  grep -A1 -- '- name: CALICO_IPV4POOL_CIDR' "${MANIFEST}" | grep -q "value: \"${POD_CIDR}\"" \
    || die "failed to set CALICO_IPV4POOL_CIDR in manifest (format changed?)"
  grep -A1 -- '- name: CALICO_IPV4POOL_IPIP' "${MANIFEST}" | grep -q 'value: "Never"' \
    || die "failed to set CALICO_IPV4POOL_IPIP=Never in manifest (format changed?)"
  grep -A1 -- '- name: CALICO_IPV4POOL_VXLAN' "${MANIFEST}" | grep -q 'value: "Never"' \
    || die "unexpected CALICO_IPV4POOL_VXLAN in manifest"
}

# hostNetwork 以外で、Running / Pending の Pod を作り直す（Job の完了済み Pod は触らない）
restart_workload_pods() {
  local pods
  pods="$(kubectl get pods -A -o json | jq -r '.items[]
    | select(.spec.hostNetwork != true)
    | select(.status.phase == "Running" or .status.phase == "Pending")
    | "\(.metadata.namespace) \(.metadata.name)"')"
  if [[ -z "${pods}" ]]; then
    log "no workload pods to restart"
    return 0
  fi
  log "restart $(wc -l <<<"${pods}") workload pods"
  local ns name
  while read -r ns name; do
    run kubectl -n "${ns}" delete pod "${name}" --wait=false
  done <<<"${pods}"
  [[ "${DRY_RUN}" == true ]] && return 0
  sleep 10
  local kind
  for kind in deploy statefulset daemonset; do
    while read -r ns name; do
      [[ -n "${ns}" ]] || continue
      kubectl -n "${ns}" rollout status "${kind}/${name}" --timeout=600s || log "WARN: ${kind} ${ns}/${name} not ready"
    done < <(kubectl get "${kind}" -A -o json | jq -r '.items[] | select(.spec.template.spec.hostNetwork != true) | "\(.metadata.namespace) \(.metadata.name)"')
  done
}

verify() {
  log "verify: CoreDNS / DNS / API from a pod"
  kubectl -n kube-system rollout status deploy/coredns --timeout=300s
  local out
  # DNS で解決でき、API に届けば（200 / 401 / 403 のどれか）OK
  out="$(kubectl run "cni-verify-$$" --rm -i --quiet --restart=Never --image=curlimages/curl:8.10.1 --command -- \
    sh -c 'nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo dns-ok;
           curl -sk -o /dev/null -w "api-%{http_code}\n" --max-time 10 https://kubernetes.default.svc/version' 2>&1 || true)"
  grep -q dns-ok <<<"${out}" || die "DNS from a pod failed: ${out}"
  grep -qE 'api-(200|401|403)' <<<"${out}" || die "API from a pod failed: ${out}"
  log "pod network OK (${out//$'\n'/ })"
}

migrate() {
  render_manifest
  local backup="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  log "backup dir: ${backup}"
  run mkdir -p "${backup}"
  run cp -a /etc/cni/net.d/. "${backup}/"

  log "apply Calico ${CALICO_VERSION} (pool ${POD_CIDR}, IPIP/VXLAN Never)"
  run kubectl apply --server-side --force-conflicts -f "${MANIFEST}"
  if [[ "${DRY_RUN}" != true ]]; then
    kubectl -n kube-system rollout status ds/calico-node --timeout=600s
    kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=600s
    [[ -f /etc/cni/net.d/10-calico.conflist ]] || die "calico did not install /etc/cni/net.d/10-calico.conflist"
  fi

  # Calico 以外の k8s 用 conflist を退避する（containerd は辞書順で最初の conflist を使う）
  local f
  for f in /etc/cni/net.d/*.conflist; do
    case "$(basename "${f}")" in
      10-calico.conflist|nerdctl-bridge.conflist) ;;
      *) log "move aside ${f}"; run mv "${f}" "${backup}/disabled-$(basename "${f}")" ;;
    esac
  done

  restart_workload_pods
  if ip link show cni0 >/dev/null 2>&1; then
    log "remove old bridge cni0"
    run ip link delete cni0
  fi
  [[ "${DRY_RUN}" == true ]] || verify
  log "done. rollback: $0 --rollback --yes  (backup: ${backup})"
}

rollback() {
  local backup
  backup="$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | tail -1)"
  [[ -n "${backup}" ]] || die "no backup under ${BACKUP_ROOT}"
  render_manifest
  log "rollback using ${backup}"
  run kubectl delete --ignore-not-found -f "${MANIFEST}"
  run rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig
  local f
  for f in "${backup}"/disabled-*.conflist; do
    [[ -e "${f}" ]] || continue
    run cp -a "${f}" "/etc/cni/net.d/$(basename "${f}" | sed 's/^disabled-//')"
  done
  restart_workload_pods
  [[ "${DRY_RUN}" == true ]] || verify
  log "rollback done"
}

if [[ "${ROLLBACK}" == true ]]; then rollback; else migrate; fi
