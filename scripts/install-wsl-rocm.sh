#!/usr/bin/env bash
# Non-interactive ROCm 7.2 install for Ubuntu 24.04 on WSL2 (AMD official WSL usecase).
# Run: wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/d/work/kubernetes && ./scripts/install-wsl-rocm.sh --check'
# Actual install requires sudo: ... ./scripts/install-wsl-rocm.sh
set -euo pipefail

ROCM_VERSION="${ROCM_VERSION:-7.2}"
DEB_VERSION="${DEB_VERSION:-7.2.70200-1}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"
AMDGPU_DEB="amdgpu-install_${DEB_VERSION}_all.deb"
AMDGPU_DEB_URL="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${UBUNTU_CODENAME}/${AMDGPU_DEB}"

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
  shift
fi

log() { printf '==> %s\n' "$*"; }

run_or_echo() {
  if $CHECK_ONLY; then
    printf '[dry-run] %s\n' "$*"
  else
    log "Running: $*"
    eval "$@"
  fi
}

require_root() {
  if $CHECK_ONLY; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: install requires root. Re-run with: sudo $0" >&2
    exit 1
  fi
}

echo "=== ROCm ${ROCM_VERSION} WSL install (Ubuntu ${UBUNTU_CODENAME}) ==="
if $CHECK_ONLY; then
  echo "Mode: --check (echo only, no changes)"
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "Detected: ${PRETTY_NAME:-unknown}"
  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    echo "WARN: This script targets Ubuntu 24.04; proceed with caution on ${VERSION_ID:-unknown}" >&2
  fi
else
  echo "WARN: /etc/os-release not found" >&2
fi

if [[ ! -e /dev/dxg ]]; then
  echo "WARN: /dev/dxg missing — install Windows Adrenalin WSL driver and update WSL2 first" >&2
fi

if ! $CHECK_ONLY; then
  require_root
fi

log "Step 1: apt update"
run_or_echo "apt update"

log "Step 2: download amdgpu-install ${DEB_VERSION}"
if $CHECK_ONLY; then
  run_or_echo "wget -O /tmp/${AMDGPU_DEB} ${AMDGPU_DEB_URL}"
else
  tmp_deb="/tmp/${AMDGPU_DEB}"
  wget -O "$tmp_deb" "$AMDGPU_DEB_URL"
fi

log "Step 3: install amdgpu-install package"
if $CHECK_ONLY; then
  run_or_echo "apt install -y /tmp/${AMDGPU_DEB}"
else
  apt install -y "/tmp/${AMDGPU_DEB}"
fi

log "Step 4: list available usecases (informational)"
run_or_echo "amdgpu-install --list-usecase"

log "Step 5: install WSL + ROCm stack (no DKMS)"
run_or_echo "amdgpu-install -y --usecase=wsl,rocm --no-dkms"

if ! command -v amd-smi >/dev/null 2>&1; then
  log "amd-smi not found after amdgpu-install; installing amd-smi-lib."
  run_or_echo "apt-get install -y amd-smi-lib"
fi

verify_amd_smi() {
  if $CHECK_ONLY; then
    run_or_echo "amd-smi version || amd-smi --help || amd-smi static"
    return 0
  fi
  if command -v amd-smi >/dev/null 2>&1; then
    if amd-smi version >/tmp/amd-smi.out 2>&1; then
      log "amd-smi looks healthy."
      sed -n '1,20p' /tmp/amd-smi.out
    elif amd-smi static >/tmp/amd-smi.out 2>&1; then
      log "amd-smi static looks healthy."
      sed -n '1,20p' /tmp/amd-smi.out
    else
      echo "WARN: amd-smi present but version/static failed; rocm-smi may still work." >&2
      sed -n '1,20p' /tmp/amd-smi.out >&2 || true
    fi
  else
    echo "WARN: amd-smi not found after amd-smi-lib install (rocm-smi fallback OK on older ROCm)." >&2
  fi
}

log "Post-install verification:"
verify_amd_smi

log "Manual verification commands (or next preflight run):"
echo "  amd-smi version || amd-smi static || true   # preferred on ROCm 7+"
echo "  rocminfo | head -40 || true"
echo "  rocm-smi || true   # legacy fallback if amd-smi missing"
echo ""
echo "gfx1010 (RX 5700) is NOT officially supported — set before PyTorch/vLLM:"
echo "  export HSA_OVERRIDE_GFX_VERSION=10.3.0"
echo "  export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True"
echo ""
echo "Docs: docs/LOCAL_GPU_SETUP_WINDOWS.md section 4.2"

if $CHECK_ONLY; then
  echo ""
  echo "Dry-run complete. To install: sudo $0"
fi
