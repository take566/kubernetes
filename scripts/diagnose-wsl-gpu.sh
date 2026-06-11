#!/usr/bin/env bash
# WSL2 AMD GPU diagnostics — device nodes, dxg/WDDM path, ROCm packages, verdict.
# Run: wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/d/work/kubernetes && ./scripts/diagnose-wsl-gpu.sh'
# JSON: ./scripts/diagnose-wsl-gpu.sh --json
set -euo pipefail

JSON_MODE=false
if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=true
fi

log() { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

# --- environment ---
IN_WSL=false
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  IN_WSL=true
fi

KERNEL="$(uname -r)"
HAS_DXG=false
HAS_KFD=false
HAS_DRI=false
DXG_DMESG_ERRORS=0
WDDM_FOUND=false
GFX1010_LIKELY=false
ROCR4WSL_INSTALLED=false
AMD_SMI_OK=false
VERDICT=""
VERDICT_DETAIL=""

[[ -e /dev/dxg ]] && HAS_DXG=true
[[ -e /dev/kfd ]] && HAS_KFD=true
if ls /dev/dri/renderD* /dev/dri/card* >/dev/null 2>&1; then
  HAS_DRI=true
fi

if dpkg -l hsa-runtime-rocr4wsl-amdgpu 2>/dev/null | awk '/^ii/{exit 0} END{exit 1}'; then
  ROCR4WSL_INSTALLED=true
fi

# dmesg dxg errors (EINVAL -22 = adapter query failed)
if command -v dmesg &>/dev/null; then
  DXG_DMESG_ERRORS=$(dmesg 2>/dev/null | grep -c 'misc dxg: dxgk:.*Ioctl failed' || true)
fi

# rocminfo WDDM probe
if command -v rocminfo &>/dev/null; then
  export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-10.3.0}"
  ROCM_OUT="$(rocminfo 2>&1 || true)"
  if ! echo "$ROCM_OUT" | grep -q 'No WDDM adapters found'; then
    if echo "$ROCM_OUT" | grep -qiE 'gfx[0-9]+|Agent'; then
      WDDM_FOUND=true
    fi
  fi
  if echo "$ROCM_OUT" | grep -qiE 'gfx1010|navi.?10'; then
    GFX1010_LIKELY=true
  fi
fi

if command -v lspci &>/dev/null; then
  if lspci 2>/dev/null | grep -qiE '5700|5600|5500|navi 10|rdna'; then
    GFX1010_LIKELY=true
  fi
fi

# WSL: lspci often empty — probe Windows GPU name via powershell.exe
if $IN_WSL && command -v powershell.exe &>/dev/null; then
  WIN_GPU="$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_VideoController | Where-Object { \$_.Name -match 'AMD|Radeon' } | Select-Object -First 1 -ExpandProperty Name)" 2>/dev/null | tr -d '\r' || true)"
  if echo "$WIN_GPU" | grep -qiE '5700|5600|5500|navi 10|rdna'; then
    GFX1010_LIKELY=true
  fi
fi

if command -v amd-smi &>/dev/null; then
  if amd-smi static &>/dev/null || amd-smi version &>/dev/null; then
    AMD_SMI_OK=true
  fi
fi

# --- verdict logic ---
if $HAS_KFD && $HAS_DRI && $WDDM_FOUND; then
  VERDICT="OK"
  VERDICT_DETAIL="WSL GPU compute path healthy (/dev/kfd, /dev/dri, WDDM adapter)."
elif $GFX1010_LIKELY; then
  VERDICT="GPU_UNSUPPORTED_WSL"
  VERDICT_DETAIL="RX 5000 (gfx1010/RDNA1) is not in AMD WSL ROCm 7.2 support matrix. /dev/kfd will not appear. Use Windows Ollama instead."
elif $HAS_DXG && ! $HAS_KFD; then
  if [[ "${DXG_DMESG_ERRORS:-0}" -gt 0 ]]; then
    VERDICT="WDDM_NOT_EXPOSED"
    VERDICT_DETAIL="/dev/dxg exists but dxgk ioctls fail and /dev/kfd is missing — Windows WSL GPU driver not exposing compute adapter."
  else
    VERDICT="KFD_MISSING"
    VERDICT_DETAIL="/dev/dxg present but /dev/kfd missing — install AMD Adrenalin 26.1.1 for WSL2, rocr4wsl, then wsl --shutdown."
  fi
elif ! $HAS_DXG; then
  VERDICT="DXG_MISSING"
  VERDICT_DETAIL="/dev/dxg missing — update WSL2 (wsl --update), install AMD WSL2 GPU driver, reboot Windows."
else
  VERDICT="UNKNOWN"
  VERDICT_DETAIL="GPU path incomplete; see remediation below."
fi

print_human() {
  log "=== WSL AMD GPU Diagnostics ==="
  log "kernel: $KERNEL"
  log "environment: $( $IN_WSL && echo WSL2 || echo Linux )"
  log ""
  log "--- device nodes ---"
  log "  /dev/dxg: $( $HAS_DXG && echo OK || echo MISSING )"
  log "  /dev/kfd: $( $HAS_KFD && echo OK || echo MISSING )"
  log "  /dev/dri: $( $HAS_DRI && echo OK || echo MISSING )"
  log ""
  log "--- kernel / dxg ---"
  log "  amdgpu in lsmod: $( lsmod 2>/dev/null | grep -q '^amdgpu' && echo yes || echo no '(expected no on WSL — uses dxg path)' )"
  log "  dxgk dmesg errors: $DXG_DMESG_ERRORS"
  log ""
  log "--- ROCm packages ---"
  log "  hsa-runtime-rocr4wsl-amdgpu: $( $ROCR4WSL_INSTALLED && echo installed || echo missing )"
  if command -v amd-smi &>/dev/null; then
    log "  amd-smi: $( $AMD_SMI_OK && echo OK || echo installed-but-failed )"
  else
    log "  amd-smi: not installed"
  fi
  log "  WDDM adapter (rocminfo): $( $WDDM_FOUND && echo found || echo NOT_FOUND )"
  if [[ -n "${WIN_GPU:-}" ]]; then
    log "  Windows GPU (via powershell): ${WIN_GPU}"
  fi
  log "  gfx1010 / RX 5700 likely: $( $GFX1010_LIKELY && echo yes || echo no )"
  log ""
  log "--- VERDICT: $VERDICT ---"
  log "$VERDICT_DETAIL"
  log ""
  log "--- remediation ---"
  case "$VERDICT" in
    OK)
      info "No action required. Set HSA_OVERRIDE_GFX_VERSION if on gfx1010 bare metal."
      ;;
    GPU_UNSUPPORTED_WSL)
      warn "WSL ROCm will NOT work on RX 5700. Recommended path:"
      log "  1. Windows: .\\scripts\\setup-ollama-rx5700.ps1"
      log "  2. Bridge:  .\\scripts\\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall"
      log "  3. K8s:      ./kubeadm/scripts/register-windows-ollama-external.sh --verify"
      log "  Docs: docs/LOCAL_GPU_SETUP_WINDOWS.md (WSL kubeadm GPU section)"
      ;;
    WDDM_NOT_EXPOSED|KFD_MISSING|DXG_MISSING)
      log "  1. Windows: Install AMD Software: Adrenalin Edition 26.1.1 for WSL2"
      log "     https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html"
      log "  2. WSL:     sudo ./scripts/install-wsl-rocm.sh  (usecase=wsl,rocm --no-dkms)"
      log "  3. Windows: wsl --shutdown   (closes all WSL — run manually when safe)"
      log "  4. Re-run:  ./scripts/diagnose-wsl-gpu.sh"
      log "  Windows helper: .\\scripts\\fix-wsl-gpu-passthrough.ps1"
      ;;
    *)
      log "  Run: .\\scripts\\fix-wsl-gpu-passthrough.ps1 (Windows)"
      log "       ./scripts/diagnose-wsl-gpu.sh (WSL)"
      ;;
  esac
}

print_json() {
  printf '{"verdict":"%s","detail":"%s","dxg":%s,"kfd":%s,"dri":%s,"wddm":%s,"gfx1010":%s,"rocr4wsl":%s,"dxg_dmesg_errors":%d}\n' \
    "$VERDICT" "$VERDICT_DETAIL" \
    "$HAS_DXG" "$HAS_KFD" "$HAS_DRI" "$WDDM_FOUND" "$GFX1010_LIKELY" "$ROCR4WSL_INSTALLED" "$DXG_DMESG_ERRORS"
}

case "$VERDICT" in
  OK) exit_code=0 ;;
  GPU_UNSUPPORTED_WSL) exit_code=2 ;;
  *) exit_code=1 ;;
esac

if $JSON_MODE; then
  print_json
else
  print_human
fi
exit "$exit_code"
