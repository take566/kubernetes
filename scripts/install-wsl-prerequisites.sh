#!/usr/bin/env bash
# Install WSL tooling for GPU / K8s manifest validation (helm, pciutils, wget).
#
# Requires sudo — run interactively inside WSL:
#   cd /mnt/d/work/kubernetes && sudo ./scripts/install-wsl-prerequisites.sh
#
# Dry-run (no changes):
#   ./scripts/install-wsl-prerequisites.sh --check
#
# From Windows (opens instructions only — sudo password cannot be supplied non-interactively):
#   .\scripts\install-wsl-rocm.ps1 -PrerequisitesOnly
set -euo pipefail

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
  shift
fi

PACKAGES=(helm pciutils wget)

log() { printf '==> %s\n' "$*"; }

require_root() {
  if $CHECK_ONLY; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: install requires root. Re-run with: sudo $0" >&2
    exit 1
  fi
}

echo "=== WSL prerequisites (helm, pciutils, wget) ==="
if $CHECK_ONLY; then
  echo "Mode: --check (echo only, no changes)"
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "Detected: ${PRETTY_NAME:-unknown}"
fi

echo ""
echo "Packages:"
for pkg in "${PACKAGES[@]}"; do
  if command -v "$pkg" &>/dev/null || dpkg -s "$pkg" &>/dev/null 2>&1; then
    echo "  $pkg: present or installed"
  else
    echo "  $pkg: MISSING"
  fi
done

if $CHECK_ONLY; then
  echo ""
  echo '[dry-run] sudo apt-get update'
  echo "[dry-run] sudo apt-get install -y ${PACKAGES[*]}"
  echo ""
  echo "Dry-run complete. To install: sudo $0"
  exit 0
fi

require_root

log "apt-get update"
apt-get update

log "install packages: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}"

echo ""
echo "Verification:"
for tool in helm lspci wget; do
  if command -v "$tool" &>/dev/null; then
    echo "  OK: $tool ($($tool --version 2>/dev/null | head -1 || echo present))"
  else
    echo "  WARN: $tool not on PATH after install"
  fi
done

echo ""
echo "Done. Re-run: ./scripts/setup-wsl-gpu-preflight.sh"
