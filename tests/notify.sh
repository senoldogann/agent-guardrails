#!/usr/bin/env bash
# Offline tests for the team notifications: the pure functions in the template's .agent/bin/notify-lib.sh
# (which events count, stale and repeated guard results, messages and payloads built from hostile PR titles)
# and .agent/bin/notify-team end to end against fake gh and curl commands. Posting to a real Slack or Teams
# webhook needs the owner's secret and is not covered here.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
bin="$kit/skills/guardrails-init/template/.agent/bin"
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$kit/skills/guardrails-init/template/.agent/bin/notify-lib.sh"
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
succeeds() {
  local name=$1
  shift
  if ("$@"); then ok; else fail "$name"; fi
}
fails() {
  local name=$1
  shift
  if ("$@") 2>/dev/null; then fail "$name"; else ok; fi
}

repo='{"default_branch": "main"}'
pr_event() { # action, extra fields of the event, fields of the PR
  printf '{"action": "%s", "repository": %s, %s "pull_request": {"number": 7, "state": "open", "head": {"sha": "abc"}, %s}}' \
    "$1" "$repo" "$2" "$3"
}
run_event() { # path, event, conclusion, base branch
  printf '{"repository": %s, "workflow_run": {"id": 50, "path": "%s", "event": "%s", "status": "completed", "conclusion": "%s", "head_sha": "abc", "pull_requests": [{"number": 7, "base": {"ref": "%s"}}]}}' \
    "$repo" "$1" "$2" "$3" "$4"
}
guard=.github/workflows/agent-guard.yml

echo "notify_candidates"
expect_eq "a question" "$(pr_event labeled '"label": {"name": "needs-decision"},' '"merged": false' | notify_candidates pull_request_target)" \
  "answer	abc	7	"
expect_eq "an answered question" "$(pr_event unlabeled '"label": {"name": "needs-decision"},' '"merged": false' | notify_candidates pull_request_target)" \
  "approve	abc	7	"
expect_eq "another label" "$(pr_event labeled '"label": {"name": "bug"},' '"merged": false' | notify_candidates pull_request_target)" ""
expect_eq "a merge" "$(pr_event closed '' '"merged": true' | notify_candidates pull_request_target)" "merged	abc	7	"
expect_eq "closed without merging" "$(pr_event closed '' '"merged": false' | notify_candidates pull_request_target)" ""
expect_eq "guard passed" "$(run_event "$guard" pull_request_target success main | notify_candidates workflow_run)" \
  "approve	abc	7	50"
expect_eq "guard failed" "$(run_event "$guard" pull_request_target failure main | notify_candidates workflow_run)" \
  "blocked	abc	7	50"
expect_eq "guard cancelled" "$(run_event "$guard" pull_request_target cancelled main | notify_candidates workflow_run)" ""
expect_eq "a PR's own workflow named agent-guard" \
  "$(run_event .github/workflows/fake.yml pull_request_target success main | notify_candidates workflow_run)" ""
expect_eq "the guard file run by a push" "$(run_event "$guard" push success main | notify_candidates workflow_run)" ""
expect_eq "a PR into another branch runs that branch's guard" \
  "$(run_event "$guard" pull_request_target success scratch | notify_candidates workflow_run)" ""
expect_eq "a run without a PR (forks)" \
  "$(run_event "$guard" pull_request_target success main | jq -c '.workflow_run.pull_requests = []' | notify_candidates workflow_run)" ""
status_event() { printf '{"repository": %s, "sha": "abc", "context": "%s", "state": "%s"}' "$repo" "$1" "$2"; }
expect_eq "an approval" "$(status_event merge-approval success | notify_candidates status)" "approved	abc		"
expect_eq "another status" "$(status_event ci/deploy success | notify_candidates status)" ""
expect_eq "a pending approval" "$(status_event merge-approval pending | notify_candidates status)" ""
fails "an unknown event is an error" notify_candidates push <<<'{}'

echo "notify_prs_at_head"
expect_eq "open PRs into the default branch at that HEAD" "$(notify_prs_at_head abc main <<<'[
  {"number": 1, "state": "open", "head": {"sha": "abc"}, "base": {"ref": "main"}},
  {"number": 2, "state": "closed", "head": {"sha": "abc"}, "base": {"ref": "main"}},
  {"number": 3, "state": "open", "head": {"sha": "def"}, "base": {"ref": "main"}},
  {"number": 4, "state": "open", "head": {"sha": "abc"}, "base": {"ref": "scratch"}}]')" "1"

echo "notify_still_current"
pr() { # state, draft, head sha, base, labels, merged
  printf '{"number": 7, "title": "feat: add cart", "state": "%s", "draft": %s, "head": {"sha": "%s"}, "base": {"ref": "%s"}, "labels": %s, "merged": %s}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
succeeds "a ready PR at that HEAD waits for approval" notify_still_current approve abc main <<<"$(pr open false abc main '[]' false)"
fails "a push made the guard result stale" notify_still_current approve abc main <<<"$(pr open false def main '[]' false)"
fails "a draft is not announced" notify_still_current blocked abc main <<<"$(pr open true abc main '[]' false)"
fails "a question outranks the guard result" notify_still_current approve abc main \
  <<<"$(pr open false abc main '[{"name": "needs-decision"}]' false)"
fails "a closed PR waits for nothing" notify_still_current approve abc main <<<"$(pr closed false abc main '[]' false)"
succeeds "a question that is still open" notify_still_current answer abc main \
  <<<"$(pr open false abc main '[{"name": "needs-decision"}]' false)"
fails "a question in a PR into another branch" notify_still_current answer abc main \
  <<<"$(pr open false abc scratch '[{"name": "needs-decision"}]' false)"
fails "a question already answered" notify_still_current answer abc main <<<"$(pr open false abc main '[]' false)"
succeeds "an approval of the current HEAD" notify_still_current approved abc main <<<"$(pr open false abc main '[]' false)"
fails "an approval of an older HEAD" notify_still_current approved abc main <<<"$(pr open false def main '[]' false)"
succeeds "a merge into the default branch" notify_still_current merged abc main <<<"$(pr closed false abc main '[]' true)"
fails "a merge into another branch" notify_still_current merged abc main <<<"$(pr closed false abc scratch '[]' true)"

echo "notify_guard_passed"
succeeds "a passed guard" notify_guard_passed <<<'[{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "cancelled"}]'
succeeds "a passed guard while an edit runs it again" notify_guard_passed \
  <<<'[{"status": "completed", "conclusion": "success"}, {"status": "in_progress", "conclusion": null}]'
fails "any failure wins (another branch's guard copy cannot pass for it)" notify_guard_passed \
  <<<'[{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "failure"}]'
fails "a timed-out guard" notify_guard_passed <<<'[{"status": "completed", "conclusion": "timed_out"}]'
fails "no finished guard" notify_guard_passed <<<'[{"status": "queued", "conclusion": null}]'
fails "no guard at all" notify_guard_passed <<<'[]'

echo "notify_guard_seen"
seen_input() { # conclusion of the earlier run, its created_at, issue events
  printf '{"runs": [
    {"id": 40, "path": "%s", "event": "pull_request_target", "status": "completed", "conclusion": "%s", "created_at": "%s", "pull_requests": [{"number": 7}]},
    {"id": 50, "path": "%s", "event": "pull_request_target", "status": "completed", "conclusion": "success", "created_at": "2026-01-03T00:00:00Z", "pull_requests": [{"number": 7}]},
    {"id": 60, "path": "%s", "event": "pull_request_target", "status": "completed", "conclusion": "success", "created_at": "2026-01-04T00:00:00Z", "pull_requests": [{"number": 7}]}],
    "events": %s}' "$guard" "$1" "$2" "$guard" "$guard" "$3"
}
succeeds "an edit re-ran the guard with the same result" notify_guard_seen 50 7 success \
  <<<"$(seen_input success 2026-01-02T00:00:00Z '[]')"
fails "the first result of a HEAD" notify_guard_seen 50 7 success <<<"$(seen_input failure 2026-01-02T00:00:00Z '[]')"
fails "only earlier runs count" notify_guard_seen 40 7 success <<<"$(seen_input success 2026-01-02T00:00:00Z '[]')"
fails "the result again once the draft is ready" notify_guard_seen 50 7 success \
  <<<"$(seen_input success 2026-01-02T00:00:00Z '[{"event": "ready_for_review", "created_at": "2026-01-02T12:00:00Z"}]')"
succeeds "readiness before the earlier run" notify_guard_seen 50 7 success \
  <<<"$(seen_input success 2026-01-02T00:00:00Z '[{"event": "ready_for_review", "created_at": "2026-01-01T00:00:00Z"}, {"event": "labeled", "created_at": "2026-01-02T12:00:00Z"}]')"
fails "the result again after a reopen" notify_guard_seen 50 7 success \
  <<<"$(seen_input success 2026-01-02T00:00:00Z '[{"event": "reopened", "created_at": "2026-01-02T12:00:00Z"}]')"
fails "another PR's run" notify_guard_seen 50 8 success <<<"$(seen_input success 2026-01-02T00:00:00Z '[]')"

echo "notify_message"
message_for() { jq -n -c --arg title "$1" '{number: 12, title: $title}' | notify_message https://github.com acme/shop "$2"; }
expect_eq "a calm line with the PR link" "$(message_for 'feat: add cart' approve)" \
  '{"ref":"acme/shop #12","url":"https://github.com/acme/shop/pull/12","detail":" · feat: add cart — waits for your approval"}'
expect_eq "blocked" "$(message_for 'feat: add cart' blocked | jq -r .detail)" " · feat: add cart — is blocked: guard failed"
expect_eq "a question" "$(message_for 'feat: add cart' answer | jq -r .detail)" " · feat: add cart — the agent asks for a decision"
expect_eq "approved" "$(message_for 'feat: add cart' approved | jq -r .detail)" " · feat: add cart — approved"
expect_eq "merged" "$(message_for 'feat: add cart' merged | jq -r .detail)" " · feat: add cart — merged"
expect_eq "line breaks, tabs and bidi overrides" \
  "$(message_for "$(printf 'fix: a\nb\tc \342\200\256d\342\200\213e\r\nf\342\200\250g')" merged | jq -r .detail)" " · fix: a b c de f g — merged"
expect_eq "a title of nothing visible" "$(message_for "$(printf '\n\342\200\213 \t')" merged | jq -r .detail)" " — merged"
long=$(printf 'x%.0s' $(seq 1 300))
expect_eq "long titles are cut" "$(message_for "$long" merged | jq -r '.detail | length')" "$((3 + 100 + 9))"
fails "an unknown kind" message_for title shipped
fails "a repository that is not owner/repo" notify_message https://github.com 'acme/shop/../x' merged <<<'{"number": 1, "title": "t"}'
fails "a PR number that is not a number" notify_message https://github.com acme/shop merged <<<'{"number": "1/../2", "title": "t"}'
fails "a server URL that is not https" notify_message http://github.com acme/shop merged <<<'{"number": 1, "title": "t"}'

echo "payloads from hostile titles"
# shellcheck disable=SC2016 # the backticks are Slack mrkdwn, not a command substitution
hostile=(
  '<!channel> deploy now'
  '<!here|here> and <!everyone>'
  'ping <@U012AB3CD> and <#C123|general>'
  'see <https://evil.example|github.com/acme/shop/pull/12>'
  'click [Approve](https://evil.example) now'
  '*bold* _italic_ ~strike~ `code` > quote'
  'AT&T &amp; &lt;b&gt;'
  "$(printf 'title\n\n<!channel>\033[31m red \007bell')"
  "$(printf 'right\342\200\256to left <!channel>')"
  '"quotes" and \backslashes\ and {"json": true}'
)
for title in "${hostile[@]}"; do
  message=$(message_for "$title" approve)
  slack=$(notify_slack_payload <<<"$message")
  teams=$(notify_teams_payload <<<"$message")
  label=$(printf '%s' "$title" | LC_ALL=C tr -d '\000-\037' | cut -c1-40)
  # Valid JSON, and no control or invisible formatting character anywhere in either payload.
  for payload in "$slack" "$teams"; do
    succeeds "no control characters [$label]" jq -e '[.. | strings | test("[\\p{Cc}\\p{Cf}]")] | any | not' <<<"$payload" >/dev/null
  done
  # Slack parses the fallback text: no <, > or bare & may survive there.
  succeeds "slack fallback escaped [$label]" jq -e '.text | test("[<>]|&(?!amp;|lt;|gt;)") | not' <<<"$slack" >/dev/null
  # The visible text is a literal rich_text element that holds the cleaned title, and the only link is the PR.
  expect_eq "slack text is literal [$label]" "$(jq -r '.blocks[0].elements[0].elements[1].text' <<<"$slack")" \
    "$(jq -r .detail <<<"$message")"
  expect_eq "slack links only the PR [$label]" "$(jq -c '[.. | .url? // empty]' <<<"$slack")" '["https://github.com/acme/shop/pull/12"]'
  expect_eq "teams links only the PR [$label]" "$(jq -c '[.. | .url? // empty]' <<<"$teams")" '["https://github.com/acme/shop/pull/12"]'
  succeeds "teams has no markdown link [$label]" jq -e '[.. | .text? // empty | strings | contains("](")] | any | not' <<<"$teams" >/dev/null
  expect_eq "slack keeps link previews off [$label]" "$(jq -c '[.unfurl_links, .unfurl_media]' <<<"$slack")" '[false,false]'
done
expect_eq "slack fallback of a broadcast" "$(message_for '<!channel> deploy now' approve | notify_slack_payload | jq -r .text)" \
  'acme/shop #12 · &lt;!channel&gt; deploy now — waits for your approval'
expect_eq "teams card" "$(message_for 'feat: add cart' approve | notify_teams_payload | jq -c '{type, card: .attachments[0].contentType,
  text: .attachments[0].content.body[0].inlines[0].text, action: .attachments[0].content.actions[0].title}')" \
  '{"type":"message","card":"application/vnd.microsoft.card.adaptive","text":"acme/shop #12 · feat: add cart — waits for your approval","action":"Open pull request"}'

echo "notify-team end to end (fake gh and curl)"
fake="$work/fake"
mkdir -p "$fake"
# gh answers the PR, the commit's PRs, the guard runs and the issue events from files; curl records what it
# was asked to post and fails as often as $work/curl-failures says.
cat >"$fake/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case $args in
  *repos/acme/shop/pulls/7*) cat "$FAKE_DIR/pr.json" ;;
  *repos/acme/shop/commits/abc/pulls*) printf '[{"number": 7, "state": "open", "head": {"sha": "abc"}, "base": {"ref": "main"}}]\n' ;;
  *actions/runs*) jq .workflow_runs "$FAKE_DIR/runs.json" ;;
  *commits/abc/check-runs*) cat "$FAKE_DIR/checks.json" ;;
  *issues/7/events*) printf '{"event": "labeled", "created_at": "2026-01-01T00:00:00Z"}\n' ;;
  *) printf 'unexpected gh call: %s\n' "$args" >&2; exit 1 ;;
esac
EOF
cat >"$fake/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/curl-args"
cat >>"$FAKE_DIR/curl-config"
data=""
out=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --data-binary) data=${2#@}; shift ;;
    --output) out=$2; shift ;;
  esac
  shift
done
cat "$data" >>"$FAKE_DIR/posted"
failures=$(cat "$FAKE_DIR/curl-failures")
if [[ $failures -gt 0 ]]; then
  printf '%s\n' $((failures - 1)) >"$FAKE_DIR/curl-failures"
  printf 'invalid_payload' >"$out"
  printf '400'
  exit 22
fi
printf 'ok' >"$out"
printf '200'
EOF
chmod +x "$fake/gh" "$fake/curl"
slack_url='https://hooks.slack.com/services/T000/B000/secretpart'
teams_url='https://prod-00.westus.logic.azure.com/workflows/abc/triggers/manual/paths/invoke?sig=secretsig'
run_notify() { # event name, event JSON; the webhook variables come from the caller's environment
  rm -f "$fake/curl-args" "$fake/curl-config" "$fake/posted"
  printf '%s' "$2" >"$work/event.json"
  FAKE_DIR=$fake PATH="$fake:$PATH" GITHUB_EVENT_NAME=$1 GITHUB_EVENT_PATH="$work/event.json" \
    GITHUB_REPOSITORY=acme/shop GITHUB_SERVER_URL=https://github.com "$bin/notify-team" >"$work/out" 2>&1
}
pr open false abc main '[]' false | jq -c '.title = "<!channel> feat: add cart"' >"$fake/pr.json"
printf '0\n' >"$fake/curl-failures"
printf '[{"status": "completed", "conclusion": "success"}]\n' >"$fake/checks.json"

if (unset GUARDRAILS_SLACK_WEBHOOK GUARDRAILS_TEAMS_WEBHOOK && run_notify workflow_run "$(run_event "$guard" pull_request_target success main)"); then
  ok
else fail "without secrets it succeeds"; fi
succeeds "without secrets it says it is off" grep -F 'Team notifications are off' "$work/out" >/dev/null
fails "without secrets nothing is posted" test -e "$fake/posted"

export GUARDRAILS_SLACK_WEBHOOK=$slack_url GUARDRAILS_TEAMS_WEBHOOK=$teams_url
printf '{"workflow_runs": []}\n' >"$fake/runs.json"
succeeds "a passed guard is posted" run_notify workflow_run "$(run_event "$guard" pull_request_target success main)"
expect_eq "one post per channel" "$(grep -c '' "$fake/posted")" "2"
expect_eq "slack got the escaped fallback" "$(sed -n 1p "$fake/posted" | jq -r .text)" \
  'acme/shop #7 · &lt;!channel&gt; feat: add cart — waits for your approval'
expect_eq "teams got the card" "$(sed -n 2p "$fake/posted" | jq -r .type)" "message"
expect_eq "the URLs reach curl through its config on stdin" "$(cat "$fake/curl-config")" "url = \"$slack_url\"
url = \"$teams_url\""
fails "the URLs are not in curl's arguments" grep -F -e secretpart -e secretsig "$fake/curl-args"
fails "the URLs are not in the log" grep -F -e secretpart -e secretsig "$work/out"
for flag in --fail-with-body --max-time --proto; do
  succeeds "curl runs with $flag" grep -F -e "$flag" "$fake/curl-args" >/dev/null
done

printf '{"workflow_runs": [{"id": 40, "path": "%s", "event": "pull_request_target", "status": "completed", "conclusion": "success", "created_at": "2026-01-02T00:00:00Z", "pull_requests": [{"number": 7}]}]}\n' \
  "$guard" >"$fake/runs.json"
succeeds "a repeated guard result succeeds" run_notify workflow_run "$(run_event "$guard" pull_request_target success main)"
fails "a repeated guard result is not posted" test -e "$fake/posted"

printf '{"workflow_runs": []}\n' >"$fake/runs.json"
printf '[{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "failure"}]\n' >"$fake/checks.json"
succeeds "a pass while another guard run failed succeeds" run_notify workflow_run "$(run_event "$guard" pull_request_target success main)"
fails "a pass while another guard run failed is not posted" test -e "$fake/posted"
printf '[{"status": "completed", "conclusion": "success"}]\n' >"$fake/checks.json"
succeeds "an answered question is posted" run_notify pull_request_target \
  "$(pr_event unlabeled '"label": {"name": "needs-decision"},' '"merged": false')"
expect_eq "an answered question waits for approval" "$(sed -n 1p "$fake/posted" | jq -r .text)" \
  'acme/shop #7 · &lt;!channel&gt; feat: add cart — waits for your approval'

pr open false def main '[]' false >"$fake/pr.json"
succeeds "a stale guard result succeeds" run_notify workflow_run "$(run_event "$guard" pull_request_target failure main)"
fails "a stale guard result is not posted" test -e "$fake/posted"

pr open false abc main '[]' false >"$fake/pr.json"
succeeds "an approval is posted" run_notify status "$(status_event merge-approval success)"
expect_eq "the approval message" "$(sed -n 1p "$fake/posted" | jq -r .text)" "acme/shop #7 · feat: add cart — approved"

printf '1\n' >"$fake/curl-failures"
succeeds "a failed post is retried" run_notify status "$(status_event merge-approval success)"
succeeds "the retry is logged as a warning" grep -F '::warning::Slack webhook post failed (attempt 1 of 4): curl exit 22, HTTP 400, response: invalid_payload' "$work/out" >/dev/null

# Slack fails all four attempts; Teams still gets its message and the run fails afterwards.
printf '4\n' >"$fake/curl-failures"
fails "a post that keeps failing fails the run" run_notify status "$(status_event merge-approval success)"
succeeds "the failure names the channel" grep -F 'error: could not post to: Slack(PR #7) (see the warnings above)' "$work/out" >/dev/null
expect_eq "the other channel still gets its message" "$(tail -n 1 "$fake/posted" | jq -r .type)" "message"
fails "the failing URLs are not in the log" grep -F -e secretpart -e secretsig "$work/out"

printf '0\n' >"$fake/curl-failures"
printf '[{"status": "completed", "conclusion": "success"}]\n' >"$fake/checks.json"
export GUARDRAILS_TEAMS_WEBHOOK='http://example.com/plain'
fails "a webhook that is not https is refused" run_notify status "$(status_event merge-approval success)"
succeeds "the refusal names the secret" grep -F 'GUARDRAILS_TEAMS_WEBHOOK is not an https:// URL' "$work/out" >/dev/null

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
