#!/usr/bin/env bash
# WSL2 GPU / ROCm preflight (run inside Ubuntu: wsl -d Ubuntu-24.04 -- bash -lc '...')
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== WSL GPU Preflight ==="
echo "uname: $(uname -a)"

# Device nodes (WSL uses dxg paravirtualization — kfd/dri require WDDM adapter from Windows)
for dev in dxg kfd; do
  if [[ -e "/dev/$dev" ]]; then
    echo "OK: /dev/$dev present"
  else
    echo "FAIL: /dev/$dev missing"
  fi
done

if ls /dev/dri/renderD* /dev/dri/card* >/dev/null 2>&1; then
  echo "OK: /dev/dri devices present"
else
  echo "FAIL: /dev/dri missing"
fi

if [[ -e /dev/dxg ]] && [[ ! -e /dev/kfd ]]; then
  echo ""
  echo "NOTE: /dev/dxg without /dev/kfd — Windows WSL GPU compute path not active."
  echo "  Run: ./scripts/diagnose-wsl-gpu.sh  (detailed verdict)"
  echo "  Windows: .\\scripts\\fix-wsl-gpu-passthrough.ps1"
fi

if command -v lspci &>/dev/null; then
  lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "WARN: no VGA entry in lspci (normal on WSL)"
else
  echo "SKIP: lspci not installed (sudo apt install pciutils)"
fi

for tool in amd-smi rocm-smi rocminfo docker kubectl; do
  if command -v "$tool" &>/dev/null; then
    echo "OK: $tool ($($tool --version 2>/dev/null | head -1 || echo present))"
  else
    echo "MISSING: $tool"
  fi
done

if command -v amd-smi &>/dev/null; then
  echo "--- amd-smi ---"
  amd-smi static 2>/dev/null || amd-smi version 2>/dev/null || true
elif command -v rocm-smi &>/dev/null; then
  echo "--- rocm-smi (legacy; amd-smi preferred on ROCm 7+) ---"
  rocm-smi || true
elif [[ -e /dev/kfd ]]; then
  echo "INFO: /dev/kfd exists but amd-smi/rocm-smi missing — install ROCm"
else
  echo "INFO: ROCm not installed or GPU path inactive. See docs/LOCAL_GPU_SETUP_WINDOWS.md"
fi

if [[ -x "$SCRIPT_DIR/diagnose-wsl-gpu.sh" ]]; then
  echo ""
  echo "--- diagnose-wsl-gpu (summary) ---"
  "$SCRIPT_DIR/diagnose-wsl-gpu.sh" || true
fi

echo ""
echo "gfx1010 (RX 5700) reminder:"
echo "  WSL ROCm 7.2 does NOT support gfx1010 — use Windows Ollama instead."
echo "  Bare-metal Linux only: export HSA_OVERRIDE_GFX_VERSION=10.3.0"
