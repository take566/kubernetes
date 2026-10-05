# shellcheck shell=bash
# #9 推論モデル比較の流れを CPU の Ollama（ollama/k8s/）で検証する。数値の大小は判定せず、形式と失敗の記録を見る。
# 採用モデルの最終判断は GPU 実機（compare_models.sh）で行う。
# 設計: docs/design/k8s-native-backlog-redesign.md「#9」
SUITE_ISSUE="#9"
SUITE_DESC="CPU Ollama でモデル比較（p50/p99/tok/s の形式、失敗候補の記録、モデル指定の回帰）"
SUITE_DUMP_NAMESPACES=(llm)

# COMPARE_SET=extended-cpu: #10 の拡張候補のうち CPU で回せる LFM2.5 小型（Ollama はコミュニティ版タグ）。
# Qwen3.6-35B / Gemma4（HF ゲート付き）は GPU 実機の対象で、ここでは回さない
case "${COMPARE_SET:-default}" in
  default) DEFAULT_COMPARE_MODELS="Qwen/Qwen2.5-0.5B-Instruct Qwen/Qwen2.5-1.5B-Instruct" ;;
  extended-cpu) DEFAULT_COMPARE_MODELS="LiquidAI/LFM2.5-350M LiquidAI/LFM2.5-1.2B-Instruct" ;;
  *) echo "unknown COMPARE_SET=${COMPARE_SET} (default|extended-cpu)" >&2; exit 2 ;;
esac
COMPARE_MODELS="${COMPARE_MODELS:-${DEFAULT_COMPARE_MODELS}}"
# 存在しないモデル（失敗を記録できることの確認）
BOGUS_MODEL="e2e-nonexistent/model-does-not-exist"

_overlay_has() {  # <overlay> <model>
  e2e::kubectl kustomize --load-restrictor LoadRestrictionsNone "${E2E_ROOT}/vllm/overlays/$1" | grep -q "$2"
}

suite_main() {
  _overlay_has kubeadm 'Qwen/Qwen2.5-1.5B-Instruct' \
    && e2e::check "overlay kubeadm serves Qwen2.5-1.5B-Instruct" true \
    || e2e::check "overlay kubeadm serves Qwen2.5-1.5B-Instruct" false
  _overlay_has kind 'Qwen/Qwen2.5-0.5B-Instruct' \
    && e2e::check "overlay kind serves Qwen2.5-0.5B-Instruct" true \
    || e2e::check "overlay kind serves Qwen2.5-0.5B-Instruct" false

  e2e::claim_namespace llm
  e2e::ensure_local_path_sc
  e2e::kubectl apply -k "${E2E_ROOT}/ollama/k8s" >/dev/null
  if e2e::kubectl -n llm wait --for=condition=Ready pod -l app=ollama --timeout=900s >/dev/null; then
    e2e::check "Ollama pod Ready" true
  else
    e2e::check "Ollama pod Ready" false; return 1
  fi

  local dir="${E2E_RESULTS_DIR}/${E2E_SUITE}" rc=0
  # 前回の実行（別の COMPARE_SET など）の結果を summary に混ぜない
  rm -rf "${dir}"
  mkdir -p "${dir}"
  # compare_ollama.sh は kubectl を直接呼ぶ。利用者の kubeconfig の current-context は変えず、
  # 対象 context だけの一時 kubeconfig を子プロセスに渡す
  local kc="${KUBECONFIG:-}"
  if [[ -n "${E2E_CONTEXT}" ]]; then
    kc="$(mktemp)"
    kubectl config view --minify --flatten --context "${E2E_CONTEXT}" > "${kc}"
  fi
  KUBECONFIG="${kc}" MODELS="${COMPARE_MODELS} ${BOGUS_MODEL}" RESULTS_DIR="${dir}" OLLAMA_NS=llm \
    bash "${E2E_ROOT}/vllm/benchmark/scripts/compare_ollama.sh" || rc=$?
  [[ -n "${E2E_CONTEXT}" ]] && rm -f "${kc}"
  # 存在しないモデルを混ぜているので、失敗あり（exit 1）が期待どおり
  e2e::assert_eq "compare_ollama.sh exits 1 (one expected failure)" "${rc}" 1

  local m f
  for m in ${COMPARE_MODELS}; do
    f="${dir}/$(tr '/:' '__' <<<"${m}").json"
    if jq -e '.status == "ok"
        and (.latency.p50_ms | type == "number" and . > 0)
        and (.latency.p99_ms | type == "number" and . >= 0)
        and (.throughput.output_tokens_per_second | type == "number" and . > 0)
        and (.throughput.successful_requests == .throughput.total_requests)' "${f}" >/dev/null 2>&1; then
      e2e::check "${m}: p50/p99/tok/s recorded" true \
        "$(jq -r '"p50=\(.latency.p50_ms)ms p99=\(.latency.p99_ms)ms tok/s=\(.throughput.output_tokens_per_second)"' "${f}")"
    else
      e2e::check "${m}: p50/p99/tok/s recorded" false "$(cat "${f}" 2>/dev/null | head -c 300)"
    fi
  done

  f="${dir}/$(tr '/:' '__' <<<"${BOGUS_MODEL}").json"
  if jq -e '.status == "failed" and (.reason | length > 0)' "${f}" >/dev/null 2>&1; then
    e2e::check "nonexistent model is recorded as failed" true "$(jq -r '.reason' "${f}" | head -c 120)"
  else
    e2e::check "nonexistent model is recorded as failed" false "$(cat "${f}" 2>/dev/null | head -c 300)"
  fi
  e2e::assert_eq "summary.json has all candidates" \
    "$(jq 'length' "${dir}/summary.json" 2>/dev/null)" $(( $(wc -w <<<"${COMPARE_MODELS}") + 1 ))
}
