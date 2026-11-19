# shellcheck shell=bash
# Pure functions behind .agent/bin/notify-team, which tells a team's Slack or Microsoft Teams channel about
# the agent's PRs. Source it after lib.sh; do not execute it. Everything here works on its arguments and stdin
# only, so tests/notify.sh in the kit can feed it hostile input offline.
#
# Kinds of notification:
#   answer    the agent asks a question (label needs-decision)
#   approve   guard passed and the PR waits for approval (also when a question is answered: label removed)
#   blocked   guard failed
#   approved  the owner approved the PR's HEAD (status mode: the commit status of approve-head)
#   merged    the PR was merged
#
# PR titles are written by the agent, so they are cleaned before they reach a message and every payload is
# built with jq, never by pasting text into JSON.

notify_guard_workflow=.github/workflows/agent-guard.yml

# Reads GitHub's event JSON (GITHUB_EVENT_PATH) on stdin and prints one tab-separated candidate per line:
# "<kind>\t<head sha>\t<pr number>\t<guard run id>". The PR number is empty for a status event (the caller
# looks the PR up by commit) and the run id is empty unless the event is a guard run. Fields that can be empty
# come last, because `read` with a tab IFS merges empty fields in the middle. Prints nothing when the
# event is not one to notify about. Argument: the event name (GITHUB_EVENT_NAME).
# Only a guard run of agent-guard.yml from pull_request_target counts: a workflow a PR adds or changes can share
# the name agent-guard, but its runs have another path or another event. A PR into another branch runs that
# branch's copy of the guard, which the agent can change; GitHub may list a PR into the default branch with
# the same head on such a run, so a passed guard is also checked with notify_guard_passed.
notify_candidates() {
  jq -r --arg event "$1" --arg guard "$notify_guard_workflow" '
    if $event == "pull_request_target" then
      .pull_request as $pr
      | if .action == "labeled" and .label.name == "needs-decision" and $pr.state == "open" then
          ["answer", $pr.head.sha, $pr.number, ""]
        elif .action == "unlabeled" and .label.name == "needs-decision" and $pr.state == "open" then
          ["approve", $pr.head.sha, $pr.number, ""]
        elif .action == "closed" and $pr.merged == true then ["merged", $pr.head.sha, $pr.number, ""]
        else empty end
    elif $event == "workflow_run" then
      .workflow_run as $run
      | .repository.default_branch as $default
      | select($run.path == $guard and $run.event == "pull_request_target" and $run.status == "completed")
      | (if $run.conclusion == "success" then "approve" elif $run.conclusion == "failure" then "blocked" else empty end) as $kind
      | $run.pull_requests[]? | select(.base.ref == $default) | [$kind, $run.head_sha, .number, $run.id]
    elif $event == "status" then
      select(.context == "merge-approval" and .state == "success") | ["approved", .sha, "", ""]
    else error("unsupported event: \($event)") end
    | map(tostring) | @tsv'
}

# Reads `GET repos/{repo}/commits/{sha}/pulls` on stdin and prints the number of each open PR into the default
# branch whose HEAD is that commit. Arguments: head sha, default branch.
notify_prs_at_head() {
  jq -r --arg sha "$1" --arg default "$2" \
    '.[] | select(.state == "open" and .head.sha == $sha and .base.ref == $default) | .number'
}

# Reads `GET repos/{repo}/pulls/{number}` on stdin and succeeds when the notification still describes the PR:
# events arrive late, and a push, a new question or a draft makes an older guard result stale. A question
# outranks the guard result, as in the owner's inbox. Arguments: kind, head sha of the event, default branch.
notify_still_current() {
  jq -e --arg kind "$1" --arg sha "$2" --arg default "$3" '
    (.base.ref == $default) as $into_default
    | if $kind == "merged" then .merged == true and $into_default
      elif $kind == "answer" then .state == "open" and $into_default and any(.labels[]?; .name == "needs-decision")
      elif $kind == "approved" then .state == "open" and .head.sha == $sha and $into_default
      elif $kind == "approve" or $kind == "blocked" then
        .state == "open" and (.draft | not) and .head.sha == $sha and $into_default
        and (any(.labels[]?; .name == "needs-decision") | not)
      else error("unknown notification kind: \($kind)") end' >/dev/null
}

# Reads the guard check runs of a HEAD (`GET repos/{repo}/commits/{sha}/check-runs?check_name=guard`, the
# check_runs array) on stdin and succeeds when one passed and none failed. Any failure wins, as in the owner's
# inbox: a guard run from another branch's copy, or a job a PR's workflow names guard, cannot turn a failed
# guard into a PR that waits for approval.
notify_guard_passed() {
  jq -e 'any(.[]; .status == "completed" and .conclusion == "success")
    and all(.[]; .status != "completed" or (.conclusion | IN("success", "cancelled", "skipped", "neutral")))' >/dev/null
}

# Reads {"runs": <workflow_runs of `GET repos/{repo}/actions/runs?head_sha=…&event=pull_request_target`>,
# "events": <`GET repos/{repo}/issues/{number}/events`>} on stdin and succeeds when an earlier guard run of the
# same PR and HEAD already ended the same way since the PR last became ready for review (or was reopened). The
# guard runs again when a PR's title or description changes; the channel hears about each result of a HEAD
# once. A draft is not notified, so the result of a HEAD counts again once the PR is ready.
# Arguments: run id, PR number, conclusion.
notify_guard_seen() {
  jq -e --argjson id "$1" --argjson pr "$2" --arg conclusion "$3" --arg guard "$notify_guard_workflow" '
    ([.events[] | select(.event == "ready_for_review" or .event == "reopened") | .created_at] | max // "") as $since
    | any(.runs[]; .id < $id and .path == $guard and .event == "pull_request_target" and .status == "completed"
        and .conclusion == $conclusion and .created_at > $since and any(.pull_requests[]?; .number == $pr))' >/dev/null
}

# Prints the short phrase that ends a message of the given kind.
notify_phrase() {
  case $1 in
    answer) printf 'the agent asks for a decision\n' ;;
    approve) printf 'waits for your approval\n' ;;
    blocked) printf 'is blocked: guard failed\n' ;;
    approved) printf 'approved\n' ;;
    merged) printf 'merged\n' ;;
    *) die "unknown notification kind: $1" ;;
  esac
}

# Reads `GET repos/{repo}/pulls/{number}` on stdin and prints the message as compact JSON:
# {ref: "acme/shop #12", url, detail: " · feat: add cart — waits for your approval"}. The link is built from
# the server URL, the repository and the PR number, never taken from the event. The title loses control and
# invisible formatting characters (line breaks, bidirectional overrides, zero-width characters), runs of
# whitespace become one space, and it is cut to 100 characters.
# Arguments: server URL (GITHUB_SERVER_URL), owner/repo, kind.
notify_message() {
  local server=$1 repo=$2 phrase
  [[ $server =~ ^https://[A-Za-z0-9.-]+$ ]] || die "not a GitHub server URL: $server"
  [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "not an owner/repo name: $repo"
  phrase=$(notify_phrase "$3") || return 1
  jq -c --arg server "$server" --arg repo "$repo" --arg phrase "$phrase" '
    (.number | tostring) as $number
    | if ($number | test("^[0-9]+$")) then . else error("not a PR number: \($number)") end
    | (.title // "" | gsub("\\p{Cf}"; "") | gsub("[\\p{Z}\\p{Cc}]+"; " ") | sub("^ "; "") | sub(" $"; "")) as $clean
    | (if ($clean | length) > 100 then $clean[0:99] + "…" else $clean end) as $title
    | {ref: "\($repo) #\($number)", url: "\($server)/\($repo)/pull/\($number)",
       detail: ((if $title == "" then "" else " · \($title)" end) + " — \($phrase)")}'
}

# Reads a message (notify_message) on stdin and prints the Slack incoming webhook payload. The visible text is
# a rich_text block, whose text elements Slack shows literally: no mrkdwn, no mentions, no automatic links.
# The top-level text is only the notification fallback; Slack parses it, so &, < and > are escaped there,
# which turns <!channel>, <@user> and <url|label> into plain text. Link previews are off.
notify_slack_payload() {
  jq -c '
    {text: ((.ref + .detail) | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")),
     unfurl_links: false, unfurl_media: false,
     blocks: [{type: "rich_text", elements: [{type: "rich_text_section", elements: [
       {type: "link", url: .url, text: .ref},
       {type: "text", text: .detail}]}]}]}'
}

# Reads a message (notify_message) on stdin and prints the payload for a Microsoft Teams Workflows webhook
# ("When a Teams webhook request is received" in Power Automate): a message with one Adaptive Card. The title
# sits in a TextRun, which Adaptive Cards render without Markdown; "](" is split as well, so a Markdown link
# in a title stays text should a client render Markdown anyway. The PR opens from the card's one action.
notify_teams_payload() {
  jq -c '
    {type: "message", attachments: [{
      contentType: "application/vnd.microsoft.card.adaptive", contentUrl: null,
      content: {"$schema": "http://adaptivecards.io/schemas/adaptive-card.json", type: "AdaptiveCard", version: "1.4",
        body: [{type: "RichTextBlock", inlines: [{type: "TextRun", text: ((.ref + .detail) | gsub("\\]\\("; "] ("))}]}],
        actions: [{type: "Action.OpenUrl", title: "Open pull request", url: .url}]}}]}'
}
