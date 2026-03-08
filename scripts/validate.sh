#!/bin/bash
# Validate all Kubernetes manifests locally
# Usage: ./scripts/validate.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "=== Kubernetes Manifest Validation ==="

# Check for required tools
for tool in kubectl; do
  if ! command -v "$tool" &> /dev/null; then
    echo -e "${RED}Error: $tool is not installed${NC}"
    exit 1
  fi
done

ERRORS=0

# Dry-run validation for each directory
for dir in elk-stack prometheus nexus nginx; do
  echo ""
  echo "--- Validating $dir/ ---"
  for file in "$dir"/*.yaml; do
    # Skip non-resource files
    case "$(basename "$file")" in
      kustomization.yaml|values.yaml|Chart.yaml|Chart.lock|*.md) continue ;;
    esac

    if kubectl apply --dry-run=client -f "$file" > /dev/null 2>&1; then
      echo -e "  ${GREEN}OK${NC}: $file"
    else
      echo -e "  ${RED}FAIL${NC}: $file"
      kubectl apply --dry-run=client -f "$file" 2>&1 | sed 's/^/    /'
      ERRORS=$((ERRORS + 1))
    fi
  done
done

# Kustomize build validation
echo ""
echo "--- Validating Kustomize builds ---"
for dir in elk-stack prometheus nexus nginx; do
  if [ -f "$dir/kustomization.yaml" ]; then
    if kubectl kustomize "$dir" > /dev/null 2>&1; then
      echo -e "  ${GREEN}OK${NC}: kustomize build $dir"
    else
      echo -e "  ${RED}FAIL${NC}: kustomize build $dir"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

echo ""
if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}All validations passed!${NC}"
else
  echo -e "${RED}$ERRORS validation(s) failed${NC}"
  exit 1
fi
