#!/bin/bash
# Send a sample distillation event to Logstash TCP :5000 for E2E smoke testing.
# Usage: ./scripts/test-distill-mock.sh [logstash-host] [logstash-port]
# Requires: kubectl, logstash reachable from a pod in the cluster.

set -euo pipefail

LOGSTASH_HOST="${1:-logstash.elk-stack.svc.cluster.local}"
LOGSTASH_PORT="${2:-5000}"
NAMESPACE="${NAMESPACE:-elk-stack}"
JOB_NAME="distill-mock-$(date +%s)"

echo "Sending mock distill sample to ${LOGSTASH_HOST}:${LOGSTASH_PORT}..."

kubectl run -n "${NAMESPACE}" "${JOB_NAME}" \
  --rm -i --restart=Never \
  --image=python:3.11-slim-bookworm \
  --command -- python -c "
import json, socket, uuid
from datetime import datetime, timezone

request_id = 'mock-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
payload = {
    '@timestamp': datetime.now(timezone.utc).isoformat(),
    'event': {'kind': 'distill.sample'},
    'distill': {
        'request_id': request_id,
        'teacher_model': 'mock/Qwen2.5-0.5B',
        'student_target': 'student-lora',
        'prompt_hash': 'mockhash001',
        'messages': [{'role': 'user', 'content': 'What is Kubernetes?'}],
        'completion': 'Kubernetes is an open-source container orchestration platform.',
        'finish_reason': 'stop',
        'usage': {'prompt_tokens': 12, 'completion_tokens': 24, 'total_tokens': 36},
        'latency_ms': 42.5,
        'quality': {'score': 0.95, 'flags': []},
        'cluster': 'kind',
        'exported': False,
    },
}
line = json.dumps(payload, separators=(',', ':')) + '\n'
with socket.create_connection(('${LOGSTASH_HOST}', ${LOGSTASH_PORT}), timeout=10) as sock:
    sock.sendall(line.encode('utf-8'))
print('sent request_id=' + request_id)
"

echo ""
echo "Verify in ES:"
echo "  kubectl port-forward svc/elasticsearch 9200:9200 -n elk-stack"
echo "  curl -s 'http://localhost:9200/logs-vllm-distill/_search?size=1&sort=@timestamp:desc&pretty'"
