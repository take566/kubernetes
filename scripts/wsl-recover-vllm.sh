#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/lib/wsl/lib:${PATH}"
export KUBECONFIG=/etc/kubernetes/admin.conf
systemctl restart containerd
sleep 4
systemctl restart kubelet
for i in $(seq 1 90); do curl -sk https://127.0.0.1:6443/healthz 2>/dev/null | grep -q ok && break; sleep 2; done

kubectl apply -f - <<'RC'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
RC

kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type=json --patch-file /mnt/c/work/kubernetes/kubeadm/addons/nvidia-device-plugin/wsl-patch.json || true
sleep 20

kubectl patch deployment vllm -n vllm --type=json -p='[{"op":"add","path":"/spec/template/spec/runtimeClassName","value":"nvidia"}]' || true

kubectl get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status,GPU:.status.allocatable.nvidia\\.com/gpu
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl -n vllm get pods -o wide
kubectl -n vllm describe pod -l app=vllm | tail -12
