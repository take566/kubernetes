#!/bin/bash
# Send a sample Serena MCP log event to Logstash TCP :5000 for E2E smoke testing.
# Usage: ./scripts/test-serena-mock-ingest.sh [logstash-host] [logstash-port]
# Requires: kubectl, logstash reachable from a pod in the cluster.
#
# NetworkPolicy allows ingest only from vllm namespace pods labeled app=distill-collector
# (same path as test-distill-mock.sh). Override namespace with NAMESPACE=elk-stack if policy
# is relaxed in your cluster.
#
# Example:
#   ./scripts/test-serena-mock-ingest.sh
#   LOGSTASH_HOST=127.0.0.1 LOGSTASH_PORT=5000 NAMESPACE=elk-stack ./scripts/test-serena-mock-ingest.sh

set -euo pipefail

LOGSTASH_HOST="${1:-logstash.elk-stack.svc.cluster.local}"
LOGSTASH_PORT="${2:-5000}"
NAMESPACE="${NAMESPACE:-vllm}"
JOB_NAME="serena-mock-$(date +%s)"

echo "Sending mock serena.log sample to ${LOGSTASH_HOST}:${LOGSTASH_PORT} (ns=${NAMESPACE})..."

kubectl run -n "${NAMESPACE}" "${JOB_NAME}" \
  --rm -i --restart=Never \
  --labels=app=distill-collector \
  --image=python:3.11-slim-bookworm \
  --command -- python -c "
import json, socket, uuid
from datetime import datetime, timezone

session_id = 'mcp_' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
payload = {
    '@timestamp': datetime.now(timezone.utc).isoformat(),
    'event': {'kind': 'serena.log'},
    'serena': {
        'stream': 'mcp.file',
        'session_id': session_id,
        'project': 'kubernetes',
        'host': 'mock-host',
        'version': '0.1.0-mock',
    },
    'log': {
        'level': 'INFO',
        'logger': 'serena.agent',
    },
    'message': 'INFO  2026-06-11 09:22:51 [MainThread] serena.agent:start_mcp_server:42 - Active tools (25): find_symbol, replace_symbol',
}
line = json.dumps(payload, separators=(',', ':')) + '\n'
with socket.create_connection(('${LOGSTASH_HOST}', ${LOGSTASH_PORT}), timeout=10) as sock:
    sock.sendall(line.encode('utf-8'))
print('sent session_id=' + session_id)
"

echo ""
echo "Verify in ES:"
echo "  kubectl port-forward svc/elasticsearch 9200:9200 -n elk-stack"
echo "  curl -s 'http://localhost:9200/logs-serena/_search?size=1&sort=@timestamp:desc&pretty'"
