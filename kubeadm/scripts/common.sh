#!/bin/bash
# Shared variables for kubeadm bootstrap scripts (Linux target nodes only).
# Source from other scripts: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

# Kubernetes patch version (1.29+). Override: export K8S_VERSION=v1.30.4
K8S_VERSION="${K8S_VERSION:-v1.29.15}"

# Debian/Ubuntu apt repository uses major.minor without patch
K8S_APT_VERSION="${K8S_APT_VERSION:-$(echo "${K8S_VERSION}" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')}"

# Pod / Service CIDR (must match kubeadm-config.yaml)
POD_SUBNET="${POD_SUBNET:-192.168.0.0/16}"
SERVICE_SUBNET="${SERVICE_SUBNET:-10.96.0.0/12}"

# CNI: calico (default) or cilium
CNI="${CNI:-calico}"

# StorageClass created by local-path-provisioner addon
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"

# Repo root (kubeadm/scripts -> repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBEADM_DIR="${REPO_ROOT}/kubeadm"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (sudo)."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}
