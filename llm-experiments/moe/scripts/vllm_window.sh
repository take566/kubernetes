#!/usr/bin/env bash
# Time-boxed window that frees deploy-note's GTX 1650 by stopping production vLLM.
#
#   sudo ./scripts/vllm_window.sh start    # pause Argo auto-sync, scale vllm to 0, wait for a free GPU
#   sudo ./scripts/vllm_window.sh stop     # restore replicas + auto-sync, verify health and UIDs
#   ./scripts/vllm_window.sh status        # read-only
#
# What start does (in this order, everything logged to $STATE_DIR/window.log):
#   1. Records, once per window, into $STATE_DIR/state.json: spec.syncPolicy of
#      the vllm-kubeadm Application AND of every parent Application found through
#      the argocd.argoproj.io/tracking-id annotation (root-application manages
#      vllm-kubeadm with selfHeal, so removing automated from vllm-kubeadm alone
#      would be reverted by the root within minutes), deploy/vllm replicas, and
#      the UIDs of the namespace, its PVCs and its Services.
#   2. Removes spec.syncPolicy.automated: parents first, then vllm-kubeadm.
#   3. Scales deploy/vllm to 0 and waits until nvidia-smi memory.used < 200 MiB.
#   4. Starts a detached watchdog that runs `stop` at the 90-minute deadline.
#   Any failure after step 1 rolls back (runs stop) unless VLLM_WINDOW_NO_ROLLBACK=1.
#
# What stop does: scales deploy/vllm back to the recorded replicas, re-applies the
# recorded automated blocks (vllm-kubeadm first, then parents) and reads them
# back, waits for the rollout + /health 200 (through the API-server service
# proxy) + Application Synced/Healthy, and checks the namespace/PVC/Service UIDs
# are unchanged. Any mismatch exits non-zero and keeps the state file.
#
# Both verbs are idempotent: a second start keeps the ORIGINAL recorded state,
# a stop with nothing recorded only verifies. kubectl runs with
# --kubeconfig /etc/kubernetes/admin.conf (root-only file; sudo -n is used when
# the file is not readable). Override with VLLM_WINDOW_KUBECONFIG.
#
# NOTE: deploy/vllm uses image vllm/vllm-openai:latest with imagePullPolicy
# Always, so the restart in `stop` may pull a NEWER vLLM image than the one that
# was running. The UID check does not cover that; check the pod image afterwards.
set -euo pipefail

APP="${VLLM_WINDOW_APP:-vllm-kubeadm}"
ARGO_NS="${VLLM_WINDOW_ARGO_NS:-argocd}"
NS="${VLLM_WINDOW_NS:-vllm}"
DEPLOY="${VLLM_WINDOW_DEPLOY:-vllm}"
SVC_HEALTH="${VLLM_WINDOW_HEALTH_SVC:-vllm:8000}"
KCFG="${VLLM_WINDOW_KUBECONFIG:-/etc/kubernetes/admin.conf}"
MAX_MINUTES="${VLLM_WINDOW_MAX_MINUTES:-90}"
GPU_FREE_BELOW_MIB="${VLLM_WINDOW_GPU_USED_BELOW_MIB:-200}"
GPU_WAIT_S="${VLLM_WINDOW_GPU_WAIT_S:-300}"
READY_TIMEOUT_S="${VLLM_WINDOW_READY_TIMEOUT_S:-1500}"
ARGO_TIMEOUT_S="${VLLM_WINDOW_ARGO_TIMEOUT_S:-600}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${VLLM_WINDOW_STATE_DIR:-}" ]]; then
  if [[ -n "${SUDO_USER:-}" ]]; then
    VLLM_WINDOW_STATE_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/state/vllm-window"
  else
    VLLM_WINDOW_STATE_DIR="${HOME}/.local/state/vllm-window"
  fi
fi
STATE_DIR="$VLLM_WINDOW_STATE_DIR"
STATE="${STATE_DIR}/state.json"
LOG="${STATE_DIR}/window.log"
LOCK="${STATE_DIR}/lock"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
die() { log "[ERROR] $*"; exit 1; }

# --------------------------------------------------------------------- kubectl
KC=()
setup_kubectl() {
  command -v kubectl >/dev/null || die "kubectl not found"
  if [[ -r "$KCFG" ]]; then
    KC=(kubectl --kubeconfig "$KCFG")
  elif sudo -n true 2>/dev/null; then
    KC=(sudo -n kubectl --kubeconfig "$KCFG")
  else
    die "cannot read ${KCFG} and sudo needs a password - run as root (sudo $0 ...) or set VLLM_WINDOW_KUBECONFIG"
  fi
}
kc() { "${KC[@]}" "$@"; }

gpu_used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' '; }

# Application chain: APP plus parents via tracking-id "<parent>:argoproj.io/Application:<ns>/<name>".
app_chain() {
  local name="$APP" parent depth=0
  echo "$name"
  while (( depth < 4 )); do
    parent="$(kc -n "$ARGO_NS" get application "$name" \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null | cut -d: -f1)"
    [[ -n "$parent" && "$parent" != "$name" ]] || break
    kc -n "$ARGO_NS" get application "$parent" >/dev/null 2>&1 || break
    echo "$parent"
    name="$parent"; depth=$((depth + 1))
  done
}

current_uids() {
  jq -n \
    --arg ns "$(kc get ns "$NS" -o jsonpath='{.metadata.uid}')" \
    --argjson pvc "$(kc -n "$NS" get pvc -o json | jq '[.items[] | {(.metadata.name): .metadata.uid}] | add // {}')" \
    --argjson svc "$(kc -n "$NS" get svc -o json | jq '[.items[] | {(.metadata.name): .metadata.uid}] | add // {}')" \
    '{namespace: $ns, pvc: $pvc, svc: $svc}'
}

health_code() {
  # API-server service proxy: no NodePort / network assumptions.
  if kc get --raw "/api/v1/namespaces/${NS}/services/${SVC_HEALTH}/proxy/health" >/dev/null 2>&1; then
    echo 200
  else
    echo 000
  fi
}

# --------------------------------------------------------------------- record
record_state() {
  if [[ -f "$STATE" ]]; then
    log "[INFO] state already recorded at ${STATE} (window $(jq -r .window_id "$STATE")) - keeping the ORIGINAL values"
    return
  fi
  local apps_json='{}' a sp replicas now
  for a in $(app_chain); do
    sp="$(kc -n "$ARGO_NS" get application "$a" -o json | jq '.spec.syncPolicy // {}')"
    apps_json="$(jq --arg a "$a" --argjson sp "$sp" '. + {($a): $sp}' <<< "$apps_json")"
  done
  replicas="$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
  [[ "$replicas" =~ ^[0-9]+$ ]] || die "could not read replicas of deploy/${DEPLOY}"
  if [[ "$replicas" == 0 ]]; then
    die "deploy/${DEPLOY} is already at 0 replicas with no recorded state - refusing to record 0 as the value to restore"
  fi
  now="$(date +%s)"
  jq -n --argjson apps "$apps_json" --argjson replicas "$replicas" --argjson uids "$(current_uids)" \
    --argjson start "$now" --argjson deadline "$(( now + MAX_MINUTES * 60 ))" \
    --arg id "$(date -u +%Y%m%dT%H%M%SZ)" --arg order "$(app_chain | tr '\n' ' ')" \
    '{window_id: $id, started_epoch: $start, deadline_epoch: $deadline, app_order: ($order | split(" ") | map(select(. != ""))),
      sync_policy: $apps, replicas: $replicas, uids: $uids}' > "${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
  log "[OK] recorded state: $(jq -c '{window_id, replicas, apps: (.sync_policy | map_values(.automated))}' "$STATE")"
}

# --------------------------------------------------------------------- start
start_watchdog() {
  local deadline id wd_pid
  deadline="$(jq -r .deadline_epoch "$STATE")"
  id="$(jq -r .window_id "$STATE")"
  if [[ -n "$(jq -r '.watchdog_pid // empty' "$STATE")" ]] && kill -0 "$(jq -r .watchdog_pid "$STATE")" 2>/dev/null; then
    log "[INFO] watchdog already running (pid $(jq -r .watchdog_pid "$STATE"))"
    return
  fi
  # Values go in as positional args ($1..$5) of the inner script, which is why it is single-quoted.
  # 9>&-: the flock fd must not leak into the watchdog, or it would hold the lock for 90 min.
  # shellcheck disable=SC2016
  VLLM_WINDOW_STATE_DIR="$STATE_DIR" VLLM_WINDOW_KUBECONFIG="$KCFG" VLLM_WINDOW_FROM_WATCHDOG=1 \
    nohup setsid bash -c '
      sleep $(( $1 - $(date +%s) )) 2>/dev/null || true
      if [[ -f "$2" ]] && [[ "$(jq -r .window_id "$2")" == "$3" ]]; then
        echo "$(date -u +%FT%TZ) [WATCHDOG] deadline reached - running stop" >> "$4"
        "$5" stop >> "$4" 2>&1
      fi' vllm-window-watchdog "$deadline" "$STATE" "$id" "$LOG" "$SELF" \
    >/dev/null 2>&1 < /dev/null 9>&- &
  wd_pid=$!
  jq --argjson p "$wd_pid" '.watchdog_pid = $p' "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
  log "[OK] watchdog pid ${wd_pid} will run stop at $(date -d "@${deadline}" '+%F %T %Z')"
}

do_start() {
  record_state
  local a auto
  # Parents first: otherwise root-application's selfHeal re-adds automated to vllm-kubeadm.
  for a in $(jq -r '.app_order | reverse | .[]' "$STATE"); do
    auto="$(kc -n "$ARGO_NS" get application "$a" -o json | jq -c '.spec.syncPolicy.automated // empty')"
    if [[ -n "$auto" ]]; then
      kc -n "$ARGO_NS" patch application "$a" --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null
      log "[OK] ${a}: removed syncPolicy.automated (was ${auto})"
    else
      log "[INFO] ${a}: automated already absent"
    fi
  done
  sleep 5
  for a in $(jq -r '.app_order[]' "$STATE"); do
    auto="$(kc -n "$ARGO_NS" get application "$a" -o json | jq -c '.spec.syncPolicy.automated // empty')"
    [[ -z "$auto" ]] || die "${a}: automated came back (${auto}) - something else manages this Application"
  done

  kc -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
  log "[OK] scaled deploy/${DEPLOY} to 0"
  kc -n "$NS" wait --for=delete pod -l app=vllm --timeout=180s >/dev/null 2>&1 \
    || log "[WARNING] some vllm pods still present after 180s: $(kc -n "$NS" get pods -l app=vllm --no-headers 2>&1 | tr '\n' ';')"

  local waited=0 used
  while :; do
    used="$(gpu_used_mib)"
    [[ "$used" =~ ^[0-9]+$ ]] || die "could not read nvidia-smi memory.used"
    (( used < GPU_FREE_BELOW_MIB )) && break
    (( waited >= GPU_WAIT_S )) && die "GPU still has ${used} MiB used after ${GPU_WAIT_S}s (another process? unload Ollama models: keep_alive=0)"
    sleep 5; waited=$((waited + 5))
  done
  log "[OK] GPU free: memory.used=${used} MiB (< ${GPU_FREE_BELOW_MIB})"
  start_watchdog
  log "[OK] window ${MAX_MINUTES} min open. ALWAYS finish with: sudo $SELF stop"
}

# --------------------------------------------------------------------- stop
do_stop() {
  if [[ ! -f "$STATE" ]]; then
    log "[INFO] no recorded window state - verifying only"
    do_status
    local missing=0 a
    for a in $(app_chain); do
      [[ -n "$(kc -n "$ARGO_NS" get application "$a" -o json | jq -c '.spec.syncPolicy.automated // empty')" ]] \
        || { log "[ERROR] ${a} has no syncPolicy.automated and no state to restore it from"; missing=1; }
    done
    [[ "$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')" != 0 ]] \
      || { log "[ERROR] deploy/${DEPLOY} is at 0 replicas and no state to restore it from"; missing=1; }
    return "$missing"
  fi
  local fail=0 replicas a want got start_ts
  replicas="$(jq -r .replicas "$STATE")"

  kc -n "$NS" scale deploy "$DEPLOY" --replicas="$replicas" >/dev/null
  log "[OK] scaled deploy/${DEPLOY} to ${replicas}"

  for a in $(jq -r '.app_order[]' "$STATE"); do
    want="$(jq -c --arg a "$a" '.sync_policy[$a].automated // empty' "$STATE")"
    [[ -n "$want" ]] || { log "[INFO] ${a}: had no automated block - nothing to restore"; continue; }
    kc -n "$ARGO_NS" patch application "$a" --type merge \
      -p "$(jq -nc --argjson auto "$want" '{spec: {syncPolicy: {automated: $auto}}}')" >/dev/null
    got="$(kc -n "$ARGO_NS" get application "$a" -o json | jq -c '.spec.syncPolicy.automated // empty')"
    if [[ "$(jq -S . <<< "$got")" == "$(jq -S . <<< "$want")" ]]; then
      log "[OK] ${a}: automated restored ${got}"
    else
      log "[ERROR] ${a}: automated is '${got}', expected '${want}'"; fail=1
    fi
  done

  if kc -n "$NS" rollout status deploy "$DEPLOY" --timeout="${READY_TIMEOUT_S}s" >/dev/null 2>&1; then
    log "[OK] deploy/${DEPLOY} rolled out: $(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}')/${replicas} ready"
  else
    log "[ERROR] deploy/${DEPLOY} not ready within ${READY_TIMEOUT_S}s"; fail=1
  fi

  start_ts=$(date +%s)
  until [[ "$(health_code)" == 200 ]]; do
    if (( $(date +%s) - start_ts > 300 )); then log "[ERROR] /health not 200 within 300s"; fail=1; break; fi
    sleep 10
  done
  [[ "$(health_code)" == 200 ]] && log "[OK] /health 200 (image: $(kc -n "$NS" get pods -l app=vllm -o jsonpath='{.items[*].status.containerStatuses[0].imageID}'))"

  local before after
  before="$(jq -S .uids "$STATE")"
  after="$(current_uids | jq -S .)"
  if [[ "$before" == "$after" ]]; then
    log "[OK] namespace/PVC/Service UIDs unchanged"
  else
    log "[ERROR] UID mismatch: before=$(jq -c . <<< "$before") after=$(jq -c . <<< "$after")"; fail=1
  fi

  start_ts=$(date +%s)
  local sync health
  while :; do
    sync="$(kc -n "$ARGO_NS" get application "$APP" -o jsonpath='{.status.sync.status}')"
    health="$(kc -n "$ARGO_NS" get application "$APP" -o jsonpath='{.status.health.status}')"
    [[ "$sync" == Synced && "$health" == Healthy ]] && break
    if (( $(date +%s) - start_ts > ARGO_TIMEOUT_S )); then
      log "[ERROR] ${APP} is ${sync}/${health} after ${ARGO_TIMEOUT_S}s"; fail=1; break
    fi
    sleep 15
  done
  [[ "$sync" == Synced && "$health" == Healthy ]] && log "[OK] ${APP} Synced/Healthy"

  if (( fail )); then
    log "[ERROR] stop finished WITH ERRORS - state kept at ${STATE}; fix and re-run stop"
    return 1
  fi
  local wd started id
  wd="$(jq -r '.watchdog_pid // empty' "$STATE")"
  started="$(jq -r .started_epoch "$STATE")"
  id="$(jq -r .window_id "$STATE")"
  if [[ -n "$wd" && -z "${VLLM_WINDOW_FROM_WATCHDOG:-}" ]]; then
    kill "$wd" 2>/dev/null && log "[OK] watchdog ${wd} stopped" || true
  fi
  mv "$STATE" "${STATE_DIR}/state-${id}-closed.json"
  log "[OK] window ${id} closed after $(( ( $(date +%s) - started ) / 60 )) min"
}

# --------------------------------------------------------------------- status
do_status() {
  local a
  echo "== Argo Applications"
  for a in $(app_chain); do
    kc -n "$ARGO_NS" get application "$a" -o json \
      | jq -r '"  \(.metadata.name): automated=\(.spec.syncPolicy.automated // "ABSENT" | tostring) sync=\(.status.sync.status) health=\(.status.health.status)"'
  done
  echo "== deploy/${DEPLOY}: replicas=$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}') ready=$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}')"
  kc -n "$NS" get pods -l app=vllm --no-headers 2>/dev/null | sed 's/^/  /'
  echo "== /health via service proxy: $(health_code)"
  echo "== GPU memory.used: $(gpu_used_mib) MiB"
  echo "== UIDs: $(current_uids | jq -c .)"
  if [[ -f "$STATE" ]]; then
    local left=$(( $(jq -r .deadline_epoch "$STATE") - $(date +%s) ))
    echo "== WINDOW OPEN: $(jq -c '{window_id, replicas, watchdog_pid}' "$STATE"), $(( left / 60 )) min left"
    (( left > 0 )) || echo "   [WARNING] past the ${MAX_MINUTES}-minute deadline - run stop now"
  else
    echo "== no window open (state: ${STATE})"
  fi
}

# --------------------------------------------------------------------- main
main() {
  local verb="${1:-}"
  case "$verb" in start|stop|status) ;; *) echo "usage: $0 start|stop|status" >&2; exit 2 ;; esac
  for t in jq nvidia-smi; do command -v "$t" >/dev/null || { echo "[ERROR] $t not found" >&2; exit 1; }; done
  mkdir -p "$STATE_DIR"
  [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$STATE_DIR" 2>/dev/null || true
  setup_kubectl
  case "$verb" in
    status) do_status ;;
    start)
      exec 9>"$LOCK"; flock -w 60 9 || die "another vllm_window run holds ${LOCK}"
      log "=== start (max ${MAX_MINUTES} min)"
      # Not `if ! (...)`: errexit is ignored inside an if-condition, subshell included.
      local rc=0
      set +e; ( set -e; do_start ); rc=$?; set -e
      if (( rc != 0 )); then
        if [[ -f "$STATE" && -z "${VLLM_WINDOW_NO_ROLLBACK:-}" ]]; then
          log "[ERROR] start failed - rolling back with stop"
          do_stop || die "ROLLBACK FAILED - inspect ${LOG} and ${STATE}"
        fi
        exit 1
      fi
      ;;
    stop)
      exec 9>"$LOCK"; flock -w 600 9 || die "another vllm_window run holds ${LOCK}"
      log "=== stop"
      do_stop
      ;;
  esac
}

main "$@"
