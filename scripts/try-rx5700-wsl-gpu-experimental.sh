#!/usr/bin/env bash
# Experimental RX 5700 / gfx1010 WSL GPU enablement attempts — read-only probes + env overrides.
# Does NOT install packages, modify drivers, or run wsl --shutdown.
#
# Run (WSL):
#   ./scripts/try-rx5700-wsl-gpu-experimental.sh
#   ./scripts/try-rx5700-wsl-gpu-experimental.sh --json
#
# Success criteria (any ONE):
#   - /dev/kfd exists
#   - rocminfo shows a WDDM agent (not "No WDDM adapters found")
#   - amd-smi static lists a GPU device
set -euo pipefail

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

log() { printf '%s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

IN_WSL=false
grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && IN_WSL=true

HAS_DXG=false
HAS_KFD=false
HAS_DRI=false
[[ -e /dev/dxg ]] && HAS_DXG=true
[[ -e /dev/kfd ]] && HAS_KFD=true
ls /dev/dri/renderD* /dev/dri/card* >/dev/null 2>&1 && HAS_DRI=true

ROCR4WSL=false
ROCDXG=false
dpkg -s hsa-runtime-rocr4wsl-amdgpu &>/dev/null && ROCR4WSL=true
dpkg -s librocdxg-amdgpu-hst &>/dev/null && ROCDXG=true

WIN_GPU=""
WIN_DRIVER=""
if $IN_WSL && command -v powershell.exe &>/dev/null; then
  WIN_GPU="$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_VideoController | Where-Object { \$_.Name -match 'AMD|Radeon' } | Select-Object -First 1 -ExpandProperty Name)" 2>/dev/null | tr -d '\r' || true)"
  WIN_DRIVER="$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_VideoController | Where-Object { \$_.Name -match 'AMD|Radeon' } | Select-Object -First 1 -ExpandProperty DriverVersion)" 2>/dev/null | tr -d '\r' || true)"
fi

GFX1010=false
echo "${WIN_GPU:-}" | grep -qiE '5700|5600|5500|navi 10|rdna' && GFX1010=true
command -v lspci &>/dev/null && lspci 2>/dev/null | grep -qiE '5700|5600|5500|navi 10|rdna' && GFX1010=true

DXG_ERRORS=0
command -v dmesg &>/dev/null && DXG_ERRORS=$(dmesg 2>/dev/null | grep -c 'misc dxg: dxgk:.*Ioctl failed' || true)

# --- Attempt 1: baseline rocminfo ---
BASE_ROCM=""
WDDM_BASE=false
if command -v rocminfo &>/dev/null; then
  BASE_ROCM="$(rocminfo 2>&1 || true)"
  ! echo "$BASE_ROCM" | grep -q 'No WDDM adapters found' && WDDM_BASE=true
fi

# --- Attempt 2: HSA_OVERRIDE_GFX_VERSION variants (Linux bare-metal hack; usually ineffective in WSL) ---
HSA_RESULTS=()
HSA_WIN=false
if command -v rocminfo &>/dev/null; then
  for ver in 10.3.0 10.1.0 9.0.6; do
    out="$(HSA_OVERRIDE_GFX_VERSION="$ver" rocminfo 2>&1 || true)"
    ok=false
    ! echo "$out" | grep -q 'No WDDM adapters found' && ok=true
    $ok && HSA_WIN=true
    HSA_RESULTS+=("${ver}:$( $ok && echo PASS || echo FAIL )")
  done
fi

# --- Attempt 3: HIP / ROC_ENABLE_PRE_VEGA legacy flags ---
LEGACY_WIN=false
if command -v rocminfo &>/dev/null; then
  out="$(HSA_OVERRIDE_GFX_VERSION=10.3.0 ROC_ENABLE_PRE_VEGA=1 rocminfo 2>&1 || true)"
  ! echo "$out" | grep -q 'No WDDM adapters found' && LEGACY_WIN=true
fi

# --- Attempt 4: amd-smi ---
AMD_SMI_GPU=false
if command -v amd-smi &>/dev/null; then
  smi_out="$(amd-smi static 2>&1 || true)"
  echo "$smi_out" | grep -qiE 'gfx[0-9]+|card|GPU' && ! echo "$smi_out" | grep -qi 'Unable to detect any GPU' && AMD_SMI_GPU=true
fi

# --- Verdict ---
WORKS=false
VERDICT="FAIL"
REASON=""

if $HAS_KFD && $WDDM_BASE; then
  WORKS=true
  VERDICT="PASS"
  REASON="/dev/kfd present and rocminfo sees WDDM adapter."
elif $WDDM_BASE || $HSA_WIN || $LEGACY_WIN || $AMD_SMI_GPU; then
  WORKS=true
  VERDICT="PARTIAL"
  REASON="GPU visible to ROCm runtime without full /dev/kfd (new ROCDXG path may apply)."
elif $GFX1010 && $HAS_DXG && ! $HAS_KFD; then
  VERDICT="UNSUPPORTED_HW"
  REASON="Windows exposes /dev/dxg but no WDDM compute adapter for gfx1010/RDNA1. AMD WSL ROCm 7.2+ supports RDNA3+ only."
elif ! $HAS_DXG; then
  VERDICT="DXG_MISSING"
  REASON="/dev/dxg missing — update WSL (wsl --update) and install AMD Adrenalin for WSL2 driver."
else
  VERDICT="WDDM_NOT_EXPOSED"
  REASON="/dev/dxg present but dxgk ioctls fail or no WDDM adapter — check Windows driver (Adrenalin for WSL2, not display-only)."
fi

if $JSON_MODE; then
  hsa_json="$(printf '"%s",' "${HSA_RESULTS[@]}" | sed 's/,$//')"
  printf '{"verdict":"%s","works":%s,"reason":"%s","dxg":%s,"kfd":%s,"dri":%s,"gfx1010":%s,"rocr4wsl":%s,"rocdxg":%s,"dxg_errors":%d,"win_gpu":"%s","win_driver":"%s","hsa_attempts":[%s]}\n' \
    "$VERDICT" "$WORKS" "$REASON" "$HAS_DXG" "$HAS_KFD" "$HAS_DRI" "$GFX1010" "$ROCR4WSL" "$ROCDXG" "$DXG_ERRORS" \
    "${WIN_GPU:-}" "${WIN_DRIVER:-}" "${hsa_json:-}"
else
  section "Environment"
  log "WSL: $( $IN_WSL && echo yes || echo no )"
  log "kernel: $(uname -r)"
  log "Windows GPU: ${WIN_GPU:-unknown}"
  log "Windows driver: ${WIN_DRIVER:-unknown}"
  log "gfx1010/RDNA1 likely: $( $GFX1010 && echo yes || echo no )"

  section "Device nodes"
  log "/dev/dxg: $( $HAS_DXG && echo OK || echo MISSING )"
  log "/dev/kfd: $( $HAS_KFD && echo OK || echo MISSING )"
  log "/dev/dri: $( $HAS_DRI && echo OK || echo MISSING )"
  log "dxgk dmesg errors: $DXG_ERRORS"

  section "ROCm WSL packages"
  log "hsa-runtime-rocr4wsl-amdgpu: $( $ROCR4WSL && echo installed || echo missing )"
  log "librocdxg-amdgpu-hst (ROCDXG 7.2+): $( $ROCDXG && echo installed || echo missing )"

  section "Attempt 1: rocminfo (baseline)"
  if [[ -n "$BASE_ROCM" ]]; then
    echo "$BASE_ROCM" | head -12 | sed 's/^/  /'
    log "WDDM adapter: $( $WDDM_BASE && echo found || echo NOT_FOUND )"
  else
    log "rocminfo not installed"
  fi

  section "Attempt 2: HSA_OVERRIDE_GFX_VERSION"
  if [[ ${#HSA_RESULTS[@]} -gt 0 ]]; then
    for r in "${HSA_RESULTS[@]}"; do log "  $r"; done
    log "Note: override affects HIP target after WDDM adapter exists; it cannot create adapters in WSL."
  else
    log "skipped (rocminfo missing)"
  fi

  section "Attempt 3: ROC_ENABLE_PRE_VEGA=1 + HSA override"
  log "WDDM adapter: $( $LEGACY_WIN && echo found || echo NOT_FOUND )"

  section "Attempt 4: amd-smi static"
  if command -v amd-smi &>/dev/null; then
    amd-smi static 2>&1 | head -8 | sed 's/^/  /' || true
    log "GPU detected: $( $AMD_SMI_GPU && echo yes || echo no )"
  else
    log "amd-smi not installed"
  fi

  section "VERDICT: $VERDICT"
  log "$REASON"
  log ""
  log "Recommended path for RX 5700:"
  log "  Windows: .\\scripts\\setup-ollama-rx5700.ps1"
  log "  Bridge:  .\\scripts\\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall"
  log "  Docs:    docs/RX5700_WSL_GPU.md"
  if [[ "$VERDICT" == "DXG_MISSING" || "$VERDICT" == "WDDM_NOT_EXPOSED" ]] && ! $GFX1010; then
    log ""
    log "If you have a supported GPU (RX 7900+), try:"
    log "  1. AMD Software: Adrenalin Edition for WSL2 (26.1.1+)"
    log "  2. sudo ./scripts/install-wsl-rocm.sh"
    log "  3. wsl --shutdown (manual, when safe)"
  fi
fi

case "$VERDICT" in
  PASS|PARTIAL) exit 0 ;;
  UNSUPPORTED_HW) exit 2 ;;
  *) exit 1 ;;
esac
