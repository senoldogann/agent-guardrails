#!/usr/bin/env bash
# Offline end-to-end tests for `guardrails on <owner/repo>`: a fake gh answers from fixtures, keeps every ruleset
# write in them and logs the writes in order, git clones the project from a local bare repository (url.insteadOf),
# and tests/pty-run.py types the owner's confirmation in a pseudo-terminal. A repository in review mode must not drop
# to status mode on a Mac that cannot apply review mode (no agent App registered or installed there) unless the owner
# asks for it with --status-mode, which the plan and the confirmation name. A switch between the modes keeps an
# approval rule at every step: when GitHub refuses one ruleset write, the rulesets left behind still require the
# owner's approval, and the command says what is on and how to finish.
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

# The project's default branch carries exactly this kit, and CODEOWNERS gives every path to the owner (review mode
# needs it). Clones of https://github.com/acme/shop.git read it.
template="$work/install/skills/guardrails-init/template"
project="$work/project"
mkdir -p "$project/.github/workflows" "$project/.claude" "$project/.cursor"
cp -R "$template/.agent" "$project/.agent"
cp "$template/.claude/settings.json" "$project/.claude/settings.json"
cp "$template/.cursor/hooks.json" "$project/.cursor/hooks.json"
cp "$template/.github/workflows/agent-guard.yml" "$template/.github/workflows/security.yml" \
  "$template/.github/workflows/agent-notify.yml" "$template/ci/checks-node.yml" "$project/.github/workflows/"
printf '* @acme-owner\n' >"$project/.github/CODEOWNERS"
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
  "api user --jq .login") echo acme-owner ;;
  "api repos/acme/shop --jq .owner.type") echo Organization ;;
  "api repos/acme/shop/codeowners/errors --jq "*) ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails")'*)
    [[ ! -f $fake/branch.json ]] || echo 7
    ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-review")'*)
    [[ ! -f $fake/review.json ]] || echo 8
    ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-tags")'*)
    [[ ! -f $fake/tag.json ]] || echo 9
    ;;
  "api repos/acme/shop/rulesets/7") cat "$fake/branch.json" ;;
  "api repos/acme/shop/rulesets/8") cat "$fake/review.json" ;;
  "api repos/acme/shop/rulesets/9") cat "$fake/tag.json" ;;
  # A ruleset write is logged in order as "<method> <name>", refused when $fake/refuse names it, and kept otherwise:
  # the fixtures are then what GitHub would hold.
  "api -X POST repos/acme/shop/rulesets --input -" | "api -X PUT repos/acme/shop/rulesets/"[789]" --input -" | \
    "api -X DELETE repos/acme/shop/rulesets/"[789])
    printf '%s\n' "$args" >>"$fake/writes.log"
    method=${args#api -X }
    method=${method%% *}
    body=""
    if [[ $method == DELETE ]]; then
      id=${args##*/}
    else
      body=$(cat)
      case $(jq -r .name <<<"$body") in
        agent-guardrails) id=7 ;;
        agent-guardrails-review) id=8 ;;
        agent-guardrails-tags) id=9 ;;
        *)
          printf 'fake gh: unexpected ruleset: %s\n' "$body" >&2
          exit 1
          ;;
      esac
    fi
    case $id in
      7) slot=branch name=agent-guardrails ;;
      8) slot=review name=agent-guardrails-review ;;
      *) slot=tag name=agent-guardrails-tags ;;
    esac
    printf '%s %s\n' "$method" "$name" >>"$fake/rulesets.log"
    if [[ -f $fake/refuse && $(<"$fake/refuse") == "$method $name" ]]; then
      printf 'gh: Validation Failed (HTTP 422)\n' >&2
      exit 1
    fi
    if [[ $method == DELETE ]]; then
      rm "$fake/$slot.json"
    else
      jq -c --argjson id "$id" '. + {id: $id}' <<<"$body" >"$fake/$slot.json"
    fi
    ;;
  "api -X "* | "label create "* | "repo edit "*) printf '%s\n' "$args" >>"$fake/writes.log" ;;
  *)
    printf 'fake gh: unexpected call: %s\n' "$args" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$fake/bin/gh"
# The agent App's installation on acme/shop, as GitHub reports it to the App: on selected repositories, with the
# agent's permissions only.
cat >"$fake/bin/curl" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == https://api.github.com/repos/acme/shop/installation ]]; then
    printf '%s\n200' '{"id": 42, "repository_selection": "selected", "account": {"login": "acme"},
      "permissions": {"contents": "write", "metadata": "read", "pull_requests": "write"}}'
    exit 0
  fi
done
printf 'fake curl: unexpected call: %s\n' "$*" >&2
exit 1
FAKE
chmod +x "$fake/bin/curl"
tag_ruleset agent-guardrails-tags | jq -c '. + {id: 9}' >"$fake/tag.json"
# No agent App is registered in this HOME, so this Mac cannot apply review mode.
fake_home="$work/home"
mkdir -p "$fake_home/.config/agent-guardrails"
home=$fake_home

# Runs `guardrails on` with the given arguments and HOME=$home, typing "acme/shop" at its prompt; prints its exit
# status. Output in $work/out, plan and confirmation events in $work/events, writes in $fake/writes.log and the
# ruleset writes, in order, in $fake/rulesets.log.
turn_on() {
  local status=0
  rm -f "$fake/writes.log" "$fake/calls.log" "$fake/rulesets.log" "$work/events"
  touch "$fake/writes.log" "$fake/rulesets.log" "$work/events"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR HOME="$home" PATH="$fake/bin:$PATH" GUARDRAILS_EVENTS_FD=3 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/remote/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ \
    python3 -I "$here/tests/pty-run.py" acme/shop -- "$work/install/bin/guardrails" on "$@" \
    >"$work/out" 2>&1 3>"$work/events" || status=$?
  printf '%s\n' "$status"
}
plan_count() { jq -s -c 'map(select(.event == "plan")) | length' "$work/events"; }
# The ruleset writes of the last run, in order, comma-separated.
ruleset_writes() { paste -s -d , "$fake/rulesets.log"; }

# Writes the rulesets of acme/shop in one approval mode and lets GitHub take every write: status (the branch ruleset
# requires merge-approval) or review (the branch ruleset without it, and the review ruleset).
in_mode() {
  rm -f "$fake/review.json" "$fake/refuse"
  case $1 in
    status) status_mode_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$fake/branch.json" ;;
    review)
      branch_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$fake/branch.json"
      review_ruleset agent-guardrails-review | jq -c '. + {id: 8}' >"$fake/review.json"
      ;;
  esac
}

# The approval rules the rulesets of acme/shop hold now: merge-approval (the branch ruleset requires that status)
# and review (the review ruleset is there), or none.
approval_rules() {
  local rules=""
  if [[ -f $fake/branch.json ]] && jq -e 'any(.rules[]; .type == "required_status_checks"
    and any(.parameters.required_status_checks[]; .context == "merge-approval"))' "$fake/branch.json" >/dev/null; then
    rules=merge-approval
  fi
  [[ ! -f $fake/review.json ]] || rules="${rules:+$rules }review"
  printf '%s\n' "${rules:-none}"
}

in_mode review
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
expect_eq "merge-approval goes in before the review ruleset goes" "$(ruleset_writes)" \
  "PUT agent-guardrails,DELETE agent-guardrails-review,PUT agent-guardrails-tags"
expect_eq "it ends in status mode" "$(approval_rules)" merge-approval

# A review-mode repository whose review ruleset was deleted still counts as review mode: its branch ruleset does
# not require merge-approval.
in_mode review
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
in_mode status
expect_eq "a status-mode repository turns on as before" "$(turn_on acme/shop)" 0
expect_eq "its plan does not leave review mode" \
  "$(jq -r -s '.[] | select(.event == "plan") | "\(.mode) \(.leavesReviewMode)"' "$work/events")" "status false"

echo "mode switches keep an approval rule"
# Review mode is ready with this HOME: it holds a registered agent App, which the fake curl reports installed on
# acme/shop, and the project's CODEOWNERS gives every path to the owner.
app_home="$work/app-home"
mkdir -p "$app_home/.config/agent-guardrails/agent"
openssl genrsa -out "$app_home/.config/agent-guardrails/agent/private-key.pem" 2048 2>/dev/null
printf '%s\n' '{"id": 1, "client_id": "Iv1.test", "slug": "agent", "owner": "acme"}' \
  >"$app_home/.config/agent-guardrails/agent/app.json"
home=$app_home

in_mode status
expect_eq "status mode switches to review mode" "$(turn_on acme/shop)" 0
expect_eq "its plan is review mode" "$(jq -r -s '.[] | select(.event == "plan") | .mode' "$work/events")" review
expect_eq "the review ruleset goes in before the branch ruleset drops merge-approval" "$(ruleset_writes)" \
  "POST agent-guardrails-review,PUT agent-guardrails,PUT agent-guardrails-tags"
expect_eq "it ends in review mode" "$(approval_rules)" review

in_mode status
printf 'POST agent-guardrails-review\n' >"$fake/refuse"
expect_eq "a refused review ruleset stops the switch" "$(turn_on acme/shop)" 1
expect_eq "before the branch ruleset is written" "$(ruleset_writes)" "POST agent-guardrails-review"
expect_eq "so merge-approval is still required" "$(approval_rules)" merge-approval
expect_out "the refusal names the ruleset" "GitHub did not take the agent-guardrails-review ruleset of acme/shop"
expect_out "and says nothing changed" \
  "guardrails on stopped before it changed the rulesets of acme/shop; they are as before, apart from a change GitHub may have taken as it stopped. Run again: guardrails on acme/shop"

in_mode status
printf 'PUT agent-guardrails\n' >"$fake/refuse"
expect_eq "a refused branch ruleset stops the switch" "$(turn_on acme/shop)" 1
expect_eq "after the review ruleset went in" "$(ruleset_writes)" "POST agent-guardrails-review,PUT agent-guardrails"
expect_eq "so both approvals are required" "$(approval_rules)" "merge-approval review"
expect_out "the stop says which rules are on" \
  "acme/shop has the agent-guardrails-review ruleset, so every merge needs a code owner's review, and its agent-guardrails ruleset may still require merge-approval as well. Run again: guardrails on acme/shop"

in_mode status
expect_eq "status mode switches to review mode with the merge queue" "$(turn_on acme/shop --merge-queue)" 0
expect_eq "the queue goes in with the branch ruleset, after the review ruleset" "$(ruleset_writes)" \
  "POST agent-guardrails-review,PUT agent-guardrails,PUT agent-guardrails-tags"
expect_eq "the branch ruleset has the queue" "$(jq -r 'any(.rules[]; .type == "merge_queue")' "$fake/branch.json")" true
expect_eq "and review mode" "$(approval_rules)" review

in_mode status
rm -f "$app_home/.config/agent-guardrails/merge-queue"
printf 'PUT agent-guardrails\n' >"$fake/refuse"
expect_eq "a refused merge queue stops the switch" "$(turn_on acme/shop --merge-queue)" 1
expect_eq "after the review ruleset went in" "$(ruleset_writes)" "POST agent-guardrails-review,PUT agent-guardrails"
expect_eq "so both approvals are required then too" "$(approval_rules)" "merge-approval review"
expect_out "the refusal names the queue" "GitHub did not take the agent-guardrails ruleset with the merge queue on acme/shop"
expect_out "the stop offers a retry, or the switch without the queue" \
  "its agent-guardrails ruleset may still require merge-approval as well. Run again: guardrails on acme/shop --merge-queue. If GitHub refuses the merge queue there, turn it on without it: guardrails on acme/shop --no-merge-queue"
expect_eq "the queue is not listed" "$(cat "$app_home/.config/agent-guardrails/merge-queue" 2>/dev/null || true)" ""

# Back to a Mac without the agent App: the owner leaves review mode on purpose.
home=$fake_home
in_mode review
printf 'PUT agent-guardrails\n' >"$fake/refuse"
expect_eq "a refused branch ruleset stops the switch to status mode" "$(turn_on acme/shop --status-mode)" 1
expect_eq "so review mode stays" "$(approval_rules)" review
expect_out "and the stop says nothing changed" \
  "guardrails on stopped before it changed the rulesets of acme/shop; they are as before, apart from a change GitHub may have taken as it stopped. Run again: guardrails on acme/shop --status-mode"

in_mode review
printf 'DELETE agent-guardrails-review\n' >"$fake/refuse"
expect_eq "a refused review ruleset deletion stops the switch to status mode" "$(turn_on acme/shop --status-mode)" 1
expect_eq "after merge-approval went in" "$(ruleset_writes)" "PUT agent-guardrails,DELETE agent-guardrails-review"
expect_eq "so both approvals are required" "$(approval_rules)" "merge-approval review"
expect_out "the stop says so and keeps the flag" \
  "the agent-guardrails ruleset of acme/shop requires merge-approval now, and its agent-guardrails-review ruleset may still be there, so merges may need both your merge-approval and a code owner's review. Run again: guardrails on acme/shop --status-mode"

printf '%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
