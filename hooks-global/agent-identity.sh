#!/usr/bin/env bash
# Global Claude Code hook (registered in ~/.claude/settings.json by install.sh) that gives the agent its own
# GitHub identity in kit repositories where the owner's agent App (`guardrails agent create`) is installed.
#   SessionStart: mints a one-hour installation token limited to the session's repository and writes exports
#     to $CLAUDE_ENV_FILE, so every Bash command of the session runs gh, and git through
#     `gh auth git-credential`, as the App's bot. SSH remotes are rewritten to HTTPS so pushes use that token too.
#   PreToolUse (Bash): renews the token when it is older than 45 minutes, and blocks gh and git push when the
#     session's identity was not set up for this repository (the session started elsewhere, or in another kit
#     repository), because its GitHub calls would then run with the owner's login or another repo's token.
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

# The repository a session's identity was set up for, by Claude Code session id.
session_marker() {
  printf '%s/sessions/by-id/%s\n' "$(agent_dir)" "$1"
}

session_start() {
  local root=$1 session_id=$2 repo installation problems session err marker
  repo=$(origin_repo "$root")
  [[ -n $repo ]] || return 0
  if [[ -n $session_id ]]; then
    marker=$(session_marker "$session_id")
    mkdir -p "$(dirname "$marker")"
    # Markers of sessions older than a week are of no use any more.
    find "$(dirname "$marker")" -type f -mtime +7 -delete
    printf '%s\n' "$repo" >"$marker"
  fi
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

# Blocks the command when it reaches GitHub (gh, git push) in a repository this session's identity was not set
# up for. Arguments: repository root, session id, the Bash command.
require_session_identity() {
  local repo set_up="" label
  grep -Eq '(^|[^[:alnum:]_.-])(gh([[:space:]]|$)|git[^;&|]*[[:space:]]push([[:space:]]|$))' <<<"$3" || return 0
  repo=$(origin_repo "$1")
  [[ -n $repo ]] || return 0
  [[ -z $2 || ! -f $(session_marker "$2") ]] || set_up=$(<"$(session_marker "$2")")
  [[ $set_up == "$repo" ]] && return 0
  if [[ -n $set_up ]]; then label="for $set_up"; else label="outside the kit repositories"; fi
  printf 'BLOCKED by agent-identity: this session'"'"'s GitHub identity was set up %s, not for %s, so gh and git push would not run as the agent here. Start a new Claude Code session inside %s.\n' \
    "$label" "$repo" "$1" >&2
  exit 2
}

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
session_id=$(jq -r '.session_id // empty' <<<"$input")
is_kit_project "$cwd" || exit 0
agent_app_registered || exit 0
root=$(git -C "$cwd" rev-parse --show-toplevel)
case $(jq -r '.hook_event_name // empty' <<<"$input") in
  SessionStart)
    [[ -n ${CLAUDE_ENV_FILE:-} ]] ||
      die "agent-identity: CLAUDE_ENV_FILE is not set; this Claude Code cannot hand the agent its own identity"
    session_start "$root" "$session_id"
    ;;
  PreToolUse)
    require_session_identity "$root" "$session_id" "$(jq -r '.tool_input.command // empty' <<<"$input")"
    # Exit 1 shows the error to the user without blocking the command; the agent's gh call then fails loudly.
    renew_if_old "$root" || exit 1
    ;;
esac
exit 0
