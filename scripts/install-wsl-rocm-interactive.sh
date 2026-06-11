#!/usr/bin/env bash
# Print copy-paste commands for interactive WSL ROCm install (sudo password required).
# Does not run apt/wget — safe to invoke from PowerShell without a TTY for sudo.
#
# Usage (inside WSL or via wsl -d Ubuntu-24.04 -- bash ...):
#   ./scripts/install-wsl-rocm-interactive.sh
#   ./scripts/install-wsl-rocm-interactive.sh /mnt/d/work/kubernetes
set -euo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
  if [[ -f "$(dirname "$0")/install-wsl-rocm.sh" ]]; then
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  else
    REPO_ROOT="/mnt/d/work/kubernetes"
  fi
fi

ROCM_VERSION="${ROCM_VERSION:-7.2}"
DEB_VERSION="${DEB_VERSION:-7.2.70200-1}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"
AMDGPU_DEB="amdgpu-install_${DEB_VERSION}_all.deb"
AMDGPU_DEB_URL="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${UBUNTU_CODENAME}/${AMDGPU_DEB}"

cat <<EOF
=== WSL ROCm ${ROCM_VERSION} — interactive install (sudo password required) ===

Open a WSL terminal (Ubuntu 24.04) and paste the block below.
PowerShell cannot supply your sudo password — you must run these commands yourself.

--- begin copy-paste ---

cd ${REPO_ROOT}

# Optional: WSL tools for preflight / validate.sh (helm, lspci, wget)
sudo ./scripts/install-wsl-prerequisites.sh

# Dry-run ROCm steps (no changes)
./scripts/install-wsl-rocm.sh --check

# Install ROCm stack (prompts for sudo password)
sudo ./scripts/install-wsl-rocm.sh

# Verify (amd-smi preferred on ROCm 7+; rocm-smi legacy fallback)
amd-smi version || amd-smi static || true
rocminfo | head -40 || true
rocm-smi || true

# gfx1010 (RX 5700) — not officially supported
export HSA_OVERRIDE_GFX_VERSION=10.3.0
export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True

--- end copy-paste ---

Manual equivalent (if you prefer not to use the repo script):

cd ${REPO_ROOT}
sudo apt update
wget -O /tmp/${AMDGPU_DEB} ${AMDGPU_DEB_URL}
sudo apt install -y /tmp/${AMDGPU_DEB}
sudo amdgpu-install --list-usecase
sudo amdgpu-install -y --usecase=wsl,rocm --no-dkms
# If amd-smi is missing after amdgpu-install:
command -v amd-smi || sudo apt-get install -y amd-smi-lib

After install, from Windows PowerShell:

  wsl --shutdown
  .\\scripts\\install-wsl-rocm.ps1 -PreflightOnly

Docs: docs/LOCAL_GPU_SETUP_WINDOWS.md section 4
EOF
