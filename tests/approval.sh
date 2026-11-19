#!/usr/bin/env bash
# Offline end-to-end tests for bin/approve-head: a fake gh answers from fixtures and logs every write, and
# tests/pty-run.py types the owner's confirmations in a pseudo-terminal. The approval must show the files of exactly
# the head and base it read (a push during the review cannot swap them), mark a changed or renamed workflow "!!"
# and ask for its second confirmation, show a re-lock's change of scope and ask to confirm each dropped file, refuse
# a file list that may be incomplete, and write nothing when the PR moved before the write. In review mode it must
# merge through the admin bypass, pinned to the head, when the owner pushed the head, since GitHub would not count
# the owner's review then.
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

echo "approval"
# A kit install exactly at its origin's main, built from this checkout's files (tracked and new ones), so the
# approval's own reviewed-install check passes.
git init -q -b main "$work/src"
git -C "$here" ls-files -z -c -o --exclude-standard | (cd "$here" && tar --null -T - -cf -) | tar -x -C "$work/src"
git -C "$work/src" add -A
git -C "$work/src" -c user.name=t -c user.email=t@example.invalid commit -q -m kit
git clone -q --bare "$work/src" "$work/origin.git"
git clone -q "$work/origin.git" "$work/install"

base=1111111111111111111111111111111111111111
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
moved=cccccccccccccccccccccccccccccccccccccccc
fake="$work/fake"
mkdir -p "$fake/bin"
# The PR as GET pulls/7 returns it. Arguments: head commit, changed_files.
pr_json() {
  jq -n -c --arg head "$1" --arg base "$base" --argjson changed "$2" \
    '{number: 7, state: "open", draft: false, title: "feat(A-1): x", html_url: "https://github.com/acme/shop/pull/7",
      node_id: "PR_7", user: {login: "agent[bot]"}, head: {sha: $head, ref: "feat/A-1-x", repo: {full_name: "Acme/Shop"}},
      base: {sha: $base, ref: "main", repo: {full_name: "Acme/Shop"}}, changed_files: $changed}'
}
source "$here/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$here/bin/guardrails-lib.sh"
status_mode_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$fake/branch.json"
printf 'on: pull_request\npermissions:\n  contents: read\njobs: {}\n' | base64 | tr -d '\n' >"$fake/workflow.b64"
jq -n -c --arg head "$head" '{workflow_runs: [{path: ".github/workflows/agent-guard.yml", created_at: "2026-01-01T00:00:00Z",
  conclusion: "success", head_sha: $head, pull_requests: [{number: 7, base: {ref: "main"}}]}]}' >"$fake/runs.json"

# Answers only for the head and base of the PR's first read: a call for any other commit is unexpected and fails.
# Read N of the PR returns pr.N.json, or the last one there is.
cat >"$fake/bin/gh" <<FAKE
#!/usr/bin/env bash
args="\$*"
fake="$fake"
head="$head"
base="$base"
FAKE
cat >>"$fake/bin/gh" <<'FAKE'
printf '%s\n' "$args" >>"$fake/calls.log"
case $args in
  "repo view acme/shop --json defaultBranchRef --jq .defaultBranchRef.name") echo main ;;
  "api repos/acme/shop/pulls/7")
    n=$(($(cat "$fake/reads" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$fake/reads"
    while [[ ! -f $fake/pr.$n.json ]]; do n=$((n - 1)); done
    cat "$fake/pr.$n.json"
    ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails")'*) echo 7 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-review")'*)
    [[ ! -f $fake/review.json ]] || echo 8
    ;;
  "api repos/acme/shop/rulesets/7") cat "$fake/branch.json" ;;
  "api repos/acme/shop/rulesets/8") cat "$fake/review.json" ;;
  "api user --jq .login") echo owner ;;
  "api repos/acme/shop/contents/specs/A-1/spec.lock?ref=$base") cat "$fake/lock.base.json" ;;
  "api repos/acme/shop/contents/specs/A-1/spec.lock?ref=$head") cat "$fake/lock.head.json" ;;
  "api repos/acme/shop/activity?ref=refs%2Fheads%2Ffeat%2FA-1-x&per_page=1") cat "$fake/activity.json" ;;
  "api repos/acme/shop/pulls/7 --jq .head.sha") echo "$head" ;;
  "api -X POST repos/acme/shop/pulls/7/reviews "*)
    printf '%s\n' "$args" >>"$fake/writes.log"
    echo 99
    ;;
  "pr merge 7 -R acme/shop "*) printf '%s\n' "$args" >>"$fake/writes.log" ;;
  "api repos/acme/shop/actions/runs?head_sha=$head&event=pull_request_target&per_page=100") cat "$fake/runs.json" ;;
  "api repos/acme/shop/contents/.github/workflows?ref=$head --jq "*) echo .github/workflows/ci.yml ;;
  "api repos/acme/shop/contents/.github/workflows/ci.yml?ref=$head --jq .content") cat "$fake/workflow.b64" ;;
  "api repos/acme/shop/compare/$base...$head?per_page=1") cat "$fake/compare.json" ;;
  "api -X POST repos/acme/shop/statuses/"*)
    printf '%s\n' "$args" >>"$fake/writes.log"
    echo '{}'
    ;;
  *)
    printf 'fake gh: unexpected call: %s\n' "$args" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$fake/bin/gh"

# Runs the approval of PR 7 with the answers typed at its prompts; prints its exit status. Fixtures: pr.N.json,
# compare.json. Output in $work/out, plan and confirmation events in $work/events, writes in $fake/writes.log.
approve() {
  local status=0
  rm -f "$fake/reads" "$fake/writes.log" "$fake/calls.log" "$work/events"
  touch "$fake/writes.log" "$work/events"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR PATH="$fake/bin:$PATH" GUARDRAILS_EVENTS_FD=3 \
    python3 -I "$here/tests/pty-run.py" "$@" -- "$work/install/bin/approve-head" https://github.com/acme/shop/pull/7 \
    >"$work/out" 2>&1 3>"$work/events" || status=$?
  printf '%s\n' "$status"
}
compare() { jq -n -c --argjson files "$1" '{status: "ahead", files: $files}' >"$fake/compare.json"; }
plan_files() { jq -r -s '.[] | select(.event == "plan") | .files[] | "\(.marker) \(.path)"' "$work/events"; }

rm -f "$fake"/pr.*.json
pr_json "$head" 2 >"$fake/pr.1.json"
compare '[{"filename": "src/a.ts", "status": "modified"}, {"filename": "tests/a.test.ts", "status": "added"}]'
expect_eq "the stable path approves" "$(approve aaaaaaa)" 0
expect_eq "it posts exactly one status, on the approved head" "$(cat "$fake/writes.log")" \
  "api -X POST repos/acme/shop/statuses/$head -f state=success -f context=merge-approval -f description=Approved by owner for PR #7"
expect_eq "the plan names the base and head it showed" \
  "$(jq -r -s '.[] | select(.event == "plan") | "\(.base) \(.sha)"' "$work/events")" "$base $head"
expect_eq "the plan lists the compared files" "$(plan_files)" " src/a.ts
! tests/a.test.ts"
expect_out "the screen shows the base" "base: $base"
expect_eq "nothing is read by PR number but the PR itself" "$(grep -c 'pulls/7/' "$fake/calls.log" || true)" 0

pr_json "$moved" 2 >"$fake/pr.2.json"
expect_eq "a push during the review stops the approval" "$(approve aaaaaaa)" 1
expect_out "the refusal says what moved" "PR #7 changed while you reviewed it (now head ccccccc, base 1111111); nothing approved."
expect_eq "a moved PR gets no write" "$(cat "$fake/writes.log")" ""
expect_eq "the files shown were the approved head's, not the moved one's" "$(plan_files)" " src/a.ts
! tests/a.test.ts"
rm -f "$fake/pr.2.json"

compare '[{"filename": ".github/workflows/ci.yml", "status": "modified"}, {"filename": "src/a.ts", "status": "modified"}]'
expect_eq "a changed workflow needs its own confirmation" "$(approve aaaaaaa no)" 1
expect_eq "the workflow is marked !!" "$(plan_files)" "!! .github/workflows/ci.yml
 src/a.ts"
expect_eq "the second confirmation is asked" "$(jq -r -s '[.[] | select(.event == "confirm") | .step] | join(" ")' "$work/events")" \
  "commit workflows"
expect_eq "a refused second confirmation writes nothing" "$(cat "$fake/writes.log")" ""
expect_eq "with both confirmations it approves" "$(approve aaaaaaa workflows)" 0
expect_eq "and writes once" "$(grep -c "statuses/$head" "$fake/writes.log")" 1

compare '[{"filename": "docs/ci.yml", "previous_filename": ".github/workflows/ci.yml", "status": "renamed"},
  {"filename": "src/a.ts", "status": "modified"}]'
expect_eq "a workflow renamed away needs its own confirmation" "$(approve aaaaaaa no)" 1
expect_eq "its old path is marked !!" "$(plan_files)" "!! .github/workflows/ci.yml
 docs/ci.yml
 src/a.ts"

pr_json "$head" 350 >"$fake/pr.1.json"
compare "$(jq -n -c '[range(300) | {filename: "src/f\(.).ts", status: "added"}]')"
expect_eq "a comparison at GitHub's limit is refused" "$(approve aaaaaaa)" 1
expect_out "the refusal says why" "GitHub lists at most 300 files of a comparison and returned 300 (the PR reports 350)"
expect_eq "no plan before a complete list" "$(jq -s -c 'map(select(.event == "plan")) | length' "$work/events")" 0
expect_eq "an incomplete list gets no write" "$(cat "$fake/writes.log")" ""

pr_json "$head" 3 >"$fake/pr.1.json"
compare '[{"filename": "src/a.ts", "status": "modified"}]'
expect_eq "a list shorter than the PR's count is refused" "$(approve aaaaaaa)" 1
expect_out "that refusal names both counts" "the comparison lists 1 files, but the PR reports 3 changed files for the same head"

# A re-lock that changes which files a spec lock covers: both versions are read by commit, the change is in the
# plan, and a file the lock stops covering needs its own confirmation.
lock_json() { printf '%s' "$1" | base64 | tr -d '\n' | jq -R -c '{type: "file", encoding: "base64", content: .}'; }
sum() { printf '%064d  %s\n' 0 "$1"; }
lock_json "$(sum specs/A-1/locked-files; sum tests/a.test.ts; sum tests/keep.test.ts)" >"$fake/lock.base.json"
lock_json "$(sum specs/A-1/locked-files; sum tests/keep.test.ts; sum tests/b.test.ts)" >"$fake/lock.head.json"
pr_json "$head" 3 >"$fake/pr.1.json"
compare '[{"filename": "specs/A-1/locked-files", "status": "modified"}, {"filename": "specs/A-1/spec.lock", "status": "modified"},
  {"filename": "tests/b.test.ts", "status": "added"}]'
lock_scope() { jq -r -s '.[] | select(.event == "plan") | .lockScope[] | "\(.change) \(.lock) \(.path)"' "$work/events"; }
expect_eq "a dropped locked file needs its own confirmation" "$(approve aaaaaaa no)" 1
expect_eq "the plan lists the change of scope" "$(lock_scope)" "dropped specs/A-1/spec.lock tests/a.test.ts
added specs/A-1/spec.lock tests/b.test.ts"
expect_out "the screen names the dropped file" '!! specs/A-1/spec.lock no longer locks "tests/a.test.ts"'
expect_out "and the added one" '   specs/A-1/spec.lock now also locks "tests/b.test.ts"'
expect_eq "the unlock confirmation is asked" "$(jq -r -s '[.[] | select(.event == "confirm") | .step] | join(" ")' "$work/events")" \
  "commit unlock"
expect_eq "a refused unlock confirmation writes nothing" "$(cat "$fake/writes.log")" ""
expect_eq "with both confirmations it approves" "$(approve aaaaaaa unlock)" 0
expect_eq "and writes once, on the head" "$(grep -c "statuses/$head" "$fake/writes.log")" 1

lock_json "$(sum specs/A-1/locked-files; sum tests/a.test.ts; sum tests/keep.test.ts; sum tests/b.test.ts)" >"$fake/lock.head.json"
expect_eq "a lock that only adds files needs no unlock confirmation" "$(approve aaaaaaa)" 0
expect_eq "its plan still lists the added file" "$(lock_scope)" "added specs/A-1/spec.lock tests/b.test.ts"

compare '[{"filename": "specs/A-1/spec.lock", "status": "removed"}, {"filename": "src/a.ts", "status": "modified"},
  {"filename": "tests/b.test.ts", "status": "added"}]'
expect_eq "a removed lock is refused" "$(approve aaaaaaa)" 1
expect_out "that refusal says why" "PR #7 deletes the spec lock specs/A-1/spec.lock"
expect_eq "a removed lock gets no write" "$(cat "$fake/writes.log")" ""

# Review mode, where the review ruleset requires approval from someone other than the last pusher: who pushed the
# head comes from GitHub's push log of the PR's branch.
branch_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$fake/branch.json"
review_ruleset agent-guardrails-review | jq -c '. + {id: 8}' >"$fake/review.json"
pr_json "$head" 1 >"$fake/pr.1.json"
compare '[{"filename": "src/a.ts", "status": "modified"}]'
activity() {
  jq -n -c --arg after "$1" --arg actor "$2" '[{ref: "refs/heads/feat/A-1-x", before: "2222222222222222222222222222222222222222",
    after: $after, activity_type: "push", timestamp: "2026-01-01T00:00:00Z", actor: {login: $actor, type: "User"}}]' >"$fake/activity.json"
}
activity "$head" "agent[bot]"
expect_eq "an agent push is approved with a review" "$(approve aaaaaaa)" 0
expect_eq "the review names the approved head" "$(cut -d' ' -f1-6 "$fake/writes.log")" \
  "api -X POST repos/acme/shop/pulls/7/reviews -f commit_id=$head"

activity "$head" owner
expect_eq "the owner's own push of an agent PR merges through the bypass" "$(approve aaaaaaa)" 0
expect_out "the prompt names the push" "Your account owner made the newest push to this PR (aaaaaaa, 2026-01-01T00:00:00Z)"
expect_out "and what merges" "This merges all of agent[bot]'s PR"
expect_eq "the plan says it merges because of the owner's push" \
  "$(jq -r -s '.[] | select(.event == "plan") | "\(.merge) \(.ownPush) \(.pushedBy) \(.pushedAt) \(.author)"' "$work/events")" \
  "true true owner 2026-01-01T00:00:00Z agent[bot]"
expect_eq "the merge is pinned to the approved head and no review is posted" "$(cat "$fake/writes.log")" \
  "pr merge 7 -R acme/shop --squash --admin --delete-branch --match-head-commit $head"

activity "$moved" "agent[bot]"
expect_eq "a push log that does not end at the head is refused" "$(approve aaaaaaa)" 1
expect_out "that refusal says why" "cannot tell who pushed aaaaaaa to feat/A-1-x of acme/shop: the newest push left the branch at ccccccc"
expect_eq "an unknown pusher gets no write" "$(cat "$fake/writes.log")" ""

printf '%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
