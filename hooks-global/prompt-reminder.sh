#!/usr/bin/env bash
# Global Claude Code UserPromptSubmit hook: adds a one-line reminder to every prompt.
# The enforcement lives in bash-guard.sh; this keeps the rule in the agent's working context.
set -euo pipefail
cat >/dev/null
printf '%s\n' "Reminder: you act with the owner's GitHub identity. Never approve PRs or deployments, merge without --auto, change repository settings/rulesets/workflows/secrets, read credentials, or push to the default branch; ask the owner instead."
