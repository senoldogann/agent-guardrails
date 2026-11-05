#!/usr/bin/env bash
# Global Claude Code UserPromptSubmit hook: adds a one-line reminder to every prompt in kit
# repositories (.agent/bin/ci-guard exists); silent everywhere else.
# The enforcement lives in bash-guard.sh; this keeps the rule in the agent's working context.
set -euo pipefail
# shellcheck source=kit-project.sh
source "$(dirname "$(realpath "$0")")/kit-project.sh"
input=$(cat)
is_kit_project "$(jq -r '.cwd // empty' <<<"$input")" || exit 0
printf '%s\n' "Reminder: you act with the owner's GitHub identity. Never approve PRs or deployments, admin-merge, change repository settings/rulesets/workflows/secrets, read credentials, or push to the default branch; ask the owner instead."
