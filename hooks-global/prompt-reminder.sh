#!/usr/bin/env bash
# Global UserPromptSubmit hook for Claude Code and Codex: adds a one-line reminder to every prompt in kit
# repositories (see is_kit_project in kit-project.sh); silent everywhere else.
# The enforcement lives in bash-guard.sh and on GitHub; this keeps the rule in the agent's working context.
set -euo pipefail
# shellcheck source=kit-project.sh
source "$(dirname "$(realpath "$0")")/kit-project.sh"
input=$(cat)
is_kit_project "$(jq -r '.cwd // empty' <<<"$input")" || exit 0
printf '%s\n' "Reminder: the owner's approval decides what merges here. Whichever GitHub identity you work with (the owner's login or the agent App), never approve PRs or deployments, admin-merge, change repository settings/rulesets/workflows/secrets, read credentials, or push to the default branch; ask the owner instead."
