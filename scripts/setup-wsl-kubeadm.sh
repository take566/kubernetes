#!/usr/bin/env bash
# WSL2 (Ubuntu) single-node kubeadm + NVIDIA vLLM helper.
# Run inside Ubuntu-24.04: bash scripts/setup-wsl-kubeadm.sh
set -euo pipefail

REPO_WIN="/mnt/c/work/kubernetes"
REPO="${REPO:-$HOME/kubernetes-wsl}"
DISTRO="${WSL_DISTRO:-Ubuntu-24.04}"

log() { echo "[setup-wsl] $*"; }
die() { echo "[setup-wsl] ERROR: $*" >&2; exit 1; }

if [[ ! -f /proc/driver/nvidia/version ]] && ! command -v nvidia-smi >/dev/null 2>&1; then
  die "nvidia-smi not found in WSL. Enable GPU in .wslconfig and update Windows NVIDIA driver."
fi

log "Syncing repo to ${REPO} (dos2unix for shell scripts)"
rm -rf "${REPO}"
cp -a "${REPO_WIN}" "${REPO}"
if command -v dos2unix >/dev/null 2>&1; then
  find "${REPO}" -name '*.sh' -exec dos2unix -q {} \;
else
  apt-get update -qq && apt-get install -y -qq dos2unix
  find "${REPO}" -name '*.sh' -exec dos2unix -q {} \;
fi
chmod +x "${REPO}/kubeadm/bootstrap.sh" "${REPO}/kubeadm/scripts/"*.sh "${REPO}/kubeadm/addons/apply-addons.sh"

log "Ensuring containerd starts before kubelet"
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/after-containerd.conf <<'UNIT'
[Unit]
After=containerd.service
Requires=containerd.service
UNIT
systemctl daemon-reload
systemctl enable --now containerd

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Installing NVIDIA Container Toolkit (containerd GPU runtime)"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=containerd
  systemctl restart containerd
fi

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log "Bootstrapping kubeadm (init + Calico + addons)"
  IP="$(hostname -I | tr -d '\n' | cut -d' ' -f1)"
  export CONTROL_PLANE_IP="${IP}"
  cd "${REPO}"
  ./kubeadm/bootstrap.sh --role init --with-nvidia
else
  log "Cluster already initialized; skipping kubeadm init"
  systemctl enable --now kubelet
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
kubectl taint nodes "${NODE}" node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl label node "${NODE}" nvidia.com/gpu.present=true workload=vllm --overwrite

log "Deploy vLLM (GTX 1650 overlay)"
kubectl apply -k "${REPO}/vllm/overlays/kubeadm/gtx1650/"

cat <<EOF

Done (or continue manually if API was not ready).
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl get nodes -o wide
  kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
  kubectl -n vllm get pods -w
  kubectl -n vllm port-forward svc/vllm 8000:8000
  # or NodePort http://<WSL-IP>:30800/health

See docs/WSL_KUBEADM_GPU.md for troubleshooting.
EOF
