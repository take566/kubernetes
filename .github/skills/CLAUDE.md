# Agent skills (canonical)

This directory (`.github/skills/`) is the **canonical** location for agent skills in this repository. Use it for GitHub Copilot, Claude Code, and Cursor.

## Skills

| Skill | Path |
|-------|------|
| CI/CD | `cicd/` |
| Code quality | `code-quality/` |
| Data analysis | `data-analysis/` |
| DevOps | `devops/` |
| Document processing | `document-processing/` |
| LLM ops | `llmops/` |

`.claude/skills/` contains only a redirect README; do not duplicate skills there.

---

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
