#!/usr/bin/env bash
# Claude Code PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
# Active only while .agent/active exists (written by .agent/bin/start-spec / start-implement).
#   spec phase:      may write specs/<TICKET>/ (not its lock files), create new test, contract and source files (no
#                    configuration, manifests, build files or dotfiles, also not inside a test directory), edit files
#                    it created, and edit the files the ticket's spec.lock locks (amending a spec; re-lock needed).
#   implement phase: may write only paths matching specs/<TICKET>/write-allow that are not locked by
#                    any specs/*/spec.lock and not human-owned (tests, configs, manifests, dotfiles).
#   both phases:     never .agent/, .claude/, .cursor/, .codex/, .github/, AGENTS.md, CLAUDE.md, Makefile,
#                    ~/.claude/.
# Paths are judged as the file system resolves them: every link is followed, an existing file is judged by the name
# its directory stores (on macOS a name in another case or Unicode form, ſ for s, opens the same file), a new name
# must be plain ASCII, and a file with several hard links is refused, so no other name stands in for a guarded file.
# Guarded names are compared without case, as macOS's default file system compares them.
# Exit code 2 blocks the tool call and shows stderr to the agent. A write is allowed only through allow; every other
# end, an internal error included, blocks it.
# This is a local fast-feedback layer; ci-guard in CI is the authority (Bash writes bypass hooks).
set -euo pipefail
# Fail closed, also after the fatal errors (a failed source, an unset variable) after which Bash 3.2, macOS's
# /bin/bash, runs the EXIT trap with status 0. A deny, also one in a subshell, ends with 2 and has said why.
# Not inherited from the environment: only allow sets it.
allowed=0
# shellcheck disable=SC2154 # status is assigned inside the trap
trap 'status=$?; if [[ ${allowed:-} != 1 ]]; then [[ $status -eq 2 ]] || printf "BLOCKED by write-guard: internal error (exit %s); ask the user to check .agent/hooks/write-guard.sh\n" "$status" >&2; exit 2; fi' EXIT
allow() {
  allowed=1
  exit 0
}
# shellcheck source=../bin/lib.sh
source "$(dirname "$0")/../bin/lib.sh"

input=$(cat)
root=${CLAUDE_PROJECT_DIR:?CLAUDE_PROJECT_DIR is not set}
active="$root/.agent/active"
[[ -f $active ]] || allow
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

# Prints the name a directory stores for an existing entry, found by its inode. Arguments: the directory, the entry.
stored_name() {
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ ! -L $entry && -e $entry ]] || continue
    if [[ $entry -ef $2 ]]; then
      printf '%s\n' "${entry##*/}"
      return 0
    fi
  done
  printf '%s\n' "${2##*/}"
}

# Prints an absolute path with every link resolved, also below a part that does not exist yet (the file a write
# would create). Existing parts come out as the file system stores them: directories through the external pwd (Bash
# 3.2's builtin pwd -P keeps a directory as typed, in another case or Unicode form, or under the
# /System/Volumes/Data firmlink), the last name through stored_name. Argument: absolute path.
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
      path=$(cd -P "$path" && /bin/pwd -P) || return 1
      printf '%s%s\n' "${path%/}" "$rest"
      return 0
    elif [[ -e $path ]]; then
      link=$(cd -P "$(dirname "$path")" && /bin/pwd -P) || return 1
      printf '%s/%s%s\n' "${link%/}" "$(stored_name "$link" "$path")" "$rest"
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
root=$(CDPATH='' cd -P -- "$root" && /bin/pwd -P)
target=$(physical_path "$file")
# A link to a directory that does not exist yet can still leave a '..' behind.
case "$target/" in
  */../* | */./*) deny "path must be normalized (no '.' or '..' segments)" ;;
esac
claude_home=$(physical_path "$HOME/.claude")
case "$(lower "$target")/" in
  "$(lower "$claude_home")"/*) deny "Claude configuration is read-only while a ticket is active" ;;
esac
[[ $target == "$root/"* ]] || allow

rel=${target#"$root"/}
# A newline or other control character would add lines to the created list and the checks that read it.
is_repo_path "$rel" || deny "the path has a control character, a backslash, a backtick or a blank at the end of a name"
if [[ -e $target ]]; then
  if [[ -f $target ]]; then
    linked=$(find "$target" -maxdepth 0 -links +1)
    [[ -z $linked ]] || deny "the file has several hard links, and another of them could be a guarded file"
  fi
else
  # Only the names this write creates must be ASCII; an existing directory keeps the name it has.
  existing=$target
  while [[ ! -e $existing ]]; do existing=$(dirname "$existing"); done
  if LC_ALL=C grep '[^ -~]' <<<"${target#"$existing"}" >/dev/null; then
    deny "a new name must be plain ASCII: macOS reads some other characters as letters of a guarded name (ſ as s)"
  fi
fi
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
    specs/"$ticket"/*) allow ;;
  esac
  case $rel_lower in
    specs/*) deny "other tickets' specs are read-only" ;;
  esac
  if [[ -f $created ]] && grep -xF -- "$rel" "$created" >/dev/null; then
    allow
  fi
  # The lock, not locked-files: locked-files is the agent's to write in this phase, the lock only spec-lock's.
  if [[ -f $lock ]] && manifest_paths <"$lock" | grep -xF -- "$rel" >/dev/null; then
    allow
  fi
  if is_human_owned "$rel" && ! is_test_path "$rel"; then
    deny "human-owned path (configuration, manifest, build file or dotfile); record the needed change in OPEN_QUESTIONS.md"
  fi
  [[ ! -e $target ]] || deny "spec phase may only create new files; record the needed change in OPEN_QUESTIONS.md"
  printf '%s\n' "$rel" >>"$created"
  allow
}

implement_phase() {
  local lock pattern allow_file="$root/specs/$ticket/write-allow"
  for lock in "$root"/specs/*/spec.lock; do
    [[ -f $lock ]] || continue
    [[ -r $lock ]] || deny "cannot read $(basename "$(dirname "$lock")")/spec.lock, so cannot tell what it locks"
    if lock_paths "$lock" | grep -ixF -- "$rel" >/dev/null; then
      deny "locked by $(basename "$(dirname "$lock")")/spec.lock (tests, types and acceptance specs are immutable)"
    fi
  done
  case $rel_lower in
    specs/*) deny "specs/ is read-only in the implement phase" ;;
  esac
  ! is_human_owned "$rel" || deny "human-owned path (test, config, manifest or dotfile); implementation files only"
  [[ -f $allow_file ]] || deny "specs/$ticket/write-allow is missing"
  while IFS= read -r pattern; do
    case $pattern in '' | '#'*) continue ;; esac
    # shellcheck disable=SC2053 # glob match against a write-allow pattern is intended
    [[ $rel != $pattern ]] || allow
  done <"$allow_file"
  deny "not matched by specs/$ticket/write-allow"
}

case $mode in
  spec) spec_phase ;;
  implement) implement_phase ;;
  *) deny "unknown phase '$mode' in .agent/active" ;;
esac
