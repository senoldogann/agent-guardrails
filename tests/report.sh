#!/usr/bin/env bash
# Offline tests for `guardrails report`: the pure functions in bin/guardrails-lib.sh over fixture JSON, and the
# command itself against a fake gh that answers from fixtures.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$kit/bin/guardrails-lib.sh"
fixtures="$kit/tests/fixtures"
work=$(mktemp -d)
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

echo "report_since"
expect_eq "30 days before now, in UTC" "$(report_since 1763546400 30)" "2025-10-20T10:00:00Z"

echo "pr_report"
# 11: the agent's PR in status mode, guard failed on the first commit, approved and merged on the second.
# 12: the agent's PR in review mode, approved, a push dismissed it, approved again on the new commit.
# 13: the owner's PR merged without an approval (an admin merge). 14: dependabot, checks timed out, still open.
# 15: merged before the window (left out). 16: open, with more commits than the query reads.
report=$(pr_report 2026-11-01T00:00:00Z guardrails-agent-acme <"$fixtures/report-prs.json")
expect_eq "PRs open in the window" "$(jq .prs <<<"$report")" 5
expect_eq "merged by the agent App and by people; the App's login matches in any case" \
  "$(jq -c .merged <<<"$report")" '{"total":3,"agent":2,"people":1,"otherBots":0}'
expect_eq "no agent App: its bot counts as another bot" \
  "$(pr_report 2026-11-01T00:00:00Z "" <"$fixtures/report-prs.json" | jq -c .merged)" '{"total":3,"agent":0,"people":1,"otherBots":2}'
# 11: ready 09:00, merge-approval 11:00. 12: never a draft, so ready at creation 08:00; the first approval at
# 09:00 counts although a push dismissed it later. 13 has no approval.
expect_eq "time to approve from ready for review (nearest rank)" "$(jq -c .approve <<<"$report")" \
  '{"count":2,"median":3600,"p90":7200}'
expect_eq "time to merge from ready for review" "$(jq -c .merge <<<"$report")" '{"count":3,"median":10800,"p90":21600}'
expect_eq "a dismissed approval followed by a new one is a re-approval" "$(jq .reapproved <<<"$report")" 1
expect_eq "failed guard and checks runs; a cancelled run is no failure, a timed-out one is" \
  "$(jq -c '[.guardFailed, .checksFailed, .failed, .failedThenMerged]' <<<"$report")" '[1,1,2,1]'
expect_eq "a merge without an approval on the final commit, with a clean title" "$(jq -c .adminMerges <<<"$report")" \
  '[{"number":13,"title":"docs: the owner'"'"'s own change?[2J","url":"u13","mergedBy":"owner","mergedAt":"2026-11-04T08:10:00Z"}]'
expect_eq "PRs read only in part are named" "$(jq -c .partial <<<"$report")" '[16]'
expect_eq "nothing in the window" "$(pr_report 2026-11-01T00:00:00Z x <<<'[]' | jq -c '[.prs, .approve, .merge.median, .adminMerges]')" \
  '[0,{"count":0,"median":null,"p90":null},null,[]]'

echo "approval on the final commit"
# One merged PR whose head is "h2": its commits as the query lists them, each with the states of its merge-approval
# statuses, and its reviews. Prints the numbers adminMerges lists for it. Arguments: commits, reviews (JSON).
admin_merges_of() {
  jq -n -c --argjson commits "$1" --argjson reviews "$2" '[{
    number: 30, title: "t", url: "u30", headRefOid: "h2",
    createdAt: "2026-11-02T08:00:00Z", closedAt: "2026-11-02T12:00:00Z", mergedAt: "2026-11-02T12:00:00Z",
    author: {__typename: "Bot", login: "agent"}, mergedBy: {login: "owner"},
    timelineItems: {pageInfo: {hasNextPage: false}, nodes: [$reviews | to_entries[] | {__typename: "PullRequestReview",
      id: "R\(.key)", state: .value.state, submittedAt: "2026-11-02T10:00:00Z", commit: {oid: .value.oid}}]},
    commits: {pageInfo: {hasPreviousPage: false}, nodes: [$commits[] | {commit: {oid: .oid,
      statusCheckRollup: {contexts: {nodes: [.approvals[]? | {__typename: "StatusContext", context: "merge-approval",
        state: ., createdAt: "2026-11-02T11:00:00Z"}]}}}}]}}]' |
    pr_report 2026-11-01T00:00:00Z agent | jq -c '[.adminMerges[].number]'
}
two_commits='[{"oid": "h1"}, {"oid": "h2"}]'
expect_eq "a review approving the final commit" \
  "$(admin_merges_of "$two_commits" '[{"state": "APPROVED", "oid": "h2"}]')" '[]'
expect_eq "a review that still approves only an earlier commit is no approval of the final one" \
  "$(admin_merges_of "$two_commits" '[{"state": "APPROVED", "oid": "h1"}]')" '[30]'
expect_eq "nor is a dismissed review of the final commit" \
  "$(admin_merges_of "$two_commits" '[{"state": "DISMISSED", "oid": "h2"}]')" '[30]'
expect_eq "an earlier approval followed by one of the final commit" \
  "$(admin_merges_of "$two_commits" '[{"state": "APPROVED", "oid": "h1"}, {"state": "APPROVED", "oid": "h2"}]')" '[]'
expect_eq "merge-approval on the final commit" \
  "$(admin_merges_of '[{"oid": "h1"}, {"oid": "h2", "approvals": ["SUCCESS"]}]' '[]')" '[]'
expect_eq "merge-approval only on an earlier commit" \
  "$(admin_merges_of '[{"oid": "h1", "approvals": ["SUCCESS"]}, {"oid": "h2"}]' '[]')" '[30]'
expect_eq "a failed merge-approval on the final commit" \
  "$(admin_merges_of '[{"oid": "h1"}, {"oid": "h2", "approvals": ["FAILURE"]}]' '[]')" '[30]'
# The commit list is in GitHub's order, not the branch's: the head need not come last.
expect_eq "the final commit is the head, wherever the list puts it" \
  "$(admin_merges_of '[{"oid": "h2"}, {"oid": "h1"}]' '[{"state": "APPROVED", "oid": "h2"}]')" '[]'

echo "ruleset history"
history=$(jq -c 'map(del(.state, .login))' "$fixtures/report-ruleset-versions.json")
expect_eq "every version in the window and the one before it" "$(ruleset_versions_needed 2026-11-01T00:00:00Z <<<"$history" | tr '\n' ' ')" "1 2 3 "
expect_eq "timestamps with offsets and fractions compare as instants" \
  "$(ruleset_versions_needed 2026-11-05T10:00:01Z <<<"$history" | tr '\n' ' ')" "2 3 "
expect_eq "pages of history arrive as several arrays" \
  "$(printf '%s\n%s\n' "$(jq -c '.[0:1]' <<<"$history")" "$(jq -c '.[1:]' <<<"$history")" |
    ruleset_versions_needed 2026-12-01T00:00:00Z)" "3"
expect_eq "who changed what, in UTC" "$(ruleset_audit 2026-11-01T00:00:00Z agent-guardrails <"$fixtures/report-ruleset-versions.json")" \
  '{"time":"2026-11-05T10:00:00Z","actor":"owner","ruleset":"agent-guardrails","changes":["enforcement active → disabled","bypass list nobody → RepositoryRole 5 (always)"]}
{"time":"2026-11-06T09:30:00Z","actor":"Integration 99","ruleset":"agent-guardrails","changes":["enforcement disabled → active","bypass list RepositoryRole 5 (always) → nobody","removed rule non_fast_forward","required checks guard, merge-approval → guard"]}'
expect_eq "the oldest version is the creation" \
  "$(jq -c '[.[] | select(.version_id == 1)]' "$fixtures/report-ruleset-versions.json" | ruleset_audit 2026-09-01T00:00:00Z x | jq -r '.changes[]')" \
  "created: branch ruleset, active, rules deletion, non_fast_forward, pull_request, required_status_checks"
expect_eq "a save that changed nothing says so" \
  "$(jq -c '[.[] | select(.version_id == 1)] | [.[0], (.[0] | .version_id = 4 | .updated_at = "2026-11-07T00:00:00Z")]' \
    "$fixtures/report-ruleset-versions.json" | ruleset_audit 2026-11-01T00:00:00Z x | jq -r '.changes[]')" "saved without changes"

echo "report_text"
line=$(jq -c --argjson m "$report" -n '{repo: "acme/shop", days: 30, since: "2026-11-01T00:00:00Z"} + $m + {rulesetChanges: []}')
text=$(report_text <<<"$line")
expect_eq "heading" "$(head -1 <<<"$text")" "acme/shop, last 30 days (since 2026-11-01 00:00 UTC)"
expect_eq "times in hours" "$(grep 'time to approve' <<<"$text")" "  time to approve  median 1 h, 90th percentile 2 h (2 PRs)"
expect_eq "admin merges listed" "$(grep -A1 'admin merges' <<<"$text" | tail -1)" \
  "                   #13 docs: the owner's own change?[2J (merged by owner 2026-11-04 08:10)"

echo "guardrails report"
# A fake gh answers the report's calls for acme/shop from fixtures: PRs updated two days ago, one ruleset.
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case $args in
  "api graphql --paginate "*) cat "$FAKE_SEARCH" ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*) printf '7\tagent-guardrails\n' ;;
  "api --paginate repos/acme/shop/rulesets/7/history?per_page=100") cat "$FAKE_HISTORY" ;;
  "api repos/acme/shop/rulesets/7/history/1") cat "$FAKE_VERSION" ;;
  "api user/1 --jq .login") echo owner ;;
  "api --paginate repos/acme/gone/rulesets"*) echo "HTTP 404: Not Found" >&2; exit 1 ;;
  *) echo "fake gh: unexpected call: $args" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/gh"
recent=$(jq -n -r 'now - 2 * 86400 | floor | todate')
jq -c --arg t "$recent" '{count: 1, nodes: [.[2] | .createdAt = $t | .closedAt = $t | .mergedAt = $t]}' \
  "$fixtures/report-prs.json" >"$work/search.json"
jq -c --arg t "$recent" '[.[2] | {version_id: 1, updated_at: $t, actor}]' "$fixtures/report-ruleset-versions.json" >"$work/history.json"
jq -c --arg t "$recent" '.[2] | del(.login) | .version_id = 1 | .updated_at = $t' "$fixtures/report-ruleset-versions.json" >"$work/version.json"
fake_home="$work/home"
mkdir -p "$fake_home"
run_report() {
  HOME=$fake_home PATH="$fake_bin:$PATH" FAKE_SEARCH=$1 FAKE_HISTORY="$work/history.json" FAKE_VERSION="$work/version.json" \
    "$kit/bin/guardrails" report "${@:2}" 2>&1
}
expect_eq "one JSON line per repository" \
  "$(run_report "$work/search.json" acme/shop --json --days 7 | jq -c '[.repo, .days, .merged.total, (.adminMerges | map(.number)), (.rulesetChanges | map(.actor))]')" \
  '["acme/shop",7,1,[13],["owner"]]'
expect_eq "text for a person" "$(run_report "$work/search.json" --days 7 acme/shop | grep 'ruleset changes')" "  ruleset changes  1"
jq -c '.count = 2' "$work/search.json" >"$work/short.json"
if out=$(run_report "$work/short.json" acme/shop --json); then
  fail "a shorter list than GitHub's count must fail the report: $out"
else
  expect_eq "a partial PR list fails loudly" "$(tail -1 <<<"$out" | sed -E 's/ since [^;]*;/ since <date>;/')" \
    "error: GitHub listed 1 of the 2 pull requests of acme/shop updated since <date>; try again"
fi
if out=$(run_report "$work/search.json" acme/gone --json); then
  fail "unreadable rulesets must fail the report: $out"
else
  expect_eq "unreadable rulesets fail loudly" "$(tail -1 <<<"$out")" "error: cannot list the rulesets of acme/gone"
fi
for bad in "--days 0" "--days 400" "--days x" "acme/shop acme/other" "--weeks 2"; do
  # shellcheck disable=SC2086 # the arguments are split on purpose
  if run_report "$work/search.json" $bad >/dev/null; then fail "bad arguments must be refused: $bad"; else ok; fi
done
expect_eq "no enforced repos and none named" "$(run_report "$work/search.json" | tail -1)" \
  "error: no enforced repos yet; name one: guardrails report <owner/repo>"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
