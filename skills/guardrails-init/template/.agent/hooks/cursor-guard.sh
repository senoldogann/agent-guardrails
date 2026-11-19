#!/usr/bin/env bash
# Cursor Agent hook for beforeShellExecution and beforeReadFile (.cursor/hooks.json), committed with the
# project so every teammate's Cursor agent is guarded, not only on machines where the kit's install.sh
# registered the global hook. It runs the installed kit's cursor-guard (found through the
# ~/.claude/skills/guardrails-init link that install.sh creates). Without the kit installed it denies gh and
# git push, the calls that act on GitHub with the user's identity, and lets reads through. An installed kit too
# old to have cursor-guard denies every shell command until it is updated, rather than guarding only part of it.
set -euo pipefail
input=$(cat)
skill="$HOME/.claude/skills/guardrails-init"
reason='BLOCKED: the agent-guardrails kit is not installed on this machine, so GitHub actions are not guarded here. Ask the user to install the kit (clone it and run ./install.sh), then try again.'
github_only=1
if [[ -d $skill ]]; then
  hooks="$(cd "$(realpath "$skill")/../.." && pwd -P)/hooks-global"
  if [[ -x $hooks/cursor-guard.sh ]]; then
    "$hooks/cursor-guard.sh" <<<"$input"
    exit $?
  fi
  if [[ -x $hooks/bash-guard.sh ]]; then
    reason="BLOCKED: the agent-guardrails kit installed at ${hooks%/hooks-global} is too old to guard Cursor. Ask the user to update it, then try again."
    github_only=0
  fi
fi
[[ $(jq -r '.hook_event_name // empty' <<<"$input") == beforeShellExecution ]] || {
  jq -n -c '{permission: "allow"}'
  exit 0
}
command=$(jq -r '.command // empty' <<<"$input")
if [[ $github_only -eq 0 ]] || grep -Eq '(^|[^[:alnum:]_.-])(gh[[:space:]]|git[[:space:]]+push)' <<<"$command"; then
  jq -n -c --arg m "$reason" '{permission: "deny", user_message: $m, agent_message: $m}'
  exit 0
fi
jq -n -c '{permission: "allow"}'
