#!/usr/bin/env bash
# Register Windows-native Ollama as an in-cluster external endpoint (non-ROCm AMD GPU path).
# Supports both kubeadm (WSL2) and kind (Docker Desktop / Git Bash) clusters.
# Usage: ./kubeadm/scripts/register-windows-ollama-external.sh [--cluster {kubeadm|kind}] [--host-ip <ip>] [--verify]
# Example (kind): ./kubeadm/scripts/register-windows-ollama-external.sh --cluster kind --verify
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="kubeadm"
KIND_CONTEXT="kind-dev"
KIND_NODE="dev-control-plane"
HOST_IP=""
VERIFY=false

usage() {
  cat <<EOF
Usage: $0 [--cluster {kubeadm|kind}] [--host-ip <windows-host-ip>] [--verify]
          [--context <kubectl-context>] [--kind-node <node-name>]

Registers Windows-native Ollama (http://<host-ip>:11434) as the in-cluster
Service/Endpoints "ollama-external" in namespace vllm.

Options:
  --cluster kubeadm|kind  Target cluster type (default: kubeadm)
                          kubeadm: KUBECONFIG=\$HOME/.kube/config-kubeadm-wsl (overridable via env),
                                   overlay vllm/overlays/kubeadm/windows-ollama-external/
                          kind:    kubectl --context <ctx> with default kubeconfig (~/.kube/config),
                                   overlay vllm/overlays/kind/windows-ollama-external/
  --context <ctx>         kubectl context for --cluster kind (default: kind-dev)
  --kind-node <node>      kind node name for preflight docker exec (default: dev-control-plane)
  --host-ip <ip>          Windows host IP (skips auto-detection)
  --verify                Run in-cluster verify Pod after registration
  -h, --help              Show this help

Host IP auto-detection order:
  1. --host-ip (explicit)
  2. Inside WSL: default gateway via 'ip route show default'
  3. Otherwise (Git Bash on Windows): vEthernet (WSL*) adapter IP via PowerShell

Examples:
  $0                          # kubeadm (WSL), current behavior
  $0 --cluster kind --verify  # kind cluster via Git Bash on Windows
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --context) KIND_CONTEXT="$2"; shift 2 ;;
    --kind-node) KIND_NODE="$2"; shift 2 ;;
    --host-ip) HOST_IP="$2"; shift 2 ;;
    --verify) VERIFY=true; shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "${CLUSTER}" in
  kubeadm)
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-kubeadm-wsl}"
    KUBECTL=(kubectl)
    OVERLAY="vllm/overlays/kubeadm/windows-ollama-external"
    ;;
  kind)
    # Do NOT override KUBECONFIG: use default (~/.kube/config) + explicit context.
    KUBECTL=(kubectl --context "${KIND_CONTEXT}")
    OVERLAY="vllm/overlays/kind/windows-ollama-external"
    ;;
  *)
    echo "ERROR: --cluster must be 'kubeadm' or 'kind' (got: ${CLUSTER})" >&2
    exit 1
    ;;
esac

# Detect whether we are running inside WSL.
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ "$(uname -r)" =~ [Mm]icrosoft ]]
}

# Multi-stage Windows host IP detection:
#   1. --host-ip explicit (handled by caller)
#   2. inside WSL: default gateway
#   3. Git Bash on Windows: vEthernet (WSL*) adapter via PowerShell
detect_host_ip() {
  if is_wsl; then
    ip route show default | awk '{print $3}'
  else
    powershell.exe -NoProfile -Command \
      "(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'vEthernet (WSL*').IPAddress" \
      | head -n1 | tr -d '[:space:]'
  fi
}

if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="$(detect_host_ip || true)"
fi

if [[ -z "${HOST_IP}" ]]; then
  echo "ERROR: could not detect Windows host IP. Pass --host-ip." >&2
  exit 1
fi

echo "=== Register Windows Ollama external endpoint ==="
echo "  Cluster: ${CLUSTER}"
echo "  Windows host IP: ${HOST_IP}"
if [[ "${CLUSTER}" == "kubeadm" ]]; then
  echo "  KUBECONFIG: ${KUBECONFIG}"
else
  echo "  kubectl context: ${KIND_CONTEXT}"
fi

# Avoid corporate http_proxy breaking curl to RFC1918 (see kubeadm/scripts/verify-ingress.sh)
noproxy_curl() {
  curl --noproxy '*' "$@"
}

echo "=== Preflight: Windows Ollama reachable from this shell ==="
if ! noproxy_curl -sf --connect-timeout 5 "http://${HOST_IP}:11434/api/tags" >/dev/null; then
  cat >&2 <<EOF
ERROR: Cannot reach http://${HOST_IP}:11434 from this shell.

Fix on Windows (PowerShell):
  .\\scripts\\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
  # Restart Ollama, then re-run this script.

If Ollama listens on 127.0.0.1 only:
  netstat -an | findstr 11434   # expect 0.0.0.0:11434 after OLLAMA_HOST + restart
EOF
  exit 1
fi
echo "  Ollama API: OK"

if [[ "${CLUSTER}" == "kind" ]]; then
  echo "=== Preflight 2: Windows Ollama reachable from kind node (${KIND_NODE}) ==="
  if ! docker exec "${KIND_NODE}" curl --noproxy '*' -sf --connect-timeout 5 "http://${HOST_IP}:11434/api/tags" >/dev/null; then
    cat >&2 <<EOF
ERROR: kind node '${KIND_NODE}' cannot reach http://${HOST_IP}:11434.

Likely causes and fixes:
  1. Windows Firewall blocks the Docker/kind network on port 11434.
     Existing rules may be scoped to Profile=Private only; re-run on Windows (PowerShell):
       .\\scripts\\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
  2. A corporate proxy intercepts the request (returns 403).
     curl inside the node MUST use --noproxy '*' (this preflight already does);
     ensure your workloads also bypass the proxy for ${HOST_IP}.
  3. Wrong host IP for the kind network. Pass --host-ip explicitly.
EOF
    exit 1
  fi
  echo "  kind node -> Ollama API: OK"
fi

echo "=== Applying Service (kustomize) ==="
"${KUBECTL[@]}" apply -k "${REPO_ROOT}/${OVERLAY}/"

echo "=== Applying Endpoints ==="
"${KUBECTL[@]}" apply -f - <<EOF
apiVersion: v1
kind: Endpoints
metadata:
  name: ollama-external
  namespace: vllm
  labels:
    app: ollama-external
    app.kubernetes.io/part-of: vllm
    app.kubernetes.io/component: windows-ollama-bridge
subsets:
  - addresses:
      - ip: ${HOST_IP}
    ports:
      - name: http
        port: 11434
        protocol: TCP
EOF

echo "=== Done ==="
"${KUBECTL[@]}" get svc,endpoints -n vllm ollama-external

if [[ "${VERIFY}" == true ]]; then
  echo "=== In-cluster verify (Job) ==="
  "${KUBECTL[@]}" -n vllm delete pod ollama-ext-verify --ignore-not-found
  "${KUBECTL[@]}" apply -f - <<'JOBEOF'
apiVersion: v1
kind: Pod
metadata:
  name: ollama-ext-verify
  namespace: vllm
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.5.0
      command:
        - sh
        - -c
        - |
          set -eu
          curl -sf "http://ollama-external.vllm:11434/api/tags" | head -c 300
          echo
JOBEOF
  "${KUBECTL[@]}" -n vllm wait --for=jsonpath='{.status.phase}'=Succeeded pod/ollama-ext-verify --timeout=120s
  echo "  Pod phase: Succeeded (in-cluster → Windows Ollama OK)"
  "${KUBECTL[@]}" -n vllm delete pod ollama-ext-verify --ignore-not-found
fi

cat <<EOF

In-cluster URLs:
  Native API:  http://ollama-external.vllm.svc.cluster.local:11434/api/generate
  OpenAI API:  http://ollama-external.vllm.svc.cluster.local:11434/v1/chat/completions

Example (from a Pod):
  curl http://ollama-external.vllm:11434/v1/models
EOF
