#!/usr/bin/env bash
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
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

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
    die "Run as root: sudo $0"
  fi
}

detect_amd_gpu() {
  local lspci_out=""
  if command -v lspci >/dev/null 2>&1; then
    lspci_out="$(lspci 2>/dev/null || true)"
    if echo "${lspci_out}" | grep -qiE 'vga|3d|display'; then
      if echo "${lspci_out}" | grep -qiE 'amd|advanced micro devices|radeon'; then
        return 0
      fi
    fi
  fi
  if ls /dev/dri/renderD* >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

configure_rx5700_override() {
  local profile_file="/etc/profile.d/rocm-rx5700.sh"
  local env_file="/etc/environment"
  local export_line="export HSA_OVERRIDE_GFX_VERSION=10.3.0"
  local env_line="HSA_OVERRIDE_GFX_VERSION=10.3.0"

  if $CHECK_ONLY; then
    run_or_echo "printf '%s\n' '${export_line}' > ${profile_file}"
    run_or_echo "grep -q '^${env_line}$' ${env_file} || printf '\n%s\n' '${env_line}' >> ${env_file}"
    return 0
  fi

  printf '%s\n' "${export_line}" >"${profile_file}"
  chmod 644 "${profile_file}"

  if ! grep -q "^${env_line}$" "${env_file}" 2>/dev/null; then
    printf '\n%s\n' "${env_line}" >>"${env_file}"
  fi
}

echo "=== ROCm worker install (Ubuntu 24.04 native Linux) ==="
if $CHECK_ONLY; then
  echo "Mode: --check (dry-run, no changes)"
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Detected OS: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" ]] || warn "This script is tested on Ubuntu."
  [[ "${VERSION_ID:-}" == "24.04" ]] || warn "This script targets Ubuntu 24.04."
else
  warn "/etc/os-release not found"
fi

if ! detect_amd_gpu; then
  die "AMD GPU not detected (amdgpu). Check hardware/driver visibility first."
fi
log "AMD GPU detected."

require_root

run_or_echo "apt-get update"
run_or_echo "apt-get install -y wget gnupg ca-certificates pciutils"

if ! $CHECK_ONLY && command -v amdgpu-install >/dev/null 2>&1; then
  log "amdgpu-install already available."
else
  run_or_echo "wget -O /tmp/${AMDGPU_DEB} ${AMDGPU_DEB_URL}"
  run_or_echo "apt-get install -y /tmp/${AMDGPU_DEB}"
fi

if $CHECK_ONLY || command -v amdgpu-install >/dev/null 2>&1; then
  run_or_echo "amdgpu-install --list-usecase"
  run_or_echo "amdgpu-install -y --usecase=dkms,rocm --no-32"
else
  warn "amdgpu-install not found after package install. Trying apt ROCm package."
  run_or_echo "apt-get install -y rocm"
fi

if ! $CHECK_ONLY && ! command -v amd-smi >/dev/null 2>&1; then
  run_or_echo "apt-get install -y amd-smi-lib"
fi

configure_rx5700_override

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
      warn "amd-smi present but version/static failed; rocm-smi may still work on older ROCm."
      sed -n '1,20p' /tmp/amd-smi.out >&2 || true
    fi
  else
    warn "amd-smi not found (optional on ROCm 7+; rocm-smi fallback is OK for older installs)."
  fi
}

echo ""
echo "Verification:"
echo "  source /etc/profile.d/rocm-rx5700.sh"
echo "  rocminfo | head -40"
echo "  amd-smi version || amd-smi static"
echo "  rocm-smi || true   # legacy fallback"
if $CHECK_ONLY; then
  run_or_echo "rocminfo | head -40"
  verify_amd_smi
else
  if command -v rocminfo >/dev/null 2>&1; then
    rocminfo >/tmp/rocminfo.out 2>&1 || true
    if grep -q "Agent" /tmp/rocminfo.out; then
      log "rocminfo looks healthy."
      sed -n '1,40p' /tmp/rocminfo.out
    else
      warn "rocminfo did not report expected GPU agents."
      sed -n '1,40p' /tmp/rocminfo.out
      exit 1
    fi
  else
    die "rocminfo command not found after install."
  fi
  verify_amd_smi
fi
