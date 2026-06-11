#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/lib/wsl/lib:${PATH}"
export KUBECONFIG=/etc/kubernetes/admin.conf
REPO=/root/kubernetes-wsl
cp -a /mnt/c/work/kubernetes "$REPO"
find "$REPO" -name '*.sh' -exec sed -i 's/\r$//' {} \;

mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/after-containerd.conf <<'UNIT'
[Unit]
After=containerd.service

[Service]
ExecStartPre=/bin/bash -c 'until [ -S /run/containerd/containerd.sock ]; do sleep 1; done'
UNIT
systemctl daemon-reload
systemctl restart containerd
sleep 3
systemctl restart kubelet

wait_api() {
  for i in $(seq 1 120); do
    curl -sk https://127.0.0.1:6443/healthz 2>/dev/null | grep -q ok && return 0
    sleep 2
  done
  return 1
}
wait_api

curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml -o /tmp/calico.yaml
kubectl apply --validate=false -f /tmp/calico.yaml

kubectl apply -k "${REPO}/kubeadm/addons/"
kubectl apply -k "${REPO}/kubeadm/addons/nvidia-device-plugin/"

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "${NODE}" node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl label node "${NODE}" nvidia.com/gpu.present=true workload=vllm --overwrite

for i in $(seq 1 60); do
  kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True && break
  sleep 5
done

kubectl apply -k "${REPO}/vllm/overlays/kubeadm/gtx1650/"

for i in $(seq 1 180); do
  PHASE=$(kubectl -n vllm get pods -l app=vllm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo Pending)
  echo "vllm phase=${PHASE} iter=${i}"
  [[ "${PHASE}" == "Running" ]] && break
  sleep 10
done

kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.allocatable.nvidia\\.com/gpu
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl -n vllm get pods -o wide

IP=$(hostname -I | awk '{print $1}')
curl -sf "http://${IP}:30800/health" && echo health_ok || echo health_fail

# minimal chat test
curl -sf "http://${IP}:30800/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' | head -c 400
echo
