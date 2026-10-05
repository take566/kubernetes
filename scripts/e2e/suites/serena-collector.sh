# shellcheck shell=bash
# #15 Serena Log Collector: collector.py を Pod で動かし、書いたログ行が欠落・重複なく logs-serena に入ることを検証する。
# ローテーション（新ファイル）、2 プロジェクトの health-check、フィールドのパース、Logstash 再起動後の再接続を含む。
# 設計: docs/design/k8s-native-backlog-redesign.md「#15」
SUITE_ISSUE="#15"
SUITE_DESC="Serena collector Pod → logs-serena（件数一致 / ローテーション / health-check / 再接続）"
SUITE_DUMP_NAMESPACES=(elk-stack)

COLLECTOR_DIR="${E2E_ROOT}/elk-stack/design/serena-collector"
FIXTURE_DIR="${E2E_ROOT}/scripts/e2e/fixtures/serena-collector"

_wait_until() {
  local timeout="$1" start=${SECONDS}
  shift
  until "$@"; do
    (( SECONDS - start >= timeout )) && return 1
    sleep 3
  done
}

# collector Pod 内のファイルに SERENA_LOG_FORMAT の行を追記する: _write <path> <count> <first-line-no>
_write() {
  e2e::kubectl -n elk-stack exec -i serena-collector -- python - "$@" <<'PY'
import os, sys
from datetime import datetime
path, count, first = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "a", encoding="utf-8") as f:
    for n in range(first, first + count):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S,%f")[:-3]
        f.write(f"INFO  {ts} [MainThread] serena.agent:e2e_write:{n} - e2e collector line {n}\n")
PY
}

_count() {  # <session_id> <stream>
  e2e::es POST /logs-serena/_refresh >/dev/null
  e2e::es POST /logs-serena/_count \
    "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"serena.session_id\":\"$1\"}},{\"term\":{\"serena.stream\":\"$2\"}}]}}}" \
    | jq -r '.count // 0'
}

_count_ge() { (( $(_count "$1" "$2") >= $3 )); }

# 期待件数に達するまで待ち、その後少し置いて重複が無いことも含めて件数を確定させる
_settled_count() {  # <session_id> <stream> <want>
  _wait_until 120 _count_ge "$1" "$2" "$3" || true
  sleep 5
  _count "$1" "$2"
}

_can_connect_logstash() {
  e2e::kubectl -n elk-stack exec serena-collector -- python -c \
    'import socket; socket.create_connection(("logstash.elk-stack.svc", 5000), timeout=5).close()' >/dev/null 2>&1
}

suite_main() {
  e2e::deploy_elk
  e2e::toolbox_up elk-stack app=serena-collector

  e2e::kubectl -n elk-stack create configmap serena-collector \
    --from-file=collector.py="${COLLECTOR_DIR}/collector.py" \
    --from-file=collector-config.yml="${FIXTURE_DIR}/collector-config.yml" \
    --dry-run=client -o yaml | e2e::kubectl apply -f - >/dev/null
  e2e::kubectl -n elk-stack delete pod serena-collector --ignore-not-found --wait=true >/dev/null
  e2e::kubectl apply -f "${FIXTURE_DIR}/pod.yaml" >/dev/null
  e2e::kubectl -n elk-stack wait --for=condition=Ready pod/serena-collector --timeout=180s >/dev/null \
    && e2e::check "collector pod Ready" true || { e2e::check "collector pod Ready" false; return 1; }
  # Logstash の 5000 番が開くまで（readinessProbe が無いため rollout 完了後も約 2 分かかる）
  _wait_until 300 _can_connect_logstash || { e2e::check "logstash:5000 reachable from collector" false; return 1; }

  local run day a b c hc
  run="$(date +%s)$RANDOM"
  day="$(date +%Y-%m-%d)"
  a="mcp_${run}a"; b="mcp_${run}b"; c="mcp_${run}c"; hc="health_check_${run}"

  e2e::log "phase 1: new file A (5 lines)"
  _write "/serena-home/logs/${day}/${a}.txt" 5 1
  e2e::assert_eq "A: 5 lines written = 5 docs" "$(_settled_count "${a}" mcp.file 5)" 5

  e2e::log "phase 2: rotation (append 2 to A, new file B with 4 lines)"
  _write "/serena-home/logs/${day}/${a}.txt" 2 6
  _write "/serena-home/logs/${day}/${b}.txt" 4 1
  e2e::assert_eq "B (created after startup): 4 lines = 4 docs" "$(_settled_count "${b}" mcp.file 4)" 4
  e2e::assert_eq "A after append: 7 docs (no loss, no duplicates)" "$(_settled_count "${a}" mcp.file 7)" 7

  e2e::log "phase 3: health-check logs in 2 projects"
  _write "/proj1/.serena/logs/health-checks/${hc}.log" 2 1
  _write "/proj2/.serena/logs/health-checks/${hc}.log" 2 1
  e2e::assert_eq "health_check: 2 projects x 2 lines" "$(_settled_count "${hc}" health_check 4)" 4
  e2e::assert_eq "health_check: 2 distinct serena.project" \
    "$(e2e::es POST "/logs-serena/_search?size=0" \
        "{\"query\":{\"term\":{\"serena.session_id\":\"${hc}\"}},\"aggs\":{\"p\":{\"cardinality\":{\"field\":\"serena.project\"}}}}" \
        | jq -r '.aggregations.p.value')" 2

  local first
  first="$(e2e::es POST "/logs-serena/_search?size=1" \
    "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"serena.session_id\":\"${a}\"}},{\"term\":{\"serena.line\":1}}]}}}" \
    | jq -c '.hits.hits[0]._source')"
  if jq -e '.serena.logger == "serena.agent" and .serena.function == "e2e_write" and .serena.line == 1 and .log.level == "INFO" and .serena.host == "e2e-collector"' \
      <<<"${first}" >/dev/null 2>&1; then
    e2e::check "parsed fields (logger/function/line/level/host)" true
  else
    e2e::check "parsed fields (logger/function/line/level/host)" false "${first}"
  fi

  e2e::log "phase 4: restart Logstash; lines written after it is back must all arrive"
  e2e::kubectl -n elk-stack rollout restart deploy/logstash >/dev/null
  e2e::kubectl -n elk-stack rollout status deploy/logstash --timeout=600s >/dev/null
  sleep 10
  _wait_until 300 _can_connect_logstash || { e2e::check "logstash back after restart" false; return 1; }
  _write "/serena-home/logs/${day}/${a}.txt" 2 8
  _write "/serena-home/logs/${day}/${c}.txt" 3 1
  e2e::assert_eq "after restart: new file C 3 lines = 3 docs" "$(_settled_count "${c}" mcp.file 3)" 3
  e2e::assert_eq "after restart: A 9 docs (old connection replaced, no loss)" "$(_settled_count "${a}" mcp.file 9)" 9

  e2e::kubectl -n elk-stack logs serena-collector --tail=500 > "${E2E_RESULTS_DIR}/${E2E_SUITE}-collector.log" 2>&1 || true
}
