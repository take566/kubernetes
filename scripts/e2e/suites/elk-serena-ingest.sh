# shellcheck shell=bash
# #14 Logstash serena.log 分岐: Collector 形式のイベントが logs-serena に正しく入ることを検証する。
# 設計: docs/design/k8s-native-backlog-redesign.md「#14」
SUITE_ISSUE="#14"
SUITE_DESC="Logstash serena 分岐 → logs-serena（PII マスク / quality / 振り分け / strict マッピング）"
SUITE_DUMP_NAMESPACES=(elk-stack)

SEED="${E2E_ROOT}/scripts/e2e/fixtures/seed-serena-events.py"

# toolbox から Logstash:5000 へ TCP 接続できるか（成功で 0）
_can_connect_logstash() {
  e2e::toolbox_py <<'PY'
import socket, sys
try:
    socket.create_connection(("logstash.elk-stack.svc", 5000), timeout=5).close()
except OSError:
    sys.exit(1)
PY
}

_cannot_connect_logstash() { ! _can_connect_logstash; }

# 条件が真になるまで待つ: _wait_until <秒> <コマンド...>
_wait_until() {
  local timeout="$1" start=${SECONDS}
  shift
  until "$@"; do
    (( SECONDS - start >= timeout )) && return 1
    sleep 3
  done
}

_es_hits() {  # <index> <session-field> <session>
  e2e::es POST "/$1/_search?size=50" \
    "{\"query\":{\"term\":{\"$2\":\"$3\"}},\"sort\":[{\"@timestamp\":\"asc\"}]}"
}

_es_count() {  # <index> <session-field> <session>
  e2e::es POST "/$1/_count" "{\"query\":{\"term\":{\"$2\":\"$3\"}}}" | jq -r '.count // 0'
}

_serena_ge() { e2e::es POST /logs-serena/_refresh >/dev/null; (( $(_es_count logs-serena serena.session_id "$1") >= $2 )); }
_rejected_logged() { (( $(_rejected_count "$1") >= 1 )); }
# Logstash 9.x の書き込み失敗ログ（"Could not index event to Elasticsearch. status: 400 ..."）のうち対象セッション分
_rejected_count() {
  e2e::kubectl -n elk-stack logs deploy/logstash --tail=2000 2>/dev/null \
    | grep "Could not index event" | grep -c "$1" || true
}

suite_main() {
  e2e::deploy_elk
  e2e::toolbox_up elk-stack app=serena-collector

  e2e::probe_netpol
  if [[ "${E2E_NETPOL_ENFORCED}" == true ]]; then
    e2e::log "NetworkPolicy: app=serena-collector 以外からの 5000 番は拒否される"
    e2e::kubectl -n elk-stack label pod e2e-toolbox app=e2e-denied --overwrite >/dev/null
    if _wait_until 30 _cannot_connect_logstash; then
      e2e::check "netpol: unlabeled pod is denied" true
    else
      e2e::check "netpol: unlabeled pod is denied" false "connection to logstash:5000 still succeeds"
    fi
    e2e::kubectl -n elk-stack label pod e2e-toolbox app=serena-collector --overwrite >/dev/null
  else
    e2e::skip "netpol: unlabeled pod is denied" "CNI does not enforce NetworkPolicy on this cluster"
  fi
  # Logstash Deployment には readinessProbe が無く、rollout 完了後もパイプライン起動（約 2 分）まで 5000 番が開かない
  if _wait_until 300 _can_connect_logstash; then
    e2e::check "netpol: app=serena-collector is allowed" true
  else
    e2e::check "netpol: app=serena-collector is allowed" false "cannot connect to logstash:5000"
    return 1
  fi

  local session="e2e-$(date +%s)-$RANDOM"
  e2e::log "send seed events (session=${session})"
  e2e::toolbox_py --session "${session}" --info 1 --pii 1 --sensitive 1 --plain 1 --unmapped 1 < "${SEED}"

  if ! _wait_until 120 _serena_ge "${session}" 3; then
    e2e::log "timeout waiting for logs-serena documents"
  fi
  _wait_until 60 _rejected_logged "${session}" || true
  e2e::es POST "/logstash-*/_refresh" >/dev/null

  local hits
  hits="$(_es_hits logs-serena serena.session_id "${session}")"

  e2e::assert_eq "logs-serena has info+pii+sensitive (unmapped rejected, plain excluded)" \
    "$(jq '.hits.total.value' <<<"${hits}")" 3

  local pii info sens
  pii="$(jq -c '[.hits.hits[]._source | select(.message | test("pii event"))][0]' <<<"${hits}")"
  info="$(jq -c '[.hits.hits[]._source | select(.message | test("info event"))][0]' <<<"${hits}")"
  sens="$(jq -c '[.hits.hits[]._source | select(.message | test("sensitive event"))][0]' <<<"${hits}")"

  # 「含まれない」だけだと message が空でも通るので、置換後のトークンが入ることも確かめる
  if jq -e '(.message | test("example\\.com|sam\\.smith") | not) and (.message | contains("[EMAIL]")) and (.message | contains("[USER_HOME]"))' <<<"${pii}" >/dev/null 2>&1; then
    e2e::check "PII masked ([EMAIL] / [USER_HOME])" true
  else
    e2e::check "PII masked ([EMAIL] / [USER_HOME])" false "message=$(jq -r '.message' <<<"${pii}" 2>/dev/null)"
  fi

  if jq -e '.serena.quality.score | type == "number" and . >= 0 and . <= 1' <<<"${info}" >/dev/null 2>&1; then
    e2e::check "quality.score is a number in [0,1]" true "$(jq -r '.serena.quality.score' <<<"${info}")"
  else
    e2e::check "quality.score is a number in [0,1]" false "$(jq -c '.serena.quality' <<<"${info}" 2>/dev/null)"
  fi

  if jq -e '.serena.quality.flags | index("sensitive_pattern")' <<<"${sens}" >/dev/null 2>&1; then
    e2e::check "sensitive_pattern flag set" true
  else
    e2e::check "sensitive_pattern flag set" false "$(jq -c '.serena.quality' <<<"${sens}" 2>/dev/null)"
  fi

  e2e::assert_eq "event.original is removed (#13)" \
    "$(jq '[.hits.hits[]._source.event.original // empty] | length' <<<"${hits}")" 0

  # logstash-* は ecs-logstash の動的マッピングで labels.* が text になるため .keyword で完全一致させる
  e2e::assert_eq "plain event goes to logstash-*" "$(_es_count 'logstash-*' labels.session_id.keyword "${session}")" 1

  # 意図的に 1 件だけ 400 を起こし、ログのパターンが実際にマッチすることも同時に確かめる
  e2e::assert_eq "exactly one HTTP 400 (the intentional unmapped event)" "$(_rejected_count "${session}")" 1
}
