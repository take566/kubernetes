#!/bin/bash
# Bootstrap Argo CD on an existing Kubernetes cluster (kubeadm / kind / cloud).
# For cluster creation see kubeadm/README.md
# Usage: ./scripts/bootstrap.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Kubernetes Platform Bootstrap ==="

# 1. Check prerequisites
echo ""
echo "--- Checking prerequisites ---"
for tool in kubectl helm; do
  if command -v "$tool" &> /dev/null; then
    echo -e "  ${GREEN}OK${NC}: $tool ($($tool version --short 2>/dev/null || $tool version 2>/dev/null | head -1))"
  else
    echo -e "  ${RED}MISSING${NC}: $tool"
    exit 1
  fi
done

if ! kubectl cluster-info &> /dev/null; then
  echo -e "  ${RED}ERROR${NC}: kubectl cannot reach a cluster. Bootstrap kubeadm first:"
  echo "    See kubeadm/README.md"
  exit 1
fi
echo -e "  ${GREEN}OK${NC}: cluster reachable ($(kubectl config current-context 2>/dev/null || echo unknown))"

# 2. Install ArgoCD
echo ""
echo "--- ArgoCD ---"
if kubectl get namespace argocd &> /dev/null; then
  echo -e "  ${GREEN}Namespace exists${NC}"
else
  echo "  Creating argocd namespace..."
  kubectl create namespace argocd
fi

echo "  Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "  Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Get ArgoCD admin password
echo ""
echo "--- ArgoCD Credentials ---"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
if [ -n "$ARGOCD_PASSWORD" ]; then
  echo -e "  Username: admin"
  echo -e "  Password: $ARGOCD_PASSWORD"
else
  echo -e "  ${YELLOW}Initial admin secret not found (may have been deleted)${NC}"
fi

# 4. Apply root application
echo ""
echo "--- Deploying Root Application ---"
kubectl apply -f argocd/apps/root-application.yaml
echo -e "  ${GREEN}Root application deployed${NC}"
echo ""
echo -e "  ${YELLOW}vLLM:${NC} production syncs via vllm-kubeadm → vllm/overlays/kubeadm"
echo "  See argocd/apps/DEPRECATED.md (minikube vllm-app removed)"

# 5. Port forward ArgoCD UI
echo ""
echo -e "${GREEN}=== Bootstrap Complete ===${NC}"
echo ""
echo "Access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "  Open: https://localhost:8443"
