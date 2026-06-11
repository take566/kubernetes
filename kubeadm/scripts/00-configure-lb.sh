#!/bin/bash
# 00-configure-lb.sh — validate control-plane endpoint before kubeadm init
# Usage:
#   export CONTROL_PLANE_IP=192.168.1.10
#   export CONTROL_PLANE_DNS=cp.example.com   # VIP or LB hostname (recommended for HA)
#   ./kubeadm/scripts/00-configure-lb.sh [--check-api]
#
# Run on any host with network access to the planned endpoint.
# For external LB (keepalived/haproxy): see kubeadm/docs/load-balancer-external.md
# For in-cluster LoadBalancer Services (post-init): kubeadm/addons/apply-addons.sh --with-metallb

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CHECK_API=false
for arg in "$@"; do
  case "${arg}" in
    --check-api) CHECK_API=true ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown argument: ${arg} (try --help)"
      ;;
  esac
done

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
CONTROL_PLANE_DNS="${CONTROL_PLANE_DNS:-}"

validate_ip() {
  local ip="$1"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local o1 o2 o3 o4
  IFS=. read -r o1 o2 o3 o4 <<<"${ip}"
  for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
    if ((octet < 0 || octet > 255)); then
      return 1
    fi
  done
}

if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  die "CONTROL_PLANE_IP is required (node advertise address, e.g. 192.168.1.10)"
fi
if ! validate_ip "${CONTROL_PLANE_IP}"; then
  die "CONTROL_PLANE_IP is not a valid IPv4 address: ${CONTROL_PLANE_IP}"
fi

if [[ -z "${CONTROL_PLANE_DNS}" ]]; then
  CONTROL_PLANE_DNS="${CONTROL_PLANE_IP}"
  warn "CONTROL_PLANE_DNS not set; using CONTROL_PLANE_IP (${CONTROL_PLANE_DNS})"
fi

ENDPOINT="${CONTROL_PLANE_DNS}:6443"

log "=== Control plane endpoint checklist ==="
echo "  CONTROL_PLANE_IP:   ${CONTROL_PLANE_IP}"
echo "  CONTROL_PLANE_DNS:  ${CONTROL_PLANE_DNS}"
echo "  controlPlaneEndpoint (kubeadm): ${ENDPOINT}"
echo ""
echo "Before kubeadm init, confirm:"
echo "  [ ] DNS or /etc/hosts resolves ${CONTROL_PLANE_DNS} on every node"
echo "  [ ] TCP 6443 on ${CONTROL_PLANE_DNS} reaches API server backend(s)"
echo "  [ ] External LB/VIP configured (Option A) OR single-node IP acceptable for dev"
echo "  [ ] kubeadm-config.yaml controlPlaneEndpoint matches ${ENDPOINT}"
echo "  [ ] advertiseAddress will be ${CONTROL_PLANE_IP} (03-init-control-plane.sh)"
echo ""
echo "Post-init (optional):"
echo "  [ ] MetalLB for Service type=LoadBalancer: apply-addons.sh --with-metallb"
echo "  [ ] Edit kubeadm/addons/metallb/ipaddresspool.yaml or METALLB_IP_POOL env"
echo ""

if command_exists getent; then
  if resolved="$(getent hosts "${CONTROL_PLANE_DNS}" 2>/dev/null | awk '{print $1; exit}')"; then
    log "DNS/hosts lookup: ${CONTROL_PLANE_DNS} -> ${resolved}"
    if [[ "${resolved}" != "${CONTROL_PLANE_IP}" && "${CONTROL_PLANE_DNS}" != "${CONTROL_PLANE_IP}" ]]; then
      warn "Resolved IP (${resolved}) differs from CONTROL_PLANE_IP (${CONTROL_PLANE_IP}); expected for VIP/LB"
    fi
  else
    warn "Cannot resolve ${CONTROL_PLANE_DNS} on this host"
  fi
fi

if [[ "${CHECK_API}" == true ]]; then
  log "=== API reachability check (${ENDPOINT}) ==="
  if command_exists curl; then
    if curl -sk --connect-timeout 5 "https://${ENDPOINT}/healthz" 2>/dev/null | grep -q ok; then
      log "API healthz: OK"
    elif curl -sk --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://${ENDPOINT}/" 2>/dev/null | grep -qE '^(401|403|200)'; then
      log "API port open (TLS responded; cluster may be up)"
    else
      warn "API not reachable at https://${ENDPOINT} (expected before init unless LB/backends are ready)"
    fi
  elif command_exists nc; then
    host="${CONTROL_PLANE_DNS}"
    port=6443
    if nc -z -w 5 "${host}" "${port}" 2>/dev/null; then
      log "TCP ${port} open on ${host}"
    else
      warn "TCP ${port} not open on ${host}"
    fi
  else
    warn "--check-api skipped: install curl or nc"
  fi
fi

log "Endpoint validation complete. Next: sudo ./kubeadm/scripts/03-init-control-plane.sh"
