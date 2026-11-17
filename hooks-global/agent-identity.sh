#!/usr/bin/env bash
# Global Claude Code hook (registered in ~/.claude/settings.json by install.sh) that gives the agent its own
# GitHub identity in kit repositories where the owner's agent App (`guardrails agent create`) is installed.
#   SessionStart: mints a one-hour installation token limited to the session's repository and writes exports
#     to $CLAUDE_ENV_FILE, so every Bash command of the session runs gh, and git through
#     `gh auth git-credential`, as the App's bot. SSH remotes are rewritten to HTTPS so pushes use that token too.
#   PreToolUse (Bash): renews the token when it is older than 45 minutes.
# The PRs the agent opens are then authored by the bot, and the owner approves them with GitHub reviews.
# When the App is registered but its installation cannot be looked up or no token can be minted, the session
# gets an empty gh config: GitHub calls fail instead of silently running as the owner. Not a boundary at the
# same macOS user: the agent could still reach the owner's own login (bash-guard blocks the obvious ways).
set -euo pipefail
hooks=$(dirname "$(realpath "$0")")
kit=$(cd "$hooks/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$hooks/kit-project.sh"
source "$kit/bin/agent-app-lib.sh"

# Points the session at an empty gh config and tells the agent why. Arguments: owner/repo, error text.
fail_closed() {
  local session
  session="$(agent_dir)/sessions/unavailable"
  mkdir -p "$session"
  agent_env_exports "$session" "$(command -v gh)" >>"$CLAUDE_ENV_FILE"
  printf 'agent-guardrails: no agent token for %s (%s). GitHub calls will fail in this session; tell the owner.\n' \
    "$1" "$2"
}

session_start() {
  local root=$1 repo installation problems session err
  repo=$(origin_repo "$root")
  [[ -n $repo ]] || return 0
  err=$(mktemp)
  if ! installation=$(agent_installation "$repo" 2>"$err"); then
    fail_closed "$repo" "$(tr '\n' ' ' <"$err")"
    rm -f "$err"
    return 0
  fi
  if [[ -z $installation ]]; then
    rm -f "$err"
    printf 'agent-guardrails: the agent App is not installed on %s, so gh and git run with the owner'"'"'s login here.\n' "$repo"
    return 0
  fi
  problems=$(installation_problems <<<"$installation")
  [[ -z $problems ]] || printf 'agent-guardrails: tell the owner about the agent App on %s: %s\n' "$repo" "$problems"
  if ! session=$(agent_session_token "$repo" "$(jq -r .id <<<"$installation")" 2>"$err"); then
    fail_closed "$repo" "$(tr '\n' ' ' <"$err")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  agent_env_exports "$session" "$(command -v gh)" >>"$CLAUDE_ENV_FILE"
  printf 'agent-guardrails: gh and git push run as %s[bot] in this session; the owner approves your PRs with a GitHub review.\n' \
    "$(jq -r .slug "$(agent_dir)/app.json")"
}

renew_if_old() {
  local root=$1 repo session installation
  repo=$(origin_repo "$root")
  [[ -n $repo ]] || return 0
  session="$(agent_dir)/sessions/${repo/\//__}"
  [[ -f $session/hosts.yml ]] || return 0
  [[ -n $(find "$session/hosts.yml" -mmin +45 2>/dev/null) ]] || return 0
  installation=$(agent_installation "$repo")
  [[ -n $installation ]] || return 0
  agent_session_token "$repo" "$(jq -r .id <<<"$installation")" >/dev/null
}

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
is_kit_project "$cwd" || exit 0
agent_app_registered || exit 0
root=$(git -C "$cwd" rev-parse --show-toplevel)
case $(jq -r '.hook_event_name // empty' <<<"$input") in
  SessionStart)
    [[ -n ${CLAUDE_ENV_FILE:-} ]] ||
      die "agent-identity: CLAUDE_ENV_FILE is not set; this Claude Code cannot hand the agent its own identity"
    session_start "$root"
    ;;
  PreToolUse)
    # Exit 1 shows the error to the user without blocking the command; the agent's gh call then fails loudly.
    renew_if_old "$root" || exit 1
    ;;
esac
exit 0
