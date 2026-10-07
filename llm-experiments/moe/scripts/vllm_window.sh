#!/usr/bin/env bash
# Time-boxed window that frees deploy-note's GTX 1650 by stopping production vLLM.
#
#   sudo ./scripts/vllm_window.sh start    # pause Argo auto-sync, scale vllm to 0, wait for a free GPU
#   sudo ./scripts/vllm_window.sh stop     # restore replicas + auto-sync, verify health and UIDs
#   ./scripts/vllm_window.sh status        # read-only (works without root)
#
# What start does (in this order, everything logged to $STATE_DIR/window.log):
#   1. Records, once per window, into $STATE_DIR/state.json: spec.syncPolicy of
#      the vllm-kubeadm Application AND of every parent Application found through
#      the argocd.argoproj.io/tracking-id annotation (root-application manages
#      vllm-kubeadm with selfHeal, so removing automated from vllm-kubeadm alone
#      would be reverted by the root within minutes), deploy/vllm replicas, and
#      the UIDs of the namespace, its PVCs and its Services.
#   2. Arms a detached watchdog that runs `stop` at the 90-minute deadline
#      (retrying every 60 s for up to 30 min until stop succeeds) - BEFORE any
#      write, so an interrupted start can never leave vLLM down without it.
#   3. Removes spec.syncPolicy.automated: parents first, then vllm-kubeadm.
#   4. Scales deploy/vllm to 0, waits until no non-Failed vllm pod is left, then
#      waits until nvidia-smi memory.free >= VLLM_WINDOW_MIN_FREE_VRAM_MIB (3072).
#   Any failure, or SIGINT/SIGTERM/SIGHUP, after step 1 rolls back (runs stop)
#   unless VLLM_WINDOW_NO_ROLLBACK=1.
#
# What stop does: kills a recorded training process ($STATE_DIR/train.pid,
# written by train_lora_cuda.sh) so vLLM does not start against an occupied GPU,
# scales deploy/vllm back to the recorded replicas, re-applies the recorded
# automated blocks (vllm-kubeadm first, then parents) and reads them back, waits
# for the rollout + /health 200 (through the API-server service proxy) +
# Application Synced/Healthy, and checks the namespace/PVC/Service UIDs are
# unchanged. Every write is retried (5 x 10 s) and a failing step does not skip
# the later ones. Any mismatch exits non-zero and keeps the state file.
#
# Both verbs are idempotent: a second start keeps the ORIGINAL recorded state,
# a stop with nothing recorded only verifies. kubectl runs with
# --kubeconfig /etc/kubernetes/admin.conf (root-only file; sudo -n is used when
# the file is not readable). Override with VLLM_WINDOW_KUBECONFIG.
#
# State lives in ONE fixed place, /var/lib/vllm-window (override:
# VLLM_WINDOW_STATE_DIR), so start, stop and the watchdog always agree whoever
# runs them. start/stop need write access there, i.e. root.
#
# NOTE: deploy/vllm uses image vllm/vllm-openai:latest with imagePullPolicy
# Always, so the restart in `stop` may pull a NEWER vLLM image than the one that
# was running. The UID check does not cover that; check the logged imageID.
set -euo pipefail

APP="${VLLM_WINDOW_APP:-vllm-kubeadm}"
ARGO_NS="${VLLM_WINDOW_ARGO_NS:-argocd}"
NS="${VLLM_WINDOW_NS:-vllm}"
DEPLOY="${VLLM_WINDOW_DEPLOY:-vllm}"
SVC_HEALTH="${VLLM_WINDOW_HEALTH_SVC:-vllm:8000}"
KCFG="${VLLM_WINDOW_KUBECONFIG:-/etc/kubernetes/admin.conf}"
MAX_MINUTES="${VLLM_WINDOW_MAX_MINUTES:-90}"
MIN_FREE_VRAM_MIB="${VLLM_WINDOW_MIN_FREE_VRAM_MIB:-3072}"
GPU_WAIT_S="${VLLM_WINDOW_GPU_WAIT_S:-300}"
POD_WAIT_S="${VLLM_WINDOW_POD_WAIT_S:-180}"
READY_TIMEOUT_S="${VLLM_WINDOW_READY_TIMEOUT_S:-1500}"
ARGO_TIMEOUT_S="${VLLM_WINDOW_ARGO_TIMEOUT_S:-600}"
RETRIES="${VLLM_WINDOW_RETRIES:-5}"
RETRY_SLEEP_S="${VLLM_WINDOW_RETRY_SLEEP_S:-10}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

STATE_DIR="${VLLM_WINDOW_STATE_DIR:-/var/lib/vllm-window}"
STATE="${STATE_DIR}/state.json"
LOG="${STATE_DIR}/window.log"
LOCK="${STATE_DIR}/lock"
TRAIN_PID="${STATE_DIR}/train.pid"

# Never let logging itself fail the run (closed terminal after SIGHUP, read-only status).
log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  if [[ -w "$STATE_DIR" ]]; then printf '%s\n' "$line" >> "$LOG" 2>/dev/null || true; fi
  printf '%s\n' "$line" >&2 2>/dev/null || true
}
die() { log "[ERROR] $*"; exit 1; }

# retry CMD...: RETRIES attempts, RETRY_SLEEP_S apart (transient API-server errors).
retry() {
  local i
  for (( i = 1; i <= RETRIES; i++ )); do
    if "$@"; then return 0; fi
    (( i < RETRIES )) && { log "[WARNING] attempt ${i}/${RETRIES} failed: $*"; sleep "$RETRY_SLEEP_S"; }
  done
  log "[ERROR] gave up after ${RETRIES} attempts: $*"
  return 1
}

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

gpu_query() { nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits | head -1 | tr -d ' '; }

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
  local ns pvc svc
  ns="$(kc get ns "$NS" -o jsonpath='{.metadata.uid}')" || return 1
  pvc="$(kc -n "$NS" get pvc -o json | jq '[.items[] | {(.metadata.name): .metadata.uid}] | add // {}')" || return 1
  svc="$(kc -n "$NS" get svc -o json | jq '[.items[] | {(.metadata.name): .metadata.uid}] | add // {}')" || return 1
  jq -n --arg ns "$ns" --argjson pvc "$pvc" --argjson svc "$svc" '{namespace: $ns, pvc: $pvc, svc: $svc}'
}

automated_of() { kc -n "$ARGO_NS" get application "$1" -o json | jq -c '.spec.syncPolicy.automated // empty'; }

health_code() {
  # API-server service proxy: no NodePort / network assumptions.
  if kc get --raw "/api/v1/namespaces/${NS}/services/${SVC_HEALTH}/proxy/health" >/dev/null 2>&1; then
    echo 200
  else
    echo 000
  fi
}

# vllm pods that still exist and are not terminal. The Failed pod
# vllm-6df68b98cc-w59qx (UnexpectedAdmissionError, never garbage-collected)
# would otherwise make a plain `wait --for=delete` burn its whole timeout.
live_vllm_pods() {
  kc -n "$NS" get pods -l app=vllm --field-selector='status.phase!=Failed,status.phase!=Succeeded' -o name
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
  # After the deadline it retries stop every 60 s for up to 30 min, as long as this window's state is open.
  # 9>&-: the flock fd must not leak into the watchdog, or it would hold the lock for 90 min.
  # shellcheck disable=SC2016
  VLLM_WINDOW_STATE_DIR="$STATE_DIR" VLLM_WINDOW_KUBECONFIG="$KCFG" VLLM_WINDOW_FROM_WATCHDOG=1 \
    nohup setsid bash -c '
      sleep $(( $1 - $(date +%s) )) 2>/dev/null || true
      for attempt in $(seq 1 30); do
        [[ -f "$2" ]] && [[ "$(jq -r .window_id "$2")" == "$3" ]] || exit 0
        echo "$(date -u +%FT%TZ) [WATCHDOG] deadline reached - running stop (attempt ${attempt}/30)" >> "$4"
        "$5" stop >> "$4" 2>&1 && exit 0
        sleep 60
      done
      echo "$(date -u +%FT%TZ) [WATCHDOG] [ERROR] stop still failing after 30 attempts - manual action needed" >> "$4"
      ' vllm-window-watchdog "$deadline" "$STATE" "$id" "$LOG" "$SELF" \
    >/dev/null 2>&1 < /dev/null 9>&- &
  wd_pid=$!
  jq --argjson p "$wd_pid" '.watchdog_pid = $p' "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
  log "[OK] watchdog pid ${wd_pid} armed: stop at $(date -d "@${deadline}" '+%F %T %Z')"
}

do_start() {
  record_state
  start_watchdog   # armed before the first write (B1)

  # Training writes its PID here (train_lora_cuda.sh); pre-create it for the invoking user.
  if [[ ! -e "$TRAIN_PID" ]]; then
    : > "$TRAIN_PID"
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$TRAIN_PID"
    chmod 0644 "$TRAIN_PID"
  fi

  local a auto
  # Parents first: otherwise root-application's selfHeal re-adds automated to vllm-kubeadm.
  for a in $(jq -r '.app_order | reverse | .[]' "$STATE"); do
    auto="$(automated_of "$a")"
    if [[ -n "$auto" ]]; then
      kc -n "$ARGO_NS" patch application "$a" --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null
      log "[OK] ${a}: removed syncPolicy.automated (was ${auto})"
    else
      log "[INFO] ${a}: automated already absent"
    fi
  done
  sleep 5
  for a in $(jq -r '.app_order[]' "$STATE"); do
    auto="$(automated_of "$a")"
    [[ -z "$auto" ]] || die "${a}: automated came back (${auto}) - something else manages this Application"
  done

  kc -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
  log "[OK] scaled deploy/${DEPLOY} to 0"
  local waited=0 pods
  while :; do
    pods="$(live_vllm_pods)"
    [[ -z "$pods" ]] && break
    (( waited >= POD_WAIT_S )) && die "vllm pods still running after ${POD_WAIT_S}s: $(tr '\n' ' ' <<< "$pods")"
    sleep 5; waited=$((waited + 5))
  done
  log "[OK] no running vllm pods (Failed pods ignored)"

  local free
  waited=0
  while :; do
    free="$(gpu_query memory.free)"
    [[ "$free" =~ ^[0-9]+$ ]] || die "could not read nvidia-smi memory.free"
    (( free >= MIN_FREE_VRAM_MIB )) && break
    (( waited >= GPU_WAIT_S )) && die "only ${free} MiB VRAM free after ${GPU_WAIT_S}s (need >= ${MIN_FREE_VRAM_MIB}; unload Ollama models: keep_alive=0)"
    sleep 5; waited=$((waited + 5))
  done
  log "[OK] GPU free: memory.free=${free} MiB (>= ${MIN_FREE_VRAM_MIB}), used=$(gpu_query memory.used) MiB"
  log "[OK] window ${MAX_MINUTES} min open. ALWAYS finish with: sudo $SELF stop"
}

# --------------------------------------------------------------------- stop
# Kill a training run that is still holding the GPU (M3). The PID is checked
# against its command line so a recycled PID is never killed.
stop_training() {
  [[ -s "$TRAIN_PID" ]] || return 0
  local pid
  pid="$(tr -dc '0-9' < "$TRAIN_PID")"
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    log "[INFO] recorded training pid ${pid} is not running"
    : > "$TRAIN_PID"; return 0
  fi
  if ! tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -q 'train_lora'; then
    log "[WARNING] pid ${pid} in ${TRAIN_PID} is not a train_lora process - not killing it"
    return 0
  fi
  log "[WARNING] training pid ${pid} still running - terminating it before vLLM comes back"
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for (( i = 0; i < 30; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    log "[WARNING] training pid ${pid} killed with SIGKILL"
  fi
  : > "$TRAIN_PID"
}

restore_automated() {
  local a="$1" want="$2" got
  kc -n "$ARGO_NS" patch application "$a" --type merge \
    -p "$(jq -nc --argjson auto "$want" '{spec: {syncPolicy: {automated: $auto}}}')" >/dev/null || return 1
  got="$(automated_of "$a")" || return 1
  if [[ -n "$got" && "$(jq -S . <<< "$got")" == "$(jq -S . <<< "$want")" ]]; then
    log "[OK] ${a}: automated restored ${got}"
  else
    log "[WARNING] ${a}: automated reads '${got}', expected '${want}'"; return 1
  fi
}

do_stop() {
  if [[ ! -f "$STATE" ]]; then
    log "[INFO] no recorded window state - verifying only"
    do_status
    local missing=0 a
    for a in $(app_chain); do
      [[ -n "$(automated_of "$a")" ]] \
        || { log "[ERROR] ${a} has no syncPolicy.automated and no state to restore it from"; missing=1; }
    done
    [[ "$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')" != 0 ]] \
      || { log "[ERROR] deploy/${DEPLOY} is at 0 replicas and no state to restore it from"; missing=1; }
    return "$missing"
  fi
  local fail=0 replicas a want start_ts
  replicas="$(jq -r .replicas "$STATE")"

  stop_training

  # Every step below runs even if an earlier one failed: Argo must be restored regardless.
  if retry kc -n "$NS" scale deploy "$DEPLOY" --replicas="$replicas"; then
    log "[OK] scaled deploy/${DEPLOY} to ${replicas}"
  else
    fail=1
  fi

  for a in $(jq -r '.app_order[]' "$STATE"); do
    want="$(jq -c --arg a "$a" '.sync_policy[$a].automated // empty' "$STATE")"
    [[ -n "$want" ]] || { log "[INFO] ${a}: had no automated block - nothing to restore"; continue; }
    retry restore_automated "$a" "$want" || fail=1
  done

  if kc -n "$NS" rollout status deploy "$DEPLOY" --timeout="${READY_TIMEOUT_S}s" >/dev/null 2>&1; then
    log "[OK] deploy/${DEPLOY} rolled out: $(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' || true)/${replicas} ready"
  else
    log "[ERROR] deploy/${DEPLOY} not ready within ${READY_TIMEOUT_S}s"; fail=1
  fi

  start_ts=$(date +%s)
  until [[ "$(health_code)" == 200 ]]; do
    if (( $(date +%s) - start_ts > 300 )); then log "[ERROR] /health not 200 within 300s"; fail=1; break; fi
    sleep 10
  done
  if [[ "$(health_code)" == 200 ]]; then
    log "[OK] /health 200 (imageID: $(kc -n "$NS" get pods -l app=vllm --field-selector=status.phase=Running -o jsonpath='{.items[*].status.containerStatuses[0].imageID}' || true))"
  fi

  local before after
  before="$(jq -S .uids "$STATE")"
  if after="$(retry current_uids)"; then
    after="$(jq -S . <<< "$after")"
    if [[ "$before" == "$after" ]]; then
      log "[OK] namespace/PVC/Service UIDs unchanged"
    else
      log "[ERROR] UID mismatch: before=$(jq -c . <<< "$before") after=$(jq -c . <<< "$after")"; fail=1
    fi
  else
    fail=1
  fi

  start_ts=$(date +%s)
  local sync='' health=''
  while :; do
    sync="$(kc -n "$ARGO_NS" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kc -n "$ARGO_NS" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [[ "$sync" == Synced && "$health" == Healthy ]] && break
    if (( $(date +%s) - start_ts > ARGO_TIMEOUT_S )); then
      log "[ERROR] ${APP} is ${sync:-?}/${health:-?} after ${ARGO_TIMEOUT_S}s"; fail=1; break
    fi
    sleep 15
  done
  if [[ "$sync" == Synced && "$health" == Healthy ]]; then log "[OK] ${APP} Synced/Healthy"; fi

  if (( fail )); then
    log "[ERROR] stop finished WITH ERRORS - state kept at ${STATE}; fix and re-run stop"
    return 1
  fi
  local wd started id
  wd="$(jq -r '.watchdog_pid // empty' "$STATE")"
  started="$(jq -r .started_epoch "$STATE")"
  id="$(jq -r .window_id "$STATE")"
  if [[ -n "$wd" && -z "${VLLM_WINDOW_FROM_WATCHDOG:-}" ]]; then
    if kill "$wd" 2>/dev/null; then log "[OK] watchdog ${wd} stopped"; fi
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
  echo "== live (non-Failed) vllm pods: $(live_vllm_pods | wc -l)"
  echo "== /health via service proxy: $(health_code)"
  echo "== GPU memory.used: $(gpu_query memory.used) MiB, memory.free: $(gpu_query memory.free) MiB (start needs >= ${MIN_FREE_VRAM_MIB})"
  echo "== UIDs: $(current_uids | jq -c .)"
  if [[ -s "$TRAIN_PID" ]]; then echo "== training pid file: $(cat "$TRAIN_PID")"; fi
  if [[ -f "$STATE" ]]; then
    local left=$(( $(jq -r .deadline_epoch "$STATE") - $(date +%s) ))
    echo "== WINDOW OPEN: $(jq -c '{window_id, replicas, watchdog_pid}' "$STATE"), $(( left / 60 )) min left"
    (( left > 0 )) || echo "   [WARNING] past the ${MAX_MINUTES}-minute deadline - run stop now"
  else
    echo "== no window open (state: ${STATE})"
  fi
}

# --------------------------------------------------------------------- main
on_signal() { INTERRUPTED="$1"; }

main() {
  local verb="${1:-}"
  case "$verb" in start|stop|status) ;; *) echo "usage: $0 start|stop|status" >&2; exit 2 ;; esac
  for t in jq nvidia-smi; do command -v "$t" >/dev/null || { echo "[ERROR] $t not found" >&2; exit 1; }; done
  if [[ "$verb" != status ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null && [[ -w "$STATE_DIR" ]] \
      || { echo "[ERROR] ${STATE_DIR} is not writable - run as root (sudo $0 $verb)" >&2; exit 1; }
  fi
  setup_kubectl
  case "$verb" in
    status) do_status ;;
    start)
      exec 9>"$LOCK"; flock -w 60 9 || die "another vllm_window run holds ${LOCK}"
      log "=== start (max ${MAX_MINUTES} min)"
      # A signal kills the do_start subshell; the parent records it and rolls back below.
      INTERRUPTED=''
      trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal HUP' HUP
      # Not `if ! (...)`: errexit is ignored inside an if-condition, subshell included.
      local rc=0
      set +e; ( trap - INT TERM HUP; set -e; do_start ); rc=$?; set -e
      if [[ -n "$INTERRUPTED" ]]; then rc=130; log "[ERROR] start interrupted by SIG${INTERRUPTED}"; fi
      if (( rc != 0 )); then
        if [[ -f "$STATE" && -z "${VLLM_WINDOW_NO_ROLLBACK:-}" ]]; then
          # The rollback must finish even if the terminal goes away or Ctrl-C is pressed again.
          trap '' INT TERM HUP
          log "[ERROR] start failed (rc=${rc}) - rolling back with stop"
          do_stop || die "ROLLBACK FAILED - inspect ${LOG} and ${STATE}; the watchdog will retry stop at the deadline"
        fi
        exit 1
      fi
      trap - INT TERM HUP
      ;;
    stop)
      exec 9>"$LOCK"; flock -w 600 9 || die "another vllm_window run holds ${LOCK}"
      log "=== stop"
      do_stop
      ;;
  esac
}

main "$@"
