# shellcheck shell=bash
# #17 serena-export Job: logs-serena から {"text": ...} の JSONL を出力し、出力済みの印を付けることを検証する。
# 設計: docs/design/k8s-native-backlog-redesign.md「#17」
SUITE_ISSUE="#17"
SUITE_DESC="serena-export Job → JSONL（件数 / 形式 / MARK_EXPORTED / 2 回目は重複しない）"
SUITE_DUMP_NAMESPACES=(vllm elk-stack)

SEED="${E2E_ROOT}/scripts/e2e/fixtures/seed-serena-events.py"
NORMAL=55
SENSITIVE=5

_wait_until() {
  local timeout="$1" start=${SECONDS}
  shift
  until "$@"; do
    (( SECONDS - start >= timeout )) && return 1
    sleep 3
  done
}

_serena_total() {
  e2e::es POST /logs-serena/_refresh >/dev/null
  e2e::es POST /logs-serena/_count '{"query":{"term":{"event.kind":"serena.log"}}}' | jq -r '.count // 0'
}
_serena_total_ge() { (( $(_serena_total) >= $1 )); }

_can_connect_logstash() {
  e2e::toolbox_py 2>/dev/null <<'PY'
import socket
socket.create_connection(("logstash.elk-stack.svc", 5000), timeout=5).close()
PY
}

# Job を CronJob から作って完了を待つ: _run_export <job-name>
_run_export() {
  e2e::kubectl -n vllm create job "$1" --from=cronjob/serena-export >/dev/null
  e2e::kubectl -n vllm wait --for=condition=complete "job/$1" --timeout=300s >/dev/null
}

# PVC vllm-finetune-dataset の中身を一時 Pod で読み、"<ファイル名> <行数> <不正行数>" を 1 行ずつ出す
_dataset_summary() {
  e2e::kubectl -n vllm delete pod e2e-dataset-reader --ignore-not-found --wait=true >/dev/null
  e2e::kubectl -n vllm run e2e-dataset-reader --restart=Never --image=python:3.11-slim-bookworm \
    --overrides='{"spec":{"containers":[{"name":"r","image":"python:3.11-slim-bookworm","command":["sleep","600"],
      "volumeMounts":[{"name":"d","mountPath":"/data/dataset"}]}],
      "volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"vllm-finetune-dataset"}}]}}' >/dev/null
  e2e::kubectl -n vllm wait --for=condition=Ready pod/e2e-dataset-reader --timeout=180s >/dev/null
  e2e::kubectl -n vllm exec -i e2e-dataset-reader -- python - <<'PY'
import glob, json, os
for p in sorted(glob.glob("/data/dataset/serena-export-*")):
    n = bad = 0
    with open(p, encoding="utf-8") as f:
        for line in f:
            n += 1
            try:
                o = json.loads(line)
                if not (isinstance(o, dict) and isinstance(o.get("text"), str) and o["text"].strip()):
                    bad += 1
            except ValueError:
                bad += 1
    print(os.path.basename(p), n, bad)
PY
  e2e::kubectl -n vllm delete pod e2e-dataset-reader --wait=false >/dev/null
}

suite_main() {
  local suspend
  suspend="$(e2e::kubectl kustomize --load-restrictor LoadRestrictionsNone "${E2E_ROOT}/vllm/overlays/kind/serena-export" \
    | e2e::kubectl create --dry-run=client --validate=false -o json -f - \
    | jq -rs '[.[] | (.items[]? // .) | select(.kind == "CronJob")][0].spec.suspend')"
  e2e::assert_eq "kind overlay: CronJob suspend" "${suspend}" true

  e2e::deploy_elk
  e2e::toolbox_up elk-stack app=serena-collector
  _wait_until 300 _can_connect_logstash || { e2e::check "logstash:5000 reachable" false; return 1; }

  e2e::log "seed ${NORMAL} normal + ${SENSITIVE} sensitive events"
  e2e::toolbox_py --session "e2e-export-$(date +%s)" --info "${NORMAL}" --sensitive "${SENSITIVE}" < "${SEED}"
  _wait_until 120 _serena_total_ge $((NORMAL + SENSITIVE)) || true
  e2e::assert_eq "seeded documents in logs-serena" "$(_serena_total)" $((NORMAL + SENSITIVE))

  e2e::claim_namespace vllm
  e2e::ensure_local_path_sc
  e2e::kubectl kustomize --load-restrictor LoadRestrictionsNone "${E2E_ROOT}/vllm/overlays/kind/serena-export" \
    | e2e::kubectl apply -f - >/dev/null
  e2e::kubectl -n vllm patch configmap serena-export-config --type merge -p '{"data":{"MARK_EXPORTED":"true"}}' >/dev/null

  e2e::log "export run 1"
  if _run_export serena-export-e2e-1; then
    e2e::check "run 1: job complete" true
  else
    e2e::check "run 1: job complete" false; return 1
  fi
  local summary1
  summary1="$(_dataset_summary)"
  e2e::log "dataset after run 1: ${summary1//$'\n'/ | }"
  e2e::assert_eq "run 1: one output file" "$(grep -c . <<<"${summary1}")" 1
  # Job の完了（exit 0）は 0 件でも起きるので、行数そのものを判定する
  e2e::assert_eq "run 1: JSONL rows = ${NORMAL} (sensitive excluded)" "$(awk '{s+=$2} END {print s+0}' <<<"${summary1}")" "${NORMAL}"
  e2e::assert_eq "run 1: every row is {\"text\": non-empty}" "$(awk '{s+=$3} END {print s+0}' <<<"${summary1}")" 0

  e2e::es POST /logs-serena/_refresh >/dev/null
  e2e::assert_eq "MARK_EXPORTED: serena.exported=true count" \
    "$(e2e::es POST /logs-serena/_count '{"query":{"term":{"serena.exported":true}}}' | jq -r '.count')" "${NORMAL}"

  e2e::log "export run 2 (no new documents)"
  sleep 2  # 出力ファイル名は秒単位
  if _run_export serena-export-e2e-2; then
    e2e::check "run 2: job complete" true
  else
    e2e::check "run 2: job complete" false; return 1
  fi
  local summary2
  summary2="$(_dataset_summary)"
  e2e::log "dataset after run 2: ${summary2//$'\n'/ | }"
  e2e::assert_eq "run 2: no new file (exported docs are skipped, empty output not written)" "$(grep -c . <<<"${summary2}")" 1
  e2e::assert_eq "run 2: run 1 output is kept (${NORMAL} rows)" "$(awk '{s+=$2} END {print s+0}' <<<"${summary2}")" "${NORMAL}"
}
