# shellcheck shell=bash
# #23 ストレージの PVC 契約テスト: vLLM のモデルキャッシュ PVC（vllm-model-cache）の要件（accessModes / 容量）で
# PVC を作り、書き込み → Pod 作り直し → 読み出しで内容（sha256）が一致することを確かめる。
# E2E_STORAGE_CLASS で StorageClass を切り替える（既定 local-path。実機の Longhorn では longhorn で同じテストを回す）。
# 設計: docs/design/k8s-native-backlog-redesign.md「#23」
SUITE_ISSUE="#23"
SUITE_DESC="PVC 契約（vllm-model-cache の要件で書き込み → Pod 作り直し → sha256 一致）/ longhorn overlay の差分"
SUITE_DUMP_NAMESPACES=(e2e-storage)

STORAGE_CLASS="${E2E_STORAGE_CLASS:-local-path}"
NS=e2e-storage

_kustomize() { e2e::kubectl kustomize --load-restrictor LoadRestrictionsNone "${E2E_ROOT}/$1"; }

_pvc_phase() { e2e::kubectl -n "${NS}" get pvc "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }

_pod_with_pvc() {  # <pod> <pvc> <command>
  e2e::kubectl -n "${NS}" delete pod "$1" --ignore-not-found --wait=true >/dev/null
  e2e::kubectl -n "${NS}" run "$1" --restart=Never --image=busybox:1.36 --overrides="$(jq -cn \
    --arg pvc "$2" --arg cmd "$3" '{spec: {containers: [{name: "c", image: "busybox:1.36",
      command: ["sh", "-c", $cmd], volumeMounts: [{name: "d", mountPath: "/data"}]}],
      volumes: [{name: "d", persistentVolumeClaim: {claimName: $pvc}}]}}')" >/dev/null
  e2e::kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=300s >/dev/null
}

suite_main() {
  # longhorn overlay は kubeadm overlay と StorageClass だけが違う（コピーした model-patch などのずれを検出する）
  local a b diffout
  a="$(mktemp)"; b="$(mktemp)"
  _kustomize vllm/overlays/kubeadm > "${a}"
  _kustomize vllm/overlays/kubeadm/longhorn > "${b}"
  diffout="$(diff "${a}" "${b}" | grep -E '^[<>]' || true)"
  rm -f "${a}" "${b}"
  if [[ "$(grep -c . <<<"${diffout}")" -eq 2 ]] \
      && grep -q '^<   storageClassName: local-path$' <<<"${diffout}" \
      && grep -q '^>   storageClassName: longhorn$' <<<"${diffout}"; then
    e2e::check "longhorn overlay differs from kubeadm only in storageClassName" true
  else
    e2e::check "longhorn overlay differs from kubeadm only in storageClassName" false "${diffout}"
  fi

  # vllm-model-cache の要件（kubeadm overlay から読む）
  local spec modes size
  spec="$(_kustomize vllm/overlays/kubeadm | e2e::kubectl create --dry-run=client --validate=false -o json -f - \
    | jq -cs '[.[] | (.items[]? // .) | select(.kind == "PersistentVolumeClaim" and .metadata.name == "vllm-model-cache")][0].spec')"
  modes="$(jq -c '.accessModes' <<<"${spec}")"
  size="$(jq -r '.resources.requests.storage' <<<"${spec}")"
  e2e::log "vllm-model-cache requirements: accessModes=${modes} size=${size}; StorageClass=${STORAGE_CLASS}"
  [[ "${modes}" != null && "${size}" != null ]] || { e2e::check "read vllm-model-cache requirements" false "${spec}"; return 1; }

  e2e::claim_namespace "${NS}"
  [[ "${STORAGE_CLASS}" == local-path ]] && e2e::ensure_local_path_sc
  e2e::kubectl get storageclass "${STORAGE_CLASS}" >/dev/null \
    || { e2e::check "StorageClass ${STORAGE_CLASS} exists" false; return 1; }

  jq -n --argjson modes "${modes}" --arg size "${size}" --arg sc "${STORAGE_CLASS}" \
    '{apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: {name: "contract"},
      spec: {accessModes: $modes, storageClassName: $sc, resources: {requests: {storage: $size}}}}' \
    | e2e::kubectl -n "${NS}" apply -f - >/dev/null

  e2e::log "write 32MiB random data"
  if _pod_with_pvc writer contract 'dd if=/dev/urandom of=/data/blob bs=1M count=32 2>/dev/null && sync && sha256sum /data/blob | cut -d" " -f1 > /data/blob.sha256'; then
    e2e::check "writer pod completed (PVC provisioned and writable)" true
  else
    e2e::check "writer pod completed (PVC provisioned and writable)" false; return 1
  fi
  e2e::assert_eq "PVC Bound" "$(_pvc_phase contract)" Bound
  e2e::kubectl -n "${NS}" delete pod writer --wait=true >/dev/null

  e2e::log "recreate a different pod and read back"
  if _pod_with_pvc reader contract 'echo "$(cat /data/blob.sha256) $(sha256sum /data/blob | cut -d" " -f1)"'; then
    local got
    got="$(e2e::kubectl -n "${NS}" logs reader)"
    read -r want actual <<<"${got}"
    if [[ -n "${want}" && "${want}" == "${actual}" ]]; then
      e2e::check "data survives pod recreation (sha256 match)" true "${actual:0:16}…"
    else
      e2e::check "data survives pod recreation (sha256 match)" false "${got}"
    fi
  else
    e2e::check "data survives pod recreation (sha256 match)" false "reader pod failed"
  fi

  # 陰性テスト: 存在しない StorageClass の PVC は Bound にならない（テストが無条件に通らないことの確認）
  jq -n --argjson modes "${modes}" \
    '{apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: {name: "bogus"},
      spec: {accessModes: $modes, storageClassName: "e2e-nonexistent-sc", resources: {requests: {storage: "1Gi"}}}}' \
    | e2e::kubectl -n "${NS}" apply -f - >/dev/null
  sleep 10
  e2e::assert_eq "PVC with a nonexistent StorageClass stays Pending" "$(_pvc_phase bogus)" Pending
}
