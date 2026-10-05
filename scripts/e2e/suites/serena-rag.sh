# shellcheck shell=bash
# #18 RAG ログ分析 CLI（scripts/serena-rag-query.py）: ES 検索 + Ollama（CPU）埋め込み + teacher-stub chat。
# 設計: docs/design/k8s-native-backlog-redesign.md「#18」
SUITE_ISSUE="#18"
SUITE_DESC="serena-rag-query.py（Ollama CPU 埋め込み / teacher-stub chat / --require-embeddings 陰性）"
SUITE_DUMP_NAMESPACES=(elk-stack llm)

SEED="${E2E_ROOT}/scripts/e2e/fixtures/seed-serena-events.py"
RAG="${E2E_ROOT}/scripts/serena-rag-query.py"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
STUB_CM="${E2E_ROOT}/vllm/components/teacher-stub/teacher-stub-configmap.yaml"
QUERY="tool execution failed with TimeoutError"

_wait_until() {
  local timeout="$1" start=${SECONDS}
  shift
  until "$@"; do
    (( SECONDS - start >= timeout )) && return 1
    sleep 3
  done
}

_can_connect_logstash() {
  e2e::toolbox_py 2>/dev/null <<'PY'
import socket
socket.create_connection(("logstash.elk-stack.svc", 5000), timeout=5).close()
PY
}

_stub_reachable() {
  e2e::toolbox_py 2>/dev/null <<'PY'
import urllib.request
urllib.request.urlopen("http://teacher-stub.elk-stack.svc:8000/health", timeout=5).read()
PY
}

_serena_count_ge() {
  e2e::es POST /logs-serena/_refresh >/dev/null
  (( $(e2e::es POST /logs-serena/_count '{"query":{"term":{"event.kind":"serena.log"}}}' | jq -r '.count // 0') >= $1 ))
}

# toolbox（elk-stack 名前空間。ES の NetworkPolicy の許可経路）で RAG CLI を実行する。
# stdout と stderr を別ファイルに保存し、終了コードを返す: _rag <name> <args...>
_rag() {
  local name="$1"
  shift
  local out="${E2E_RESULTS_DIR}/${E2E_SUITE}-${name}.stdout" err="${E2E_RESULTS_DIR}/${E2E_SUITE}-${name}.stderr"
  e2e::toolbox_py --es-url http://elasticsearch.elk-stack.svc:9200 --query "${QUERY}" "$@" \
    < "${RAG}" > "${out}" 2> "${err}"
}

_out() { cat "${E2E_RESULTS_DIR}/${E2E_SUITE}-$1.$2"; }

suite_main() {
  e2e::deploy_elk
  e2e::toolbox_up elk-stack app=serena-collector
  _wait_until 300 _can_connect_logstash || { e2e::check "logstash:5000 reachable" false; return 1; }

  local run err_session noise_session
  run="$(date +%s)$RANDOM"
  err_session="e2e-rag-err-${run}"
  noise_session="e2e-rag-noise-${run}"
  e2e::log "seed: ${err_session} (3 ERROR TimeoutError + 2 INFO), ${noise_session} (4 unrelated WARNING + 3 INFO)"
  e2e::toolbox_py --session "${err_session}" --error 3 --info 2 < "${SEED}"
  e2e::toolbox_py --session "${noise_session}" --warning 4 --info 3 < "${SEED}"
  _wait_until 120 _serena_count_ge 12 || true

  e2e::log "Ollama (CPU) + ${EMBED_MODEL}"
  e2e::claim_namespace llm
  e2e::ensure_local_path_sc
  e2e::kubectl apply -k "${E2E_ROOT}/ollama/k8s" >/dev/null
  e2e::kubectl -n llm rollout status deploy/ollama --timeout=900s
  e2e::kubectl -n llm exec deploy/ollama -- ollama pull "${EMBED_MODEL}" >/dev/null
  local dim
  dim="$(e2e::toolbox_py "${EMBED_MODEL}" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request("http://ollama.llm.svc:11434/api/embeddings",
                             data=json.dumps({"model": sys.argv[1], "prompt": "x"}).encode(),
                             headers={"Content-Type": "application/json"})
print(len(json.load(urllib.request.urlopen(req, timeout=300)).get("embedding") or []))
PY
)"
  e2e::assert_ge "Ollama /api/embeddings returns a vector" "${dim}" 1

  e2e::log "teacher-stub (OpenAI 互換の固定応答) を elk-stack で起動"
  e2e::kubectl create --dry-run=client -o json -f "${STUB_CM}" \
    | jq '.metadata.namespace = "elk-stack"' | e2e::kubectl apply -f - >/dev/null
  e2e::kubectl -n elk-stack delete pod teacher-stub --ignore-not-found --wait=true >/dev/null
  e2e::kubectl -n elk-stack run teacher-stub --labels=app=teacher-stub --image=python:3.11-slim-bookworm --port=8000 \
    --overrides='{"spec":{"containers":[{"name":"teacher-stub","image":"python:3.11-slim-bookworm",
      "command":["python","/stub/openai_stub.py"],"ports":[{"containerPort":8000}],
      "readinessProbe":{"tcpSocket":{"port":8000},"periodSeconds":2},
      "volumeMounts":[{"name":"s","mountPath":"/stub"}]}],
      "volumes":[{"name":"s","configMap":{"name":"teacher-stub-script"}}]}}' >/dev/null
  e2e::kubectl -n elk-stack expose pod teacher-stub --port=8000 --name=teacher-stub >/dev/null 2>&1 || true
  e2e::kubectl -n elk-stack wait --for=condition=Ready pod/teacher-stub --timeout=180s >/dev/null
  # Pod が Ready でも Service の経路（kube-proxy）が反映されるまでは connection refused になる（CI で発生）
  _wait_until 60 _stub_reachable || { e2e::check "teacher-stub reachable via Service" false; return 1; }

  e2e::log "RAG: embeddings required, chat via teacher-stub"
  local rc=0
  _rag stub --ollama http://ollama.llm.svc:11434 --embed-model "${EMBED_MODEL}" \
    --vllm http://teacher-stub.elk-stack.svc:8000 --require-embeddings || rc=$?
  e2e::assert_eq "RAG exit code (--require-embeddings)" "${rc}" 0
  if grep -q "falling back to keyword ranking" <(_out stub stderr); then
    e2e::check "embeddings used (no keyword fallback)" false "$(_out stub stderr | head -3)"
  else
    e2e::check "embeddings used (no keyword fallback)" true
  fi
  if grep -q "vLLM chat failed" <(_out stub stderr); then
    e2e::check "chat went through teacher-stub (no Ollama fallback)" false "$(_out stub stderr | head -3)"
  elif grep -q "\[kind-stub\]" <(_out stub stdout); then
    e2e::check "chat went through teacher-stub (no Ollama fallback)" true
  else
    e2e::check "chat went through teacher-stub (no Ollama fallback)" false "summary has no [kind-stub] marker"
  fi
  # 出力の Top log chunks 節: "1. session_id=<id> score=<s> [LEVEL]"
  local top1
  top1="$(_out stub stdout | sed -n 's/^1\. session_id=\([^ ]*\) .*/\1/p' | head -1)"
  e2e::assert_eq "top-ranked chunk is the ERROR (TimeoutError) session, not the unrelated WARNING" "${top1}" "${err_session}"

  e2e::log "negative: Ollama unreachable"
  rc=0
  _rag noollama-required --ollama http://ollama-missing.llm.svc:11434 \
    --vllm http://teacher-stub.elk-stack.svc:8000 --require-embeddings || rc=$?
  e2e::assert_eq "--require-embeddings fails when Ollama is unreachable (exit 2)" "${rc}" 2
  rc=0
  _rag noollama-fallback --ollama http://ollama-missing.llm.svc:11434 \
    --vllm http://teacher-stub.elk-stack.svc:8000 || rc=$?
  if [[ "${rc}" -eq 0 ]] && grep -q "falling back to keyword ranking" <(_out noollama-fallback stderr); then
    e2e::check "without the flag it only warns and falls back (exit 0 is not proof of embeddings)" true
  else
    e2e::check "without the flag it only warns and falls back (exit 0 is not proof of embeddings)" false "rc=${rc}"
  fi
}

suite_cleanup() {
  # teacher-stub と toolbox は elk-stack 名前空間ごと消える。llm 名前空間は e2e 管理なので cluster_down が消す
  :
}
