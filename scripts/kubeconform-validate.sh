#!/usr/bin/env bash
# kubeconform によるマニフェスト検証（CI とローカルの共通スクリプト）
#
#   (1) kustomization.yaml を持つ全ディレクトリを `kubectl kustomize` でビルドし、
#       その出力を kubeconform に通す（パッチはビルド後の形で検証される）。
#   (2) kustomize のパッチ / configMapGenerator・secretGenerator の files: として
#       参照されているファイルを除いた *.yaml を単体で検証する。
#
# スキーマが見つからない kind はエラーにする（fail-closed。-ignore-missing-schemas は使わない）。
# スキーマの無い新しい CRD 系の kind が出たら、KC_ARGS の -skip に GVK を追加する。
#
# Usage: ./scripts/kubeconform-validate.sh
# 必要: kubectl, kubeconform（helmCharts を使うディレクトリには helm も必要。
#       CI では helm が無ければ失敗、ローカルでは SKIP）
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "::error::bash 4 以上が必要（mapfile を使う）。macOS は brew install bash"
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FIND=/usr/bin/find
GREP=/usr/bin/grep
[ -x "$FIND" ] || FIND=find
[ -x "$GREP" ] || GREP=grep

for tool in kubectl kubeconform; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "::error::$tool is not installed"
    exit 1
  fi
done

KC_ARGS=(
  -strict -summary
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  # スキーマで検証できない kind だけを明示的に除外する:
  # - CustomResourceDefinition: 公開スキーマが無い（upstream の CRD をそのまま使っている）
  # - 残りは K8s リソースではない設定ファイル（kind / kubeadm / kubelet / kube-proxy / skaffold）
  -skip 'apiextensions.k8s.io/v1/CustomResourceDefinition,kind.x-k8s.io/v1alpha4/Cluster,kubeadm.k8s.io/v1beta3/ClusterConfiguration,kubeadm.k8s.io/v1beta3/InitConfiguration,kubelet.config.k8s.io/v1beta1/KubeletConfiguration,kubeproxy.config.k8s.io/v1alpha1/KubeProxyConfiguration,skaffold/v4beta11/Config'
)

# 検証対象外のディレクトリ（Helm wrapper chart / ランタイムデータ / CI 定義など）
PRUNE=(
  -path ./.git -o -path ./.github -o -path ./.claude -o -path ./data
  -o -path ./gitlab -o -path ./jenkins
  -o -path ./actions-runner-controller -o -path ./github-runners
  -o -name charts
)

FAILED=0
fail() {
  echo "::error::$*"
  FAILED=1
}

mapfile -t KUSTOMIZATIONS < <("$FIND" . \( "${PRUNE[@]}" \) -prune -o -type f -name kustomization.yaml -print | LC_ALL=C sort)

# --- ガード: 非推奨フィールドはパッチ自動除外の対象外なので禁止 -----------------
for k in "${KUSTOMIZATIONS[@]}"; do
  if "$GREP" -qE '^[[:space:]]*(patchesStrategicMerge|patchesJson6902):' "$k"; then
    echo "::error file=${k#./}::patchesStrategicMerge / patchesJson6902 は非推奨。patches: を使うこと"
    exit 1
  fi
  # files: のフロー形式（[a, b]）は除外リストの抽出が対応していないので禁止
  if "$GREP" -qE '^[[:space:]]*files:[[:space:]]*\[' "$k"; then
    echo "::error file=${k#./}::files: のフロー形式 [a, b] は非対応。ブロック形式（- path）で書くこと"
    exit 1
  fi
done

# --- (1) kustomize build → kubeconform ------------------------------------------
for k in "${KUSTOMIZATIONS[@]}"; do
  dir=$(dirname "$k")
  dir=${dir#./}
  echo "::group::kustomize build ${dir}"
  flags=(--load-restrictor LoadRestrictionsNone)
  if "$GREP" -qE '^helmCharts:' "$k"; then
    if command -v helm > /dev/null 2>&1; then
      flags+=(--enable-helm)
    elif [ -n "${CI:-}" ]; then
      echo "::endgroup::"
      fail "${dir}: helmCharts を使うが helm が無い"
      continue
    else
      echo "SKIP: ${dir} (helm not installed)"
      echo "::endgroup::"
      continue
    fi
  fi
  if ! out=$(kubectl kustomize "$dir" "${flags[@]}"); then
    echo "::endgroup::"
    fail "kustomize build failed: ${dir}"
    continue
  fi
  if ! printf '%s\n' "$out" | kubeconform "${KC_ARGS[@]}" -; then
    echo "::endgroup::"
    fail "kubeconform failed on kustomize build output: ${dir}"
    continue
  fi
  echo "::endgroup::"
done

# --- (2) 単体検証（kustomize のパッチ / generator 入力を除外） ---------------------
# 除外するのは次の参照先（/ で始まる JSON pointer は対象外）:
#   - patches[].path
#   - configMapGenerator / secretGenerator の files:（`key=path` 形式は path 部分）
# パス正規化は realpath -m --relative-to（GNU 拡張。macOS の BSD realpath に無い）を避け、
# cd + pwd で行う。存在しない参照は kustomize build 側で失敗するので無視してよい。
ROOT=$(pwd)
EXCLUDE_REFS=()
for k in "${KUSTOMIZATIONS[@]}"; do
  dir=$(dirname "$k")
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pdir=$(cd "$dir/$(dirname "$p")" 2> /dev/null && pwd) || continue
    abs="$pdir/$(basename "$p")"
    EXCLUDE_REFS+=("${abs#"$ROOT"/}")
  done < <({
             sed -nE 's/^[[:space:]]*-?[[:space:]]*path:[[:space:]]*["'\'']?([^"'\''[:space:]#]+)["'\'']?.*$/\1/p' "$k"
             # files: ブロック配下の "- path" / "- key=path"（mawk 互換）
             awk 'function ind(s){match(s,/^[ \t]*/);return RLENGTH} /^[ \t]*#/{next} inf&&NF{i=ind($0); if($0~/^[ \t]*-[ \t]/&&i>=fi){v=$0;sub(/^[ \t]*-[ \t]+/,"",v);sub(/[ \t]+#.*$/,"",v);gsub(/["\047]/,"",v);sub(/^[^=]*=/,"",v);print v;next} else if(i<=fi) inf=0} /^[ \t]*files:[ \t]*$/{inf=1;fi=ind($0)}' "$k"
           } | "$GREP" -vE '^/' | "$GREP" -E '\.(ya?ml|json)$' || true)
done

mapfile -t FILES < <(
  "$FIND" . \( "${PRUNE[@]}" \) -prune -o -type f -name '*.yaml' \
    -not -path './cert-manager/cert-manager.custom.yaml' \
    -not -name 'kustomization.yaml' \
    -not -name 'values.yaml' \
    -not -name '*-values.yaml' \
    -not -name 'Chart.yaml' \
    -not -name 'nginx-ingress.yaml' \
    -print \
  | sed 's|^\./||' | LC_ALL=C sort \
  | { if [ ${#EXCLUDE_REFS[@]} -gt 0 ]; then "$GREP" -vxF -f <(printf '%s\n' "${EXCLUDE_REFS[@]}") || true; else cat; fi; }
)

echo "::group::kubeconform single files (${#FILES[@]} files, ${#EXCLUDE_REFS[@]} patch/generator refs excluded)"
if [ ${#FILES[@]} -gt 0 ]; then
  if ! kubeconform "${KC_ARGS[@]}" "${FILES[@]}"; then
    echo "::endgroup::"
    fail "kubeconform failed on single-file manifests"
  else
    echo "::endgroup::"
  fi
else
  echo "::endgroup::"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "kubeconform validation FAILED"
  exit 1
fi
echo "kubeconform validation passed"
