#!/bin/bash
# Bootstrap GitHub Actions self-hosted runners (ARC v2) on kind / kubeadm clusters.
#
# Usage:
#   ./scripts/bootstrap-self-hosted-runner.sh          # install / upgrade
#   ./scripts/bootstrap-self-hosted-runner.sh --check  # dry-run: prereqs + helm template only
#
# GitHub token (optional — required to register runners):
#   export GITHUB_TOKEN=ghp_...   OR   echo 'ghp_...' > ~/.github-runner-token
#
# After bootstrap:
#   gh workflow run self-hosted-test.yaml
#   ./scripts/trigger-vllm-benchmark.sh default

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHECK_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $arg${NC}" >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARC_CHART="${REPO_ROOT}/actions-runner-controller"
RUNNERS_CHART="${REPO_ROOT}/github-runners"
ARC_NS="actions-runner-system"
RUNNERS_NS="github-runners"
ARC_RELEASE="arc"
RUNNERS_RELEASE="github-runners"
TOKEN_FILE="${HOME}/.github-runner-token"

log()  { echo -e "$*"; }
ok()   { echo -e "  ${GREEN}OK${NC}: $*"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $*"; }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $*"; }
fail() { echo -e "  ${RED}FAIL${NC}: $*" >&2; exit 1; }

ensure_helm_deps() {
  local chart_dir="$1"
  if [[ ! -d "${chart_dir}/charts" ]] || [[ -z "$(ls -A "${chart_dir}/charts" 2>/dev/null)" ]]; then
    log "--- Building Helm dependencies: ${chart_dir##*/} ---"
    helm dependency build "${chart_dir}"
  fi
}

resolve_github_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "${GITHUB_TOKEN}"
    return 0
  fi
  if [[ -f "${TOKEN_FILE}" ]]; then
    tr -d '\n\r' < "${TOKEN_FILE}"
    return 0
  fi
  return 1
}

echo "=== Self-Hosted Runner Bootstrap (ARC v2) ==="
if [[ "${CHECK_ONLY}" == true ]]; then
  warn "Mode: --check (dry-run, no cluster changes)"
fi

# --- Prerequisites ---
echo ""
echo "--- Checking prerequisites ---"
for tool in kubectl helm; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool ($($tool version --short 2>/dev/null || $tool version 2>/dev/null | head -1))"
  else
    fail "$tool is not installed"
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  fail "kubectl cannot reach a cluster (bootstrap kind or kubeadm first)"
fi
CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
ok "cluster reachable (context: ${CTX})"

for chart_dir in "${ARC_CHART}" "${RUNNERS_CHART}"; do
  [[ -f "${chart_dir}/Chart.yaml" ]] || fail "missing ${chart_dir}/Chart.yaml"
  ensure_helm_deps "${chart_dir}"
done

echo ""
echo "--- Helm template validation ---"
if helm template "${ARC_RELEASE}" "${ARC_CHART}" \
     -f "${ARC_CHART}/values.yaml" \
     -n "${ARC_NS}" >/dev/null; then
  ok "helm template ${ARC_CHART##*/}"
else
  fail "helm template ${ARC_CHART##*/}"
fi

if helm template "${RUNNERS_RELEASE}" "${RUNNERS_CHART}" \
     -f "${RUNNERS_CHART}/values.yaml" \
     -n "${RUNNERS_NS}" >/dev/null; then
  ok "helm template ${RUNNERS_CHART##*/}"
else
  fail "helm template ${RUNNERS_CHART##*/}"
fi

if [[ "${CHECK_ONLY}" == true ]]; then
  echo ""
  echo -e "${GREEN}=== Check complete (no changes applied) ===${NC}"
  echo ""
  echo "GitHub token (required to register runners):"
  echo "  export GITHUB_TOKEN=ghp_...   OR   echo 'ghp_...' > ${TOKEN_FILE}"
  echo ""
  echo "Apply bootstrap:"
  echo "  ./scripts/bootstrap-self-hosted-runner.sh"
  echo ""
  echo "Trigger smoke test:"
  echo "  gh workflow run self-hosted-test.yaml"
  exit 0
fi

# --- ARC controller ---
echo ""
echo "--- Installing ARC controller (${ARC_NS}) ---"
kubectl create namespace "${ARC_NS}" --dry-run=client -o yaml | kubectl apply -f -
helm template "${ARC_RELEASE}" "${ARC_CHART}" \
  -f "${ARC_CHART}/values.yaml" \
  -n "${ARC_NS}" | kubectl apply -f -
ok "controller manifests applied"

echo "  Waiting for controller deployment..."
if kubectl wait --for=condition=available \
     --timeout=300s \
     deployment/"${ARC_RELEASE}"-gha-rs-controller \
     -n "${ARC_NS}" 2>/dev/null; then
  ok "controller ready (${ARC_RELEASE}-gha-rs-controller)"
else
  warn "controller not ready within 300s — check: kubectl get pods -n ${ARC_NS}"
fi

# --- GitHub token + runner scale set ---
echo ""
echo "--- GitHub runner scale set (${RUNNERS_NS}) ---"
echo "  Token source: GITHUB_TOKEN env or ${TOKEN_FILE}"
echo "  PAT scopes: repo, workflow (repo) or org admin:self-hosted-runners (org)"
echo "  See: github-runners/README.md"

if TOKEN="$(resolve_github_token)"; then
  kubectl create namespace "${RUNNERS_NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic github-runners-secret \
    --namespace "${RUNNERS_NS}" \
    --from-literal=github_token="${TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "secret github-runners-secret applied"

  helm template "${RUNNERS_RELEASE}" "${RUNNERS_CHART}" \
    -f "${RUNNERS_CHART}/values.yaml" \
    -n "${RUNNERS_NS}" | kubectl apply -f -
  ok "runner scale set applied (runs-on: k8s-self-hosted)"

  echo "  Waiting for AutoscalingRunnerSet..."
  for _ in $(seq 1 30); do
    if kubectl get autoscalingrunnersets -n "${RUNNERS_NS}" 2>/dev/null | grep -q k8s-self-hosted; then
      ok "AutoscalingRunnerSet k8s-self-hosted present"
      break
    fi
    sleep 2
  done
else
  skip "no GitHub token — controller only (create secret, re-run to deploy runners)"
  echo ""
  echo "  Create token then re-run:"
  echo "    export GITHUB_TOKEN=ghp_..."
  echo "    ./scripts/bootstrap-self-hosted-runner.sh"
fi

echo ""
echo -e "${GREEN}=== Bootstrap complete ===${NC}"
echo ""
echo "Verify:"
echo "  kubectl get pods -n ${ARC_NS}"
echo "  kubectl get autoscalingrunnersets -n ${RUNNERS_NS}"
echo ""
echo "Trigger workflows:"
echo "  gh workflow run self-hosted-test.yaml"
echo "  ./scripts/trigger-vllm-benchmark.sh default"
