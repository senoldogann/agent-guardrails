#!/usr/bin/env bash
# Claude Code PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
# Active only while .agent/active exists (written by .agent/bin/start-spec / start-implement).
#   spec phase:      may write specs/<TICKET>/ (not its lock files), create new files other than configuration,
#                    manifests, build files and dotfiles (tests, contracts and stubs are fine), edit files it
#                    created, and edit the files the ticket's spec.lock locks (amending a spec; re-lock needed).
#   implement phase: may write only paths matching specs/<TICKET>/write-allow that are not locked by
#                    any specs/*/spec.lock and not human-owned (tests, configs, manifests, dotfiles).
#   both phases:     never .agent/, .claude/, .cursor/, .codex/, .github/, AGENTS.md, CLAUDE.md, Makefile,
#                    ~/.claude/.
# Paths are judged as the file system resolves them: every link is followed, so no link inside or outside the
# project stands in for a guarded file, and guarded names are compared without case, as macOS's default file
# system compares them.
# Exit code 2 blocks the tool call and shows stderr to the agent. Any other failure is turned into 2 as well, so an
# error in this hook blocks the write instead of letting it through.
# This is a local fast-feedback layer; ci-guard in CI is the authority (Bash writes bypass hooks).
set -euo pipefail
# shellcheck disable=SC2154 # status is assigned inside the trap
trap 'status=$?; if [[ $status -ne 0 && $status -ne 2 ]]; then printf "BLOCKED by write-guard: internal error (exit %s); ask the user to check .agent/hooks/write-guard.sh\n" "$status" >&2; exit 2; fi' EXIT
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

lower() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

# Prints an absolute path with every link resolved, also below a part that does not exist yet (the file a write
# would create). Directories come out as the file system names them, in their stored case. Argument: absolute path.
physical_path() {
  local path=$1 rest="" link hops=0
  while :; do
    if [[ -L $path ]]; then
      hops=$((hops + 1))
      [[ $hops -le 40 ]] || deny "a link loop at $path"
      link=$(readlink "$path") || return 1
      [[ $link == /* ]] || link="$(dirname "$path")/$link"
      path=$link
    elif [[ -d $path ]]; then
      path=$(cd -P "$path" && pwd -P) || return 1
      printf '%s%s\n' "${path%/}" "$rest"
      return 0
    elif [[ -e $path ]]; then
      link=$(cd -P "$(dirname "$path")" && pwd -P) || return 1
      printf '%s/%s%s\n' "${link%/}" "${path##*/}" "$rest"
      return 0
    elif [[ -z $path || $path == / ]]; then
      printf '%s\n' "${rest:-/}"
      return 0
    else
      rest="/${path##*/}$rest"
      path=${path%/*}
    fi
  done
}

[[ -n $file ]] || deny "tool input has no file path"
case $file in
  /*) ;;
  *) file="$root/$file" ;;
esac
case "$file/" in
  */../* | */./*) deny "path must be normalized (no '.' or '..' segments)" ;;
esac
root=$(CDPATH='' cd -P -- "$root" && pwd -P)
target=$(physical_path "$file")
# A link to a directory that does not exist yet can still leave a '..' behind.
case "$target/" in
  */../* | */./*) deny "path must be normalized (no '.' or '..' segments)" ;;
esac
claude_home=$(physical_path "$HOME/.claude")
case "$(lower "$target")/" in
  "$(lower "$claude_home")"/*) deny "Claude configuration is read-only while a ticket is active" ;;
esac
[[ $target == "$root/"* ]] || exit 0

rel=${target#"$root"/}
rel_lower=$(lower "$rel")
case $rel_lower in
  .agent/* | .claude/* | .cursor/* | .codex/* | .github/* | agents.md | claude.md | makefile)
    deny "guardrail and context files are human-owned (use the process-fix skill to propose changes)"
    ;;
esac

spec_phase() {
  local created="$root/.agent/created-$ticket" lock="$root/specs/$ticket/spec.lock" own
  own=$(lower "specs/$ticket")
  case $rel_lower in
    "$own/spec.lock" | "$own/tests.lock") deny "lock files are written only by .agent/bin/spec-lock" ;;
  esac
  case $rel in
    specs/"$ticket"/*) exit 0 ;;
  esac
  case $rel_lower in
    specs/*) deny "other tickets' specs are read-only" ;;
  esac
  if [[ -f $created ]] && grep -xF -- "$rel" "$created" >/dev/null; then
    exit 0
  fi
  # The lock, not locked-files: locked-files is the agent's to write in this phase, the lock only spec-lock's.
  if [[ -f $lock ]] && manifest_paths <"$lock" | grep -xF -- "$rel" >/dev/null; then
    exit 0
  fi
  if is_human_owned "$rel" && ! is_test_path "$rel"; then
    deny "human-owned path (configuration, manifest, build file or dotfile); record the needed change in OPEN_QUESTIONS.md"
  fi
  [[ ! -e $target ]] || deny "spec phase may only create new files; record the needed change in OPEN_QUESTIONS.md"
  printf '%s\n' "$rel" >>"$created"
  exit 0
}

implement_phase() {
  local lock pattern allow="$root/specs/$ticket/write-allow"
  for lock in "$root"/specs/*/spec.lock; do
    [[ -f $lock ]] || continue
    if lock_paths "$lock" | grep -ixF -- "$rel" >/dev/null; then
      deny "locked by $(basename "$(dirname "$lock")")/spec.lock (tests, types and acceptance specs are immutable)"
    fi
  done
  case $rel_lower in
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
