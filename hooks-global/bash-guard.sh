#!/usr/bin/env bash
# Global Claude Code PreToolUse hook for Bash (registered in ~/.claude/settings.json by install.sh).
# The agent works with the owner's GitHub identity, so actions reserved for the human must be blocked
# before they run: approving or admin-merging PRs, approving deployments (merge-approval environment),
# changing repo settings/rulesets/workflows/secrets, reading credentials, and pushing to the default
# branch. `gh` is allow-listed per subcommand; everything else is a deny-list over the whole command
# string, including text inside quotes (so `bash -c "..."` wrappers are covered).
# Limits: obfuscated commands (string concatenation, scripts written to files) can evade text matching.
# The server-side backstop is a fine-grained GH_TOKEN without Administration/Workflows/Deployments/
# Environments permissions. Exit code 2 blocks the call and shows stderr to the agent.
set -euo pipefail

input=$(cat)
raw=$(jq -r '.tool_input.command // empty' <<<"$input")
[[ -n $raw ]] || exit 0
# Normalize common spellings so quoting or path tricks do not hide a gh call:
# drop quotes and backslashes, and turn $(which gh)/$(command -v gh)/`which gh` into gh.
quote_chars=$'"\'\\'
# shellcheck disable=SC2016 # $( and backticks are literal text to rewrite, not expansions
gh_lookup='s/\$\((which|command -v|type -p) gh\)/gh/g; s/`(which|command -v|type -p) gh`/gh/g'
cmd=$(tr -d "$quote_chars" <<<"$raw" | sed -E "$gh_lookup")

deny() {
  printf 'BLOCKED by bash-guard: %s\nThis is reserved for the human (approvals, merges, credentials, repository settings). Do not work around it; ask the user to do it.\n' "$1" >&2
  exit 2
}

matches() {
  grep -Eiq -- "$1" <<<"$cmd"
}

# Credentials and token fallbacks.
matches 'security[[:space:]]+(find|dump|export)-' && deny "reading the macOS keychain"
matches 'git[[:space:]]+credential' && deny "git credential helper access"
matches '\.config/gh|hosts\.yml|\.git-credentials|\.netrc|settings\.local\.json' && deny "reading stored GitHub credentials"
matches '(GH|GITHUB)_(ENTERPRISE_)?TOKEN' && deny "referencing the GitHub token (read, override or unset)"
matches 'pending_deployments|deployment_protection|/environments/' && deny "deployment approval or environment access"
matches '(^|/|[[:space:]])(approve|revoke)-head([[:space:]]|$)|/statuses/' && deny "merge approval (owner-only commit status)"
# shellcheck disable=SC2016 # backticks are literal regex characters
matches '(^|[;&|(`"'"'"'[:space:]])(printenv|export[[:space:]]+-p|set)([[:space:]]*($|[;&|)`"'"'"']))|(^|[;&|(`[:space:]])env[[:space:]]*($|[;&|)`])' &&
  deny "dumping the environment (may expose tokens)"
matches 'git[[:space:]]+config[^;&|]*(credential|insteadof|core\.hookspath|url\.)' && deny "changing git credential/URL/hook configuration"

# Git over SSH would use the owner's key (full rights, incl. workflow files) instead of the agent token.
matches 'git[[:space:]]+(push|remote|clone|fetch|pull)[^;&|]*(git@github\.com|ssh://)' && deny "git over SSH (use the HTTPS remote with the agent token)"

# Direct GitHub API access outside gh.
matches '(curl|wget|http|https|xh)[^;&|]*(api\.github\.com|github\.com/[^[:space:]]*/(settings|reviews|merge))' &&
  deny "calling the GitHub API directly"

# Pushing to the default branch or rewriting remote refs.
if matches 'git[[:space:]]+push'; then
  matches 'git[[:space:]]+push[^;&|]*([[:space:]:+/](main|master)([[:space:]]|$|[;&|])|--mirror|--tags|--delete|[[:space:]]-d([[:space:]]|$)|--all)' &&
    deny "pushing to the default branch, deleting remote refs or pushing tags/all refs"
fi

# gh: allow-list of subcommands; the rest needs the human.
while IFS= read -r call; do
  [[ -n $call ]] || continue
  read -r _gh group action rest <<<"$call" || true
  case "$group $action" in
    "pr create" | "pr view" | "pr list" | "pr checks" | "pr diff" | "pr status" | "pr comment" | "pr ready" | "pr close" | "pr checkout") ;;
    "pr edit")
      [[ " $rest " != *" --base "* && " $rest " != *" -B "* ]] || deny "retargeting a PR's base branch"
      ;;
    "pr merge")
      [[ " $rest " == *" --auto "* ]] || deny "merging without --auto (merges wait for the human's merge-approval)"
      [[ " $rest " != *" --admin "* ]] || deny "admin merge bypasses protection"
      ;;
    "issue view" | "issue list" | "issue comment" | "issue create" | "issue edit" | "issue status") ;;
    "run view" | "run list" | "run watch" | "run download") ;;
    "repo view" | "repo clone" | "release view" | "release list" | "workflow view" | "workflow list") ;;
    "label list" | "search "* | "status "* | "browse "*) ;;
    "auth status")
      [[ " $rest " != *" -t "* && " $rest " != *"--show-token"* ]] || deny "printing the GitHub token"
      ;;
    "api "*)
      api_args="$action $rest"
      [[ $action != graphql ]] || deny "gh api graphql (may mutate: reviews, merges, protections)"
      if grep -Eiq -- '(^|[[:space:]])(-X|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)' <<<"$api_args"; then
        deny "gh api write call"
      fi
      if grep -Eiq -- 'pending_deployments|/reviews|rulesets|/protection|/environments|/hooks|/keys|/collaborators|/secrets|/variables|/actions/permissions' <<<"$api_args"; then
        deny "gh api on protected repository resources"
      fi
      ;;
    *) deny "gh $group $action is not on the allow-list" ;;
  esac
done < <(grep -oE '(^|[/;&|(`"'"'"'[:space:]])gh[[:space:]]+[a-z-]+([[:space:]]+[^;&|`"'"'"']*)?' <<<"$cmd" | sed -E 's/^[/;&|(`"'"'"'[:space:]]+//; s/^.*\/gh /gh /')

exit 0
