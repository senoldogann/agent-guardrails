#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash, committed with the project so every teammate's agent is guarded,
# not only on machines where the kit's install.sh registered the global hook. It runs the installed kit's
# bash-guard (found through the ~/.claude/skills/guardrails-init link that install.sh creates). Without
# the kit installed it blocks gh and git push, the calls that act on GitHub with the user's identity.
# A command is allowed only through allow: any other end, an error of this shim included (a dangling skill link,
# missing jq, a fatal error after which Bash 3.2 runs the EXIT trap with status 0), blocks it with 2.
set -euo pipefail
# shellcheck disable=SC2154 # status is assigned inside the trap
trap 'status=$?; if [[ ${allowed:-} != 1 ]]; then [[ $status -eq 2 ]] || printf "BLOCKED by .agent/hooks/bash-guard.sh: internal error (exit %s); ask the user to check the hook\n" "$status" >&2; exit 2; fi' EXIT
allow() {
  allowed=1
  exit 0
}
input=$(cat)
skill="$HOME/.claude/skills/guardrails-init"
if [[ -d $skill ]]; then
  guard="$(cd "$(realpath "$skill")/../.." && pwd -P)/hooks-global/bash-guard.sh"
  if [[ -x $guard ]]; then
    if "$guard" <<<"$input"; then allow; fi
    exit 2
  fi
fi
command=$(jq -r '.tool_input.command // empty' <<<"$input")
if grep -Eq '(^|[^[:alnum:]_.-])(gh[[:space:]]|git[[:space:]]+push)' <<<"$command"; then
  printf 'BLOCKED: the agent-guardrails kit is not installed on this machine, so GitHub actions are not guarded here. Ask the user to install the kit (clone it and run ./install.sh), then try again.\n' >&2
  exit 2
fi
allow
