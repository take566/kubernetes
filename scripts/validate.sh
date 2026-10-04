#!/bin/bash
# Validate all Kubernetes manifests locally
# Usage: ./scripts/validate.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

# vLLM model profiles JSON
echo ""
echo "--- Validating vllm/benchmark/model-profiles.json ---"
if command -v python3 &> /dev/null; then
  if python3 vllm/benchmark/scripts/validate_model_profiles.py; then
    echo -e "  ${GREEN}OK${NC}: model-profiles.json"
  else
    echo -e "  ${RED}FAIL${NC}: model-profiles.json"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo -e "  ${GREEN}SKIP${NC}: model-profiles.json (python3 not installed)"
fi

# kubeconform: 全 kustomization のビルド結果 + 単体マニフェスト（パッチ除く）
# CI の validate ジョブと同じ scripts/kubeconform-validate.sh を使う
echo ""
echo "--- Validating manifests with kubeconform (scripts/kubeconform-validate.sh) ---"
if command -v kubeconform &> /dev/null; then
  if bash scripts/kubeconform-validate.sh; then
    echo -e "  ${GREEN}OK${NC}: kubeconform-validate.sh"
  else
    echo -e "  ${RED}FAIL${NC}: kubeconform-validate.sh"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: kubeconform is not installed (required)"
  echo "    install: go install github.com/yannh/kubeconform/cmd/kubeconform@latest"
  echo "         or: https://github.com/yannh/kubeconform/releases"
  ERRORS=$((ERRORS + 1))
fi

# Helm wrapper dirs (gitlab/jenkins use Chart.yaml — optional helm template check)
echo ""
echo "--- Validating Helm wrapper charts (optional) ---"
HELM_WRAPPER_DIRS=(gitlab jenkins actions-runner-controller github-runners)
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

# Argo CD Application manifests: 名前の重複チェックのみ
# （スキーマは kubeconform-validate.sh で検証済み。kubectl dry-run は API サーバーが要るので使わない）
# 1 ファイルに複数ドキュメントがあるので、全ドキュメントの metadata.name を拾う
echo ""
echo "--- Validating Argo CD Applications (duplicate names; schema は kubeconform で検証済み) ---"
declare -A APP_NAMES=()
APP_COUNT=0
DUP_ERRORS=0
while IFS=$'\t' read -r name file; do
  [ -n "$name" ] || continue
  APP_COUNT=$((APP_COUNT + 1))
  if [ -n "${APP_NAMES[$name]:-}" ]; then
    echo -e "  ${RED}FAIL${NC}: duplicate Application name '$name' in ${APP_NAMES[$name]} and $file"
    DUP_ERRORS=$((DUP_ERRORS + 1))
  else
    APP_NAMES[$name]=$file
  fi
done < <(awk 'FNR==1{m=0} /^metadata:/{m=1;next} /^[^ \t#]/{m=0} m&&/^  name:/{n=$2; gsub(/["\047]/,"",n); print n"\t"FILENAME; m=0}' argocd/apps/*.yaml)
if [ "$APP_COUNT" -eq 0 ]; then
  echo -e "  ${RED}FAIL${NC}: no Application found in argocd/apps/*.yaml"
  ERRORS=$((ERRORS + 1))
elif [ "$DUP_ERRORS" -eq 0 ]; then
  echo -e "  ${GREEN}OK${NC}: ${APP_COUNT} Applications, no duplicate names"
else
  ERRORS=$((ERRORS + DUP_ERRORS))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}All validations passed!${NC}"
else
  echo -e "${RED}$ERRORS validation(s) failed${NC}"
  exit 1
fi
