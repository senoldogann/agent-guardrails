#!/usr/bin/env bash
# Tests for bin/pr-target.sh: PR links resolve to "<owner/repo> <number>" from any directory.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$kit/bin/pr-target.sh"

failed=0
expect() {
  local input=$1 want=$2 got
  got=$(pr_target "$input")
  if [[ $got == "$want" ]]; then
    printf '  ok   %s\n' "$input"
  else
    printf '  FAIL %s -> %s (want %s)\n' "$input" "$got" "$want"
    failed=$((failed + 1))
  fi
}
expect_rejected() {
  if (pr_target "$1") >/dev/null 2>&1; then
    printf '  FAIL %s was accepted\n' "$1"
    failed=$((failed + 1))
  else
    printf '  ok   rejected %s\n' "$1"
  fi
}

echo "pr-target"
expect https://github.com/acme/shop/pull/12 "acme/shop 12"
expect https://github.com/acme/shop/pull/12/files "acme/shop 12"
expect_rejected https://github.com/acme/shop/issues/12
expect_rejected 'not-a-pr'
[[ $failed -eq 0 ]]
