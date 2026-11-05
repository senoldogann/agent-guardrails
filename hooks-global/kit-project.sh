# shellcheck shell=bash
# Shared by the global hooks. Source it; do not execute it.

# Succeeds when the directory belongs to a git repository that uses the agent-guardrails kit
# (its root has .agent/bin/ci-guard). Outside such repositories the global hooks stay out of the way.
is_kit_project() {
  local dir=$1 root
  [[ -n $dir && -d $dir ]] || return 1
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -x "$root/.agent/bin/ci-guard" ]]
}
