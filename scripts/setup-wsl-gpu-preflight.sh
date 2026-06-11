#!/usr/bin/env bash
# WSL2 GPU / ROCm preflight (run inside Ubuntu: wsl -d Ubuntu-24.04 -- bash -lc '...')
set -euo pipefail

echo "=== WSL GPU Preflight ==="
echo "uname: $(uname -a)"

if [[ -e /dev/dxg ]]; then
  echo "OK: /dev/dxg present (WSL GPU paravirtualization)"
else
  echo "WARN: /dev/dxg missing — update WSL2 / Windows GPU driver"
fi

if command -v lspci &>/dev/null; then
  lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "WARN: no VGA entry in lspci"
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
  echo "INFO: ROCm not installed. See docs/LOCAL_GPU_SETUP_WINDOWS.md"
fi

echo ""
echo "gfx1010 (RX 5700) reminder:"
echo "  export HSA_OVERRIDE_GFX_VERSION=10.3.0"
echo "  export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True"
