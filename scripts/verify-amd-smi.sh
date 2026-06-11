#!/usr/bin/env bash
# AMD GPU / amd-smi verification for Linux hosts (bare metal or WSL).
# Run: ./scripts/verify-amd-smi.sh
# Dry-run: ./scripts/verify-amd-smi.sh --check
set -euo pipefail

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
    eval "$@"
  fi
}

CRITICAL_FAIL=false

echo "=== AMD GPU / amd-smi verification ==="
echo "uname: $(uname -a)"

if [[ -e /dev/kfd ]]; then
  echo "OK: /dev/kfd present"
else
  echo "FAIL: /dev/kfd missing"
  if ! $CHECK_ONLY; then
    CRITICAL_FAIL=true
  fi
fi

if ls /dev/dri/renderD* >/dev/null 2>&1 || ls /dev/dri/card* >/dev/null 2>&1; then
  echo "OK: /dev/dri devices present"
else
  echo "FAIL: /dev/dri devices missing"
  if ! $CHECK_ONLY; then
    CRITICAL_FAIL=true
  fi
fi

if [[ -e /dev/dxg ]]; then
  echo "OK: /dev/dxg present (WSL GPU paravirtualization)"
fi

echo "--- package versions ---"
if $CHECK_ONLY; then
  run_or_echo "dpkg -l amdgpu-dkms rocm-dev amd-smi-lib 2>/dev/null | awk '/^ii/'"
else
  dpkg -l amdgpu-dkms rocm-dev amd-smi-lib 2>/dev/null | awk '/^ii/' || true
fi

if $CHECK_ONLY; then
  if command -v amd-smi &>/dev/null; then
    echo "OK: amd-smi ($(command -v amd-smi))"
  else
    echo "MISSING: amd-smi"
  fi
  run_or_echo "amd-smi version || amd-smi static"
else
  if command -v amd-smi &>/dev/null; then
    echo "OK: amd-smi ($(command -v amd-smi))"
    echo "--- amd-smi ---"
    if amd-smi static 2>/dev/null; then
      :
    elif amd-smi version 2>/dev/null; then
      :
    else
      warn "amd-smi present but static/version failed"
    fi
  else
    warn "amd-smi not found (optional; rocm-smi fallback OK on older ROCm)"
    if command -v rocm-smi &>/dev/null; then
      echo "INFO: rocm-smi available (legacy)"
      run_or_echo "rocm-smi"
      if ! $CHECK_ONLY; then
        rocm-smi || true
      fi
    fi
  fi
fi

GFX1010=false
if command -v rocminfo &>/dev/null && ! $CHECK_ONLY; then
  if rocminfo 2>/dev/null | grep -qiE 'gfx1010|navi10'; then
    GFX1010=true
  fi
elif command -v lspci &>/dev/null && ! $CHECK_ONLY; then
  if lspci 2>/dev/null | grep -qiE '5700|5600|5500|navi 10|rdna'; then
    GFX1010=true
  fi
fi

if $GFX1010; then
  echo ""
  echo "gfx1010 (RX 5700 / RDNA1) detected"
  if [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]]; then
    echo "OK: HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION}"
  elif grep -q '^HSA_OVERRIDE_GFX_VERSION=10.3.0' /etc/environment 2>/dev/null \
    || [[ -f /etc/profile.d/rocm-rx5700.sh ]]; then
    echo "OK: HSA_OVERRIDE_GFX_VERSION configured in system files"
  else
    warn "HSA_OVERRIDE_GFX_VERSION not set — RX 5700 needs: export HSA_OVERRIDE_GFX_VERSION=10.3.0"
  fi
fi

echo ""
if $CRITICAL_FAIL; then
  die "Critical GPU device check failed (/dev/kfd or /dev/dri)."
fi

if $CHECK_ONLY; then
  run_or_echo "test -e /dev/kfd"
  run_or_echo "ls /dev/dri/renderD* /dev/dri/card*"
  echo "Dry-run complete. Re-run without --check to execute amd-smi."
  exit 0
fi

log "AMD GPU verification passed (amd-smi missing is warn-only)."
exit 0
