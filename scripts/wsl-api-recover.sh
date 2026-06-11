#!/usr/bin/env bash
# Recover Kubernetes API when Calico CNI cannot tear down sandboxes while apiserver is down (WSL kubeadm).
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/cni-backup
if [ -f /etc/cni/net.d/10-calico.conflist ]; then
  mv /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig /root/cni-backup/ 2>/dev/null || true
fi
cat >/etc/cni/net.d/10-loopback.conf <<EOF
{
  "cniVersion": "0.3.1",
  "name": "loopback",
  "type": "loopback"
}
EOF
if ! curl -sk https://127.0.0.1:6443/healthz 2>/dev/null | grep -q ok; then
  systemctl stop kubelet
  crictl rmp -fa 2>/dev/null || true
  systemctl restart containerd
  sleep 3
  systemctl start kubelet
fi
for i in $(seq 1 90); do
  if curl -sk https://127.0.0.1:6443/healthz 2>/dev/null | grep -q ok; then
    echo "API healthy (attempt $i)"
    if [ -f /root/cni-backup/10-calico.conflist ]; then
      cp /root/cni-backup/10-calico.conflist /root/cni-backup/calico-kubeconfig /etc/cni/net.d/ 2>/dev/null || true
    fi
    exit 0
  fi
  sleep 2
done
echo "API still down after loopback bootstrap" >&2
exit 1