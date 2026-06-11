#!/bin/bash
# Integration tests for kubeadm addons on the current kubectl context.
# Safe to run on kind-dev (smoke) or kubeadm-prod (after bootstrap).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export no_proxy='127.0.0.1,localhost'

PASS=0
FAIL=0
note() { echo "[INFO] $*"; }
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1" >&2; FAIL=$((FAIL + 1)); }

note "Context: $(kubectl config current-context 2>/dev/null || echo unknown)"
note "=== Phase 1: cluster baseline ==="

kubectl cluster-info >/dev/null 2>&1 && ok "cluster-info" || bad "cluster-info"
kubectl get nodes --no-headers 2>/dev/null | grep -q Ready && ok "nodes Ready" || bad "nodes Ready"
kubectl get storageclass local-path >/dev/null 2>&1 && ok "local-path StorageClass" || bad "local-path StorageClass"

note "=== Phase 2: metrics-server ==="
if kubectl -n kube-system get deployment metrics-server >/dev/null 2>&1; then
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s >/dev/null 2>&1 && ok "metrics-server Ready" || bad "metrics-server Ready"
else
  note "metrics-server not deployed — applying base addons"
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/" && ok "base addons applied" || bad "base addons apply"
fi

note "=== Phase 3: ingress-nginx ==="
if ! kubectl -n ingress-nginx get daemonset ingress-nginx-controller >/dev/null 2>&1; then
  kubectl apply -k "${REPO_ROOT}/kubeadm/addons/ingress-nginx/" && ok "ingress-nginx applied" || bad "ingress-nginx apply"
fi
if "${SCRIPT_DIR}/verify-ingress.sh"; then ok "ingress echo test"; else bad "ingress echo test"; fi

note "=== Phase 4: MetalLB (optional) ==="
if kubectl -n metallb-system get deployment controller >/dev/null 2>&1; then
  kubectl -n metallb-system rollout status deployment/controller --timeout=120s >/dev/null 2>&1 && ok "metallb controller" || bad "metallb controller"
  kubectl apply -f "${REPO_ROOT}/kubeadm/addons/metallb/ipaddresspool.yaml" >/dev/null 2>&1 || true
  kubectl get ipaddresspool -n metallb-system default >/dev/null 2>&1 && ok "metallb IPAddressPool" || bad "metallb IPAddressPool"
else
  note "MetalLB not installed — skip (use apply-addons.sh --with-metallb on LAN cluster)"
  ok "metallb skip"
fi

note "=== Phase 5: network policies (opt-in) ==="
for ns in argocd ingress-nginx longhorn-system; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
done
if kubectl apply -k "${REPO_ROOT}/kubeadm/addons/network-policies/" >/dev/null 2>&1; then
  ok "network-policies applied"
else
  bad "network-policies apply"
fi

note "=== Phase 6: bootstrap dry-run ==="
"${REPO_ROOT}/kubeadm/bootstrap.sh" --role init --dry-run --with-ingress --with-metallb >/dev/null 2>&1 && ok "bootstrap init dry-run" || bad "bootstrap init dry-run"

note "=== Phase 7: PVC bind test (local-path) ==="
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-test-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-test-pvc-pod
  namespace: default
spec:
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.9
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: smoke-test-pvc
  restartPolicy: Never
EOF
kubectl wait --for=condition=Ready pod/smoke-test-pvc-pod --timeout=120s >/dev/null 2>&1 && ok "PVC bound (local-path)" || bad "PVC bound (local-path)"
kubectl delete pod smoke-test-pvc-pod pvc smoke-test-pvc --ignore-not-found >/dev/null 2>&1 || true

echo ""
echo "=== Integration results: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
