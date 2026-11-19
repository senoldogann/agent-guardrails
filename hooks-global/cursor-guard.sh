#!/usr/bin/env bash
# Global Cursor Agent hook for beforeShellExecution and beforeReadFile (registered in ~/.cursor/hooks.json by
# install.sh, and run by the project shim .agent/hooks/cursor-guard.sh). It holds no rules of its own: it
# translates Cursor's hook protocol into bash-guard.sh's input and bash-guard's verdict back into Cursor's
# answer, so bash-guard.sh stays the single source of truth for what is blocked.
#   beforeShellExecution: the command is checked as it is, in its working directory (every workspace root when
#     Cursor sends none).
#   beforeReadFile: the path is checked as a file read, against bash-guard's rules on the owner's files and
#     credential files, in the file's own directory and every workspace root, so a kit repository opened next to
#     another folder is guarded too.
# bash-guard runs once per directory; the first refusal decides.
# Cursor input (https://cursor.com/docs/agent/hooks): JSON on stdin with hook_event_name, workspace_roots and,
# per event, command and cwd, or file_path. Answer: JSON on stdout with permission "allow" or "deny" and the
# messages each event accepts. Cursor blocks on invalid JSON, and install.sh registers this hook with
# failClosed, so a crash or timeout blocks too; this script also turns its own errors into a deny.
# Not a boundary: like bash-guard it matches text, and ci-guard and the rulesets on GitHub are the authority.
set -euo pipefail
hooks=$(dirname "$(realpath "$0")")

# Prints Cursor's deny answer for the event. Arguments: event, the reason shown to the user and the agent.
deny_answer() {
  case $1 in
    beforeReadFile) jq -n -c --arg m "$2" '{permission: "deny", user_message: $m}' ;;
    *) jq -n -c --arg m "$2" '{permission: "deny", user_message: $m, agent_message: $m}' ;;
  esac
}

event=""
# Fail closed: an internal error (missing jq, unreadable input) denies the action instead of letting it through.
# Exit 2 is Cursor's own deny, for when not even the JSON answer can be written.
# shellcheck disable=SC2154 # status is assigned inside the trap
trap 'status=$?; if [[ $status -ne 0 ]]; then deny_answer "$event" "BLOCKED by cursor-guard: internal error (exit $status); ask the user to check the hook" || exit 2; exit 0; fi' EXIT

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
case $event in
  beforeShellExecution)
    command=$(jq -r '.command // empty' <<<"$input")
    [[ -n $command ]] || {
      deny_answer "$event" "BLOCKED by cursor-guard: the hook input has no command"
      exit 0
    }
    tool_input=$(jq -n -c --arg c "$command" '{command: $c}')
    dirs=$(jq -r 'if (.cwd // "") != "" then .cwd else (.workspace_roots // [])[] end' <<<"$input")
    ;;
  beforeReadFile)
    file=$(jq -r '.file_path // empty' <<<"$input")
    [[ -n $file ]] || {
      deny_answer "$event" "BLOCKED by cursor-guard: the hook input has no file_path"
      exit 0
    }
    tool_input=$(jq -n -c --arg f "$file" '{file_path: $f}')
    dirs=$(jq -r '(.file_path | sub("/[^/]*$"; "")), (.cwd // empty), (.workspace_roots // [])[]' <<<"$input")
    ;;
  *)
    deny_answer "$event" "BLOCKED by cursor-guard: unsupported hook event '$event'; register it for beforeShellExecution and beforeReadFile only"
    exit 0
    ;;
esac

# With no directory at all, the one empty line still runs bash-guard once, for the rules that hold everywhere.
while IFS= read -r dir; do
  verdict=0
  reason=$(jq -n -c --arg d "$dir" --argjson t "$tool_input" '{cwd: $d, tool_input: $t}' |
    "$hooks/bash-guard.sh" 2>&1 >/dev/null) || verdict=$?
  case $verdict in
    0) ;;
    2)
      deny_answer "$event" "$reason"
      exit 0
      ;;
    *)
      deny_answer "$event" "BLOCKED by cursor-guard: bash-guard failed (exit $verdict): $reason"
      exit 0
      ;;
  esac
done <<<"$dirs"
jq -n -c '{permission: "allow"}'
