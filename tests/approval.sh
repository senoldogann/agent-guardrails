#!/usr/bin/env bash
# Offline end-to-end tests for bin/approve-head in status mode: a fake gh answers from fixtures and logs every
# write, and tests/pty-run.py types the owner's confirmations in a pseudo-terminal. The approval must show the
# files of exactly the head and base it read (a push during the review cannot swap them), mark a changed or
# renamed workflow "!!" and ask for its second confirmation, refuse a file list that may be incomplete, and write
# nothing when the PR moved before the write.
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
      node_id: "PR_7", user: {login: "agent[bot]"}, head: {sha: $head, ref: "feat/A-1-x"},
      base: {sha: $base, ref: "main"}, changed_files: $changed}'
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
  "api repos/acme/shop/rulesets/7") cat "$fake/branch.json" ;;
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

printf '%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
