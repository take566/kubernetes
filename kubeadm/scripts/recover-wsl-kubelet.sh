#!/bin/bash
# Recover kubelet on WSL2 after swap or Docker Desktop breaks /proc/mounts parsing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
require_root() { [[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }; }
require_root
if swapon --show | grep -q .; then swapoff -a; fi
if bash "${SCRIPT_DIR}/check-wsl-mounts.sh" 2>/dev/null | grep -q .; then
  echo "Unmounting /Docker/host (Docker Desktop WSL integration workaround)..."
  umount /Docker/host 2>/dev/null || true
fi
systemctl restart containerd
systemctl restart kubelet
sleep 5
systemctl is-active kubelet
