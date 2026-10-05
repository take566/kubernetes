#!/usr/bin/env bash
# Claude Code SessionStart hook: fetch the upstream remote and fast-forward the current branch when safe.
# Always exits 0 so that session startup is never blocked.
# Disable with GIT_AUTO_PULL=0 (also accepts false/no/off).

PREFIX="[git-auto-pull] "

say() {
  printf '%s%s\n' "$PREFIX" "$1"
}

case "$(printf '%s' "${GIT_AUTO_PULL:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Never block on credential / passphrase prompts
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# timeout is not always available (e.g. macOS without coreutils)
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 20"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 20"
else
  TIMEOUT_CMD=""
fi

branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)

# Fetch the branch's upstream remote; fall back to origin
remote=""
if [ -n "$branch" ]; then
  remote=$(git config --get "branch.$branch.remote" 2>/dev/null)
fi
[ -z "$remote" ] && remote="origin"

# remote "." means the upstream is a local branch: nothing to fetch
if [ "$remote" != "." ]; then
  if ! $TIMEOUT_CMD git fetch --prune --quiet "$remote" >/dev/null 2>&1; then
    say "fetch failed (offline?)"
    exit 0
  fi
fi

if [ -z "$branch" ]; then
  say "fetched only (detached HEAD)"
  exit 0
fi

if ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  say "fetched only (no upstream)"
  exit 0
fi

counts=$(git rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null)
if [ -z "$counts" ]; then
  say "fetched only (cannot compare with upstream)"
  exit 0
fi
ahead=$(printf '%s' "$counts" | awk '{print $1}')
behind=$(printf '%s' "$counts" | awk '{print $2}')

if [ "${behind:-0}" -eq 0 ]; then
  if [ "${ahead:-0}" -gt 0 ]; then
    say "up to date (ahead $ahead, not pushed)"
  else
    say "up to date"
  fi
  exit 0
fi

if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  say "skip pull: working tree dirty (behind $behind)"
  exit 0
fi

if [ "${ahead:-0}" -gt 0 ]; then
  say "skip pull: diverged (ahead $ahead, behind $behind)"
  exit 0
fi

if git merge --ff-only --no-overwrite-ignore --quiet '@{u}' >/dev/null 2>&1; then
  say "pulled $behind commit(s) into $branch"
else
  say "skip pull: fast-forward failed (behind $behind)"
fi
exit 0
