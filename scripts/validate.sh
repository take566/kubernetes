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
for dir in elk-stack prometheus nexus nginx cert-manager agents/hermes vllm/base vllm/components/amd vllm/components/finetune vllm/benchmark kubeadm/addons kubeadm/addons/local-path-storage kubeadm/addons/metrics-server kubeadm/addons/nvidia-device-plugin kind/addons vllm/overlays/kubeadm vllm/overlays/kubeadm/amd vllm/overlays/kubeadm/finetune vllm/overlays/kind vllm/overlays/kind/amd vllm/overlays/kind/finetune; do
  echo ""
  echo "--- Validating $dir/ ---"
  for file in "$dir"/*.yaml; do
    # Skip non-resource files
    case "$(basename "$file")" in
      kustomization.yaml|values.yaml|Chart.yaml|Chart.lock|*.md) continue ;;
    esac

    if kubectl apply --dry-run=client --validate=false -f "$file" > /dev/null 2>&1; then
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
KUSTOMIZE_DIRS=(
  elk-stack prometheus nexus nginx cert-manager agents/hermes
  vllm/base vllm/components/amd vllm/components/finetune vllm/benchmark
  kubeadm/addons kubeadm/addons/local-path-storage kubeadm/addons/metrics-server kubeadm/addons/nvidia-device-plugin
  kind/addons
  vllm/overlays/kubeadm vllm/overlays/kubeadm/amd vllm/overlays/kubeadm/finetune
  vllm/overlays/kind vllm/overlays/kind/amd vllm/overlays/kind/finetune
)
KUSTOMIZE_LOAD_FLAGS=(--load-restrictor LoadRestrictionsNone)
for dir in "${KUSTOMIZE_DIRS[@]}"; do
  if [ -f "$dir/kustomization.yaml" ]; then
    if kubectl kustomize "$dir" "${KUSTOMIZE_LOAD_FLAGS[@]}" > /dev/null 2>&1; then
      echo -e "  ${GREEN}OK${NC}: kustomize build $dir"
    else
      echo -e "  ${RED}FAIL${NC}: kustomize build $dir"
      kubectl kustomize "$dir" "${KUSTOMIZE_LOAD_FLAGS[@]}" 2>&1 | sed 's/^/    /'
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

# Helm wrapper dirs (gitlab/jenkins use Chart.yaml — optional helm template check)
echo ""
echo "--- Validating Helm wrapper charts (optional) ---"
HELM_WRAPPER_DIRS=(gitlab jenkins)
for dir in "${HELM_WRAPPER_DIRS[@]}"; do
  if [ -f "$dir/Chart.yaml" ]; then
    if command -v helm &> /dev/null; then
      if helm template test "$dir" -f "$dir/values.yaml" > /dev/null 2>&1; then
        echo -e "  ${GREEN}OK${NC}: helm template $dir"
      else
        echo -e "  ${RED}FAIL${NC}: helm template $dir"
        helm template test "$dir" -f "$dir/values.yaml" 2>&1 | sed 's/^/    /' | head -20
        ERRORS=$((ERRORS + 1))
      fi
    else
      echo -e "  ${GREEN}SKIP${NC}: $dir (helm not installed)"
    fi
  fi
done

# Helm wrapper dirs (monitoring uses helmCharts in kustomization — needs helm on PATH)
echo ""
echo "--- Validating Helm-backed kustomize (optional) ---"
HELM_KUSTOMIZE_DIRS=(monitoring cert-manager)
for dir in "${HELM_KUSTOMIZE_DIRS[@]}"; do
  if [ -f "$dir/kustomization.yaml" ]; then
    if command -v helm &> /dev/null; then
      if kubectl kustomize "$dir" "${KUSTOMIZE_LOAD_FLAGS[@]}" > /dev/null 2>&1; then
        echo -e "  ${GREEN}OK${NC}: kustomize build $dir (helm)"
      else
        echo -e "  ${RED}FAIL${NC}: kustomize build $dir (helm)"
        ERRORS=$((ERRORS + 1))
      fi
    else
      echo -e "  ${GREEN}SKIP${NC}: $dir (helm not installed)"
    fi
  fi
done

# Argo CD Application manifests (syntax + duplicate names)
echo ""
echo "--- Validating Argo CD Applications ---"
declare -A APP_NAMES=()
for file in argocd/apps/*-app.yaml; do
  [ -f "$file" ] || continue
  if kubectl apply --dry-run=client --validate=false -f "$file" > /dev/null 2>&1; then
    echo -e "  ${GREEN}OK${NC}: $file"
    name=$(grep -E '^  name:' "$file" | head -1 | awk '{print $2}')
    if [ -n "${APP_NAMES[$name]:-}" ]; then
      echo -e "  ${RED}FAIL${NC}: duplicate Application name '$name' in ${APP_NAMES[$name]} and $file"
      ERRORS=$((ERRORS + 1))
    else
      APP_NAMES[$name]=$file
    fi
  else
    echo -e "  ${RED}FAIL${NC}: $file"
    ERRORS=$((ERRORS + 1))
  fi
done

if kubectl apply --dry-run=client --validate=false -f argocd/apps/root-application.yaml > /dev/null 2>&1; then
  echo -e "  ${GREEN}OK${NC}: argocd/apps/root-application.yaml"
else
  echo -e "  ${RED}FAIL${NC}: argocd/apps/root-application.yaml"
  ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}All validations passed!${NC}"
else
  echo -e "${RED}$ERRORS validation(s) failed${NC}"
  exit 1
fi
