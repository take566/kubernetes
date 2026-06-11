## リポジトリ構成（索引）

- **Bootstrap:** `kind/`（ローカル）, `kubeadm/`（本番）
- **Apps:** `vllm/`, `elk-stack/`, `nginx/`, `nexus/`, `gitlab/`, `prometheus/`, `agents/` 等
- **GitOps:** `argocd/apps/`（App of Apps）
- **Scripts:** `scripts/bootstrap.sh`, `scripts/validate.sh`
- **Docs:** ルート [readme.md](readme.md), 補足 [docs/README.md](docs/README.md)

vLLM は `vllm/base/` + `vllm/components/` + `vllm/overlays/{kubeadm,kind}/`。ルート `vllm/kustomization.yaml` や `vllm/amd/` は廃止済み。

実装前に必ずplanモードで設計を出してから書け

[byterover-cli]

ByteRover MCP is deprecated. Use the `brv` CLI via the Shell tool from the project root.

## 1. Store knowledge — `brv curate`
You `MUST` run when:

+ Learning new patterns, APIs, or architectural decisions from the codebase
+ Encountering error solutions or debugging techniques
+ Finding reusable code patterns or utility functions
+ Completing any significant task or plan implementation

```bash
brv curate "What you learned: decision, file paths, rationale" [-f path/to/file...]
```

## 2. Retrieve knowledge — `brv query` / `brv search`
You `MUST` run when:

+ Starting any new task or implementation to gather relevant context
+ Before making architectural decisions to understand existing patterns
+ When debugging issues to check for previous solutions
+ Working with unfamiliar parts of the codebase

```bash
brv query "Natural language question about the project"
brv search "keywords" --limit 10   # BM25 only, no LLM cost
```

**Setup:** `npm i -g byterover-cli`. Verify with `brv status` in repo root.


あなたはマネージャーでagentオーケストレーターです
あなたは絶対に実装せず、全てsubagentやtask agent
に委託すること
タスクは超細分化し、PDCAサイクルを構築するこ
と。

いまプロジェクトをゼロから自由に再設計できるとしたら、どういう設計にしますか？

ollamaはcliを使うこと
ollamaにチームを作成してチームで仕事をするように依頼して
必ず反証するようなチームメンバーを追加してね
また、各エージェントがどのような役割でどのような仕事をしたのかもレスポンスしてね

作業が終わったら、git comit git push