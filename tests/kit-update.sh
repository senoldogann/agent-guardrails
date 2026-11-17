#!/usr/bin/env bash
# Offline tests for kit_update (`guardrails update`) against a local clone of this repository as the origin: it
# refuses local changes, another branch and a diverged main; it announces its plan and changes nothing without
# the confirmation; with it, it fast-forwards and reinstalls into a throwaway HOME.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf '  FAIL %s\n' "$1"
}
expect_eq() {
  if [[ $2 == "$3" ]]; then ok; else fail "$1: want [$3] got [$2]"; fi
}
# Runs kit_update in a subshell; prints its exit status, then its output.
run_update() {
  local out status
  out=$( (kit_update) 2>&1 3>"$work/events") && status=0 || status=$?
  printf '%s\n%s\n' "$status" "$out"
}

echo "kit-update"
# A two-commit history built from this checkout's HEAD (CI checkouts are shallow and have no main): the install
# sits at the first commit, the origin's main at the second, which raises VERSION.
git init -q -b main "$work/src"
git -C "$here" archive HEAD | tar -x -C "$work/src"
commit() { git -C "$work/src" -c user.name=t -c user.email=t@example.invalid commit -q -m "$1"; }
git -C "$work/src" add -A
commit "base"
printf '9.9.9\n' >"$work/src/VERSION"
git -C "$work/src" add VERSION
commit "chore: release 9.9.9"
git clone -q --bare "$work/src" "$work/origin.git"
git clone -q "$work/origin.git" "$work/install"
git -C "$work/install" reset -q --hard HEAD~1
target=$(git -C "$work/origin.git" rev-parse main)
kit="$work/install"
source "$here/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$here/bin/guardrails-lib.sh"
export GUARDRAILS_EVENTS_FD=3
# No terminal here: the owner's typed confirmation is replaced per case.
refuse() { die "confirmation did not match; nothing changed"; }
accept() { :; }

confirm() { refuse; }
before=$(git -C "$kit" rev-parse HEAD)
result=$(run_update)
expect_eq "without the confirmation it stops" "$(head -1 <<<"$result")" 1
expect_eq "and changes nothing" "$(git -C "$kit" rev-parse HEAD)" "$before"
expect_eq "the plan names the exact target and its version" \
  "$(jq -r 'select(.action == "update") | "\(.to) \(.toVersion) \(.commits | length)"' "$work/events")" "$target 9.9.9 1"
if grep -F "Update the kit install at $kit" <<<"$result" >/dev/null; then ok; else fail "the plan is printed"; fi

printf 'x\n' >"$kit/stray"
expect_eq "local changes are refused" "$(run_update | tail -1)" \
  "error: the kit install at $kit has local changes, so it cannot be fast-forwarded. Inspect them with: git -C $kit status"
rm "$kit/stray"

git -C "$kit" switch -q -c elsewhere
expect_eq "another branch is refused" "$(run_update | tail -1)" \
  "error: the kit install at $kit is not on main. Switch it with: git -C $kit switch main"
git -C "$kit" switch -q main

git -C "$kit" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "local only"
expect_eq "a diverged main is refused" "$(run_update | tail -1)" \
  "error: main of the kit origin does not contain the installed commit $(git -C "$kit" rev-parse --short=7 HEAD); inspect it before updating"
git -C "$kit" reset -q --hard "$before"

confirm() { accept; }
home="$work/home"
mkdir -p "$home/.local/bin"
result=$(HOME="$home" PATH="$home/.local/bin:$PATH" run_update)
expect_eq "with the confirmation it updates" "$(head -1 <<<"$result")" 0
expect_eq "to exactly the target" "$(git -C "$kit" rev-parse HEAD)" "$target"
expect_eq "and reinstalls the commands" "$(readlink "$home/.local/bin/guardrails")" "$kit/bin/guardrails"
expect_eq "a second run finds nothing to do" "$(run_update | tail -1)" "the kit install is up to date (${target:0:7})"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
