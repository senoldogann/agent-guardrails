#!/usr/bin/env bash
# Claude Code PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
# Active only while .agent/active exists (written by .agent/bin/start-spec / start-implement).
#   spec phase:      may write specs/<TICKET>/ (not its lock files), create new files, edit files it
#                    created, and edit the ticket's own locked files (amending a spec; re-lock needed).
#   implement phase: may write only paths matching specs/<TICKET>/write-allow that are not locked by
#                    any specs/*/spec.lock and not human-owned (tests, configs, manifests, dotfiles).
#   both phases:     never .agent/, .claude/, .cursor/, .codex/, .github/, AGENTS.md, CLAUDE.md, Makefile,
#                    ~/.claude/.
# Exit code 2 blocks the tool call and shows stderr to the agent.
# This is a local fast-feedback layer; ci-guard in CI is the authority (Bash writes bypass hooks).
set -euo pipefail
# shellcheck source=../bin/lib.sh
source "$(dirname "$0")/../bin/lib.sh"

input=$(cat)
root=${CLAUDE_PROJECT_DIR:?CLAUDE_PROJECT_DIR is not set}
active="$root/.agent/active"
[[ -f $active ]] || exit 0
read -r mode ticket <"$active"

file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")

deny() {
  printf 'BLOCKED by write-guard (%s phase, ticket %s): %s\nReason: %s\nDo not work around this. If the guarded file looks wrong, stop and tell the user.\n' \
    "$mode" "$ticket" "$file" "$1" >&2
  exit 2
}

[[ -n $file ]] || deny "tool input has no file path"
case $file in
  /*) ;;
  *) file="$root/$file" ;;
esac
case "$file/" in
  */../* | */./*) deny "path must be normalized (no '.' or '..' segments)" ;;
esac
[[ $file != "$HOME/.claude/"* ]] || deny "Claude configuration is read-only while a ticket is active"
[[ $file == "$root/"* ]] || exit 0

rel=${file#"$root"/}
case $rel in
  .agent/* | .claude/* | .cursor/* | .codex/* | .github/* | AGENTS.md | CLAUDE.md | Makefile)
    deny "guardrail and context files are human-owned (use the process-fix skill to propose changes)"
    ;;
esac

spec_phase() {
  local created="$root/.agent/created-$ticket"
  case $rel in
    specs/"$ticket"/spec.lock | specs/"$ticket"/tests.lock) deny "lock files are written only by .agent/bin/spec-lock" ;;
    specs/"$ticket"/*) exit 0 ;;
    specs/*) deny "other tickets' specs are read-only" ;;
  esac
  if [[ -f $created ]] && grep -xF -- "$rel" "$created" >/dev/null; then
    exit 0
  fi
  if [[ -f "$root/specs/$ticket/locked-files" ]] && list_entries "$root/specs/$ticket/locked-files" | grep -xF -- "$rel" >/dev/null; then
    exit 0
  fi
  [[ ! -e $file ]] || deny "spec phase may only create new files; record the needed change in OPEN_QUESTIONS.md"
  printf '%s\n' "$rel" >>"$created"
  exit 0
}

implement_phase() {
  local lock pattern allow="$root/specs/$ticket/write-allow"
  for lock in "$root"/specs/*/spec.lock; do
    [[ -f $lock ]] || continue
    if sed -E 's/^[0-9a-f]{64}  //' "$lock" | grep -xF -- "$rel" >/dev/null; then
      deny "locked by $(basename "$(dirname "$lock")")/spec.lock (tests, types and acceptance specs are immutable)"
    fi
  done
  case $rel in
    specs/*) deny "specs/ is read-only in the implement phase" ;;
  esac
  ! is_human_owned "$rel" || deny "human-owned path (test, config, manifest or dotfile); implementation files only"
  [[ -f $allow ]] || deny "specs/$ticket/write-allow is missing"
  while IFS= read -r pattern; do
    case $pattern in '' | '#'*) continue ;; esac
    # shellcheck disable=SC2053 # glob match against a write-allow pattern is intended
    [[ $rel != $pattern ]] || exit 0
  done <"$allow"
  deny "not matched by specs/$ticket/write-allow"
}

case $mode in
  spec) spec_phase ;;
  implement) implement_phase ;;
  *) deny "unknown phase '$mode' in .agent/active" ;;
esac
