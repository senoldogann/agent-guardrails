#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash, committed with the project so every teammate's agent is guarded,
# not only on machines where the kit's install.sh registered the global hook. It runs the installed kit's
# bash-guard (found through the ~/.claude/skills/guardrails-init link that install.sh creates). Without
# the kit installed it blocks gh and git push, the calls that act on GitHub with the user's identity.
set -euo pipefail
input=$(cat)
skill="$HOME/.claude/skills/guardrails-init"
if [[ -L $skill ]]; then
  guard="$(cd "$(realpath "$skill")/../.." && pwd -P)/hooks-global/bash-guard.sh"
  if [[ -x $guard ]]; then
    "$guard" <<<"$input"
    exit $?
  fi
fi
command=$(jq -r '.tool_input.command // empty' <<<"$input")
if grep -Eq '(^|[^[:alnum:]_.-])(gh[[:space:]]|git[[:space:]]+push)' <<<"$command"; then
  printf 'BLOCKED: the agent-guardrails kit is not installed on this machine, so GitHub actions are not guarded here. Ask the user to install the kit (clone it and run ./install.sh), then try again.\n' >&2
  exit 2
fi
exit 0
