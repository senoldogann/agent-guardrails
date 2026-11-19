#!/usr/bin/env bash
# Offline end-to-end tests for `guardrails on <owner/repo>`: a fake gh answers from fixtures and logs every write,
# git clones the project from a local bare repository (url.insteadOf), and tests/pty-run.py types the owner's
# confirmation in a pseudo-terminal. A repository in review mode must not drop to status mode on a Mac that cannot
# apply review mode (no agent App registered or installed there) unless the owner asks for it with --status-mode,
# which the plan and the confirmation name.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
kit=$here
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf '  FAIL %s\n' "$1"
  sed 's/^/       /' "$work/out"
}
expect_out() {
  if grep -F -- "$2" "$work/out" >/dev/null; then ok; else fail "$1 (output lacks: $2)"; fi
}
expect_eq() {
  if [[ $2 == "$3" ]]; then ok; else fail "$1: want [$3] got [$2]"; fi
}

echo "turn on"
# A kit install exactly at its origin's main, built from this checkout's files (tracked and new ones), so the
# command's own reviewed-install check passes.
git init -q -b main "$work/src"
git -C "$here" ls-files -z -c -o --exclude-standard | (cd "$here" && tar --null -T - -cf -) | tar -x -C "$work/src"
git -C "$work/src" add -A
git -C "$work/src" -c user.name=t -c user.email=t@example.invalid commit -q -m kit
git clone -q --bare "$work/src" "$work/origin.git"
git clone -q "$work/origin.git" "$work/install"

# The project's default branch carries exactly this kit. Clones of https://github.com/acme/shop.git read it.
template="$work/install/skills/guardrails-init/template"
project="$work/project"
mkdir -p "$project/.github/workflows" "$project/.claude" "$project/.cursor"
cp -R "$template/.agent" "$project/.agent"
cp "$template/.claude/settings.json" "$project/.claude/settings.json"
cp "$template/.cursor/hooks.json" "$project/.cursor/hooks.json"
cp "$template/.github/workflows/agent-guard.yml" "$template/.github/workflows/security.yml" \
  "$template/.github/workflows/agent-notify.yml" "$template/ci/checks-node.yml" "$project/.github/workflows/"
git -C "$project" init -q -b main
git -C "$project" add -A
git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -q -m project
mkdir -p "$work/remote/acme"
git clone -q --bare "$project" "$work/remote/acme/shop.git"

fake="$work/fake"
mkdir -p "$fake/bin"
source "$here/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$here/bin/guardrails-lib.sh"
cat >"$fake/bin/gh" <<FAKE
#!/usr/bin/env bash
args="\$*"
fake="$fake"
FAKE
cat >>"$fake/bin/gh" <<'FAKE'
printf '%s\n' "$args" >>"$fake/calls.log"
case $args in
  "repo view acme/shop --json defaultBranchRef --jq .defaultBranchRef.name") echo main ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails")'*) echo 7 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-review")'*)
    [[ ! -f $fake/review.json ]] || echo 8
    ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-tags")'*) echo 9 ;;
  "api repos/acme/shop/rulesets/7") cat "$fake/branch.json" ;;
  "api repos/acme/shop/rulesets/8") cat "$fake/review.json" ;;
  "api repos/acme/shop/rulesets/9") cat "$fake/tag.json" ;;
  "api -X "* | "label create "* | "repo edit "*) printf '%s\n' "$args" >>"$fake/writes.log" ;;
  *)
    printf 'fake gh: unexpected call: %s\n' "$args" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$fake/bin/gh"
tag_ruleset agent-guardrails-tags | jq -c '. + {id: 9}' >"$fake/tag.json"
# No agent App is registered in this HOME, so this Mac cannot apply review mode.
fake_home="$work/home"
mkdir -p "$fake_home/.config/agent-guardrails"

# Runs `guardrails on` with the given arguments, typing "acme/shop" at its prompt; prints its exit status. Output
# in $work/out, plan and confirmation events in $work/events, writes in $fake/writes.log.
turn_on() {
  local status=0
  rm -f "$fake/writes.log" "$fake/calls.log" "$work/events"
  touch "$fake/writes.log" "$work/events"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR HOME="$fake_home" PATH="$fake/bin:$PATH" GUARDRAILS_EVENTS_FD=3 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/remote/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ \
    python3 -I "$here/tests/pty-run.py" acme/shop -- "$work/install/bin/guardrails" on "$@" \
    >"$work/out" 2>&1 3>"$work/events" || status=$?
  printf '%s\n' "$status"
}
plan_count() { jq -s -c 'map(select(.event == "plan")) | length' "$work/events"; }

# acme/shop is in review mode: the branch ruleset without merge-approval and the review ruleset.
branch_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$fake/branch.json"
review_ruleset agent-guardrails-review | jq -c '. + {id: 8}' >"$fake/review.json"
expect_eq "a plain on refuses to leave review mode" "$(turn_on acme/shop)" 1
expect_out "the refusal says why" "acme/shop is in review mode, but no agent App is registered on this Mac"
expect_out "and what to do" "Run guardrails on acme/shop from the Mac that holds the agent App, or register one here"
expect_out "and how to leave review mode on purpose" "guardrails on acme/shop --status-mode"
expect_eq "no plan before the refusal" "$(plan_count)" 0
expect_eq "nothing is written" "$(cat "$fake/writes.log")" ""

expect_eq "--status-mode leaves review mode" "$(turn_on acme/shop --status-mode)" 0
expect_eq "the plan says so" "$(jq -r -s '.[] | select(.event == "plan") | "\(.mode) \(.leavesReviewMode)"' "$work/events")" \
  "status true"
expect_out "the confirmation names it" "--status-mode: this switches acme/shop from review mode to status mode"
expect_eq "it deletes the review ruleset" "$(grep -c '^api -X DELETE repos/acme/shop/rulesets/8$' "$fake/writes.log")" 1

# A review-mode repository whose review ruleset was deleted still counts as review mode: its branch ruleset does
# not require merge-approval.
rm "$fake/review.json"
expect_eq "a lost review ruleset is no way around the refusal" "$(turn_on acme/shop)" 1
expect_eq "and nothing is written then either" "$(cat "$fake/writes.log")" ""

# A branch ruleset the mode check cannot evaluate stops `on`; it must not read as status mode.
jq -c '.rules += [{type: "required_status_checks", parameters: {required_status_checks: ["merge-approval"]}}]' \
  "$fake/branch.json" >"$fake/branch.odd.json"
mv "$fake/branch.odd.json" "$fake/branch.json"
expect_eq "an unreadable ruleset stops on" "$(turn_on acme/shop)" 1
expect_out "that refusal says why" "cannot tell whether the live rulesets of acme/shop are in review mode"
expect_eq "and nothing is written" "$(cat "$fake/writes.log")" ""

# acme/shop is in status mode: on applies status mode again without asking for the flag.
status_mode_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$fake/branch.json"
expect_eq "a status-mode repository turns on as before" "$(turn_on acme/shop)" 0
expect_eq "its plan does not leave review mode" \
  "$(jq -r -s '.[] | select(.event == "plan") | "\(.mode) \(.leavesReviewMode)"' "$work/events")" "status false"

printf '%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
