# shellcheck shell=bash
# Shared by bin/guardrails and its tests. Source it after lib.sh; do not execute it.
# Functions that only read or change a local checkout are kept free of GitHub calls so tests can run offline.

# shellcheck disable=SC2154 # kit is set by the sourcing script
template="$kit/skills/guardrails-init/template"

# Prints every way the kit-owned files of a checkout differ from the installed kit's template, one per line.
# Nothing printed means the checkout carries exactly this kit: .agent/, .claude/settings.json, .cursor/hooks.json,
# the guard, security and team notification workflows and each checks-<lang> workflow. The notification
# workflow holds the webhook secrets, so where it posts may not change without the kit. The Makefile,
# AGENTS.md and .github/security-ignore hold project judgment and are not compared.
kit_drift() {
  local dir=$1 workflow name
  [[ -d "$dir/.agent" ]] || {
    printf 'missing: .agent/\n'
    return 0
  }
  # diff exits 1 when the trees differ (reported below) and 2 when it could not compare them (an error).
  local differences status=0
  differences=$(diff -rq "$template/.agent" "$dir/.agent") || status=$?
  [[ $status -le 1 ]] || die "could not compare $dir/.agent with the kit template (diff exit $status)"
  [[ -z $differences ]] || sed -E \
    -e "s#^Files $template/(.*) and .* differ\$#differs from the kit: \\1#" \
    -e "s#^Only in $template/(.*): (.*)\$#missing: \\1/\\2#" \
    -e "s#^Only in $dir/(.*): (.*)\$#not in the kit: \\1/\\2#" <<<"$differences"
  # diff and cmp follow symlinks and ignore modes, so check both separately.
  # Only the kit's own file in .cursor/: projects may link their Cursor rules.
  find "$dir/.agent" "$dir/.claude" "$dir/.cursor/hooks.json" "$dir/.github" -type l 2>/dev/null | sed "s#^$dir/#symlink not allowed: #"
  (cd "$template" && find .agent -type f) | while IFS= read -r file; do
    [[ -f "$dir/$file" && ! -L "$dir/$file" ]] || continue
    if [[ -x "$template/$file" && ! -x "$dir/$file" ]] || [[ ! -x "$template/$file" && -x "$dir/$file" ]]; then
      printf 'file mode differs from the kit: %s\n' "$file"
    fi
  done
  cmp -s "$template/.claude/settings.json" "$dir/.claude/settings.json" ||
    printf 'differs or missing: .claude/settings.json\n'
  cmp -s "$template/.cursor/hooks.json" "$dir/.cursor/hooks.json" ||
    printf 'differs or missing: .cursor/hooks.json\n'
  for name in agent-guard.yml security.yml agent-notify.yml; do
    cmp -s "$template/.github/workflows/$name" "$dir/.github/workflows/$name" ||
      printf 'differs or missing: .github/workflows/%s\n' "$name"
  done
  local found=0
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    found=1
    name=${workflow##*/}
    cmp -s "$template/ci/$name" "$workflow" || printf 'differs from the kit: .github/workflows/%s\n' "$name"
  done
  [[ $found -eq 1 ]] || printf 'missing: .github/workflows/checks-<lang>.yml\n'
}

# Git on the kit install without the repository settings that run programs locally (fsmonitor, hooks, pager).
# Talking to the origin needs kit_remote_git as well: a remote's settings can run programs too.
kit_git() {
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -C "$kit" "$@"
}

# The kit origin's URL from the install's config: an https GitHub repository, or an absolute path to a local
# clone (tests, mirrors). Git is then given this URL, never the remote's name, so the remote's other settings
# (such as an upload program, which git would run) do not apply.
kit_origin() {
  local url
  url=$(kit_git remote get-url origin) || die "the kit install at $kit has no origin remote"
  [[ $url =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ || ($url == /* && $url != *::*) ]] ||
    die "the kit install's origin is '$url', not https://github.com/<owner>/<repo>. Fix it with: git -C $kit remote set-url origin https://github.com/<owner>/agent-guardrails.git"
  printf '%s\n' "$url"
}

# Git against the kit origin's URL: the ext transport is off, so a URL rewrite in the config (url.*.insteadOf)
# cannot turn the fetch into a program, and no credential helper runs.
kit_remote_git() {
  kit_git -c protocol.ext.allow=never -c credential.helper= "$@"
}

# Prints the kit install's local changes, one per line: edits and untracked files (whatever the repository
# config says about showing them) and files git was told to stop looking at (assume-unchanged, skip-worktree).
kit_local_changes() {
  kit_git status --porcelain --untracked-files=all
  kit_git ls-files -v | awk '$1 != "H" { sub(/^[^ ]+ /, ""); print "not watched by git: " $0 }'
}

# Prints, one per line, why the workflow on stdin could let its token write check runs or commit statuses (and
# so fake a required check or an approval): `checks` or `statuses` at write, `write-all`, a permission GitHub
# does not define, or YAML the check cannot read. Nothing printed means none. It runs the template's
# .agent/workflow/check.py, the same file ci-guard runs, so the owner's side and CI cannot disagree; it dies
# when that check cannot run.
workflow_token_problems() {
  python3 -I -S -B "$template/.agent/workflow/check.py" token-problems ||
    die "could not check a workflow: $template/.agent/workflow/check.py needs python3 3.8 or newer"
}

# Succeeds for a file name GitHub may load as a workflow (.yml or .yaml in any case), as ci-guard decides it.
is_workflow_file() {
  case $(tr '[:upper:]' '[:lower:]' <<<"$1") in
    *.yml | *.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

# Dies when any workflow of the checkout could write check runs or commit statuses (and so fake a
# required check or merge-approval): pull_request runs execute the PR's code with that token. find lists
# dot-named files too, which a shell glob would skip. Argument: the checkout's directory.
require_no_status_rights() {
  local dir=$1 workflow problems
  [[ -d $dir/.github/workflows ]] || return 0
  while IFS= read -r -d '' workflow; do
    [[ -f $workflow ]] || continue
    is_workflow_file "$workflow" || continue
    problems=$(workflow_token_problems <"$workflow")
    [[ -z $problems ]] ||
      die "${workflow#"$dir"/} could let its token write checks or statuses (could fake an approval); fix that first:
$problems"
  done < <(find "$dir/.github/workflows" -mindepth 1 -maxdepth 1 ! -type d -print0)
}

# Prints a repository path for a contents API URL: each segment percent-encoded, so a file name holding ?, &
# or # cannot change the request (such as its ref). Argument: the path.
contents_api_path() {
  jq -rn --arg path "$1" '$path | split("/") | map(@uri) | join("/")'
}

# Succeeds for a changed file that can change what CI enforces: workflows and other GitHub config (including
# .github/security-ignore, which accepts findings of the security check), the guardrails themselves (.agent/,
# and the agents' hook settings in .claude/, .cursor/ and .codex/), the Makefiles CI runs, and code owners.
# approve-head marks these "!!" and asks for a second confirmation.
changes_enforcement() {
  case $1 in
    .github/* | .agent/* | .claude/* | .cursor/* | .codex/* | Makefile | */Makefile | *.mk | CODEOWNERS | docs/CODEOWNERS) return 0 ;;
    *) return 1 ;;
  esac
}

# Reads `GET repos/{repo}/actions/runs?head_sha=…&event=pull_request_target` on stdin and prints the
# conclusion of the newest agent-guard.yml run of PR $1 into branch $2, or "missing". A pull_request_target run
# uses the workflow of its base branch, so only a run into the default branch counts. GitHub lists the PR of
# a run only for PRs from the same repository; PRs from forks are not supported.
guard_conclusion() {
  jq -r --argjson pr "$1" --arg base "$2" '
    [.workflow_runs[] | select(.path == ".github/workflows/agent-guard.yml"
      and any(.pull_requests[]?; .number == $pr and .base.ref == $base))]
    | sort_by(.created_at) | last | .conclusion // "missing"'
}

# Dies in the agent's environment: the agent's sessions set a GitHub token or point gh at the agent App's
# config. The owner's commands run only in the owner's own shell. Argument: the command's name.
require_owner_environment() {
  [[ -z ${GH_TOKEN:-} && -z ${GITHUB_TOKEN:-} && -z ${GH_CONFIG_DIR:-} ]] ||
    die "GH_TOKEN, GITHUB_TOKEN or GH_CONFIG_DIR is set: this looks like the agent's environment. Run $1 in your own shell."
}

# Dies unless the kit install is exactly the reviewed main of its origin: no local changes, HEAD equal to
# origin's main. The owner's commands and the template they compare against come from this checkout, so
# a change an agent made there must not silently become the reference.
require_reviewed_kit() {
  local local_sha remote_sha origin
  origin=$(kit_origin)
  [[ -z $(kit_local_changes) ]] ||
    die "the kit install at $kit has local changes, so this command may not be the reviewed one. Inspect them with: git -C $kit status"
  local_sha=$(kit_git rev-parse HEAD)
  remote_sha=$(kit_remote_git ls-remote "$origin" refs/heads/main | cut -f1) ||
    die "could not reach $origin to confirm the kit install is its reviewed main"
  [[ -n $remote_sha ]] || die "$origin has no main branch"
  [[ $local_sha == "$remote_sha" ]] ||
    die "the kit install at $kit is at ${local_sha:0:7}, not at main of $origin (${remote_sha:0:7}). Update it with: git -C $kit switch main && git -C $kit pull --ff-only"
}

# Prints the files a PR changes, one per line; dies when GitHub cannot list them or when a file name holds a
# control character. Names are written by the agent, and a newline or escape sequence in one could forge
# lines of the review the owner reads (or a confirmation prompt the app answers). The list must be complete: a
# page that fails midway, or GitHub's cap of 3000 files, would hide files from the review, so the count is
# compared with the PR's own count of changed files.
pr_files() {
  local files unsafe expected count
  files=$(gh api --paginate "repos/$1/pulls/$2/files?per_page=100" \
    --jq '.[].filename | if test("[[:cntrl:]]") then "control-character " + gsub("[[:cntrl:]]"; "?") else . end') ||
    die "could not list the files of PR #$2 in $1"
  [[ -n $files ]] || die "could not list the files of PR #$2 in $1"
  expected=$(gh api "repos/$1/pulls/$2" --jq .changed_files) || die "could not read PR #$2 in $1"
  count=$(grep -c '' <<<"$files")
  [[ $count == "$expected" ]] ||
    die "GitHub listed $count of the $expected files PR #$2 in $1 changes (it lists at most 3000); refuse to show or approve a partial list. Split the PR."
  unsafe=$(grep '^control-character ' <<<"$files" || true)
  [[ -z $unsafe ]] || die "PR #$2 in $1 has file names with control characters; refuse to show or approve it:
${unsafe//control-character /  }"
  printf '%s\n' "$files"
}

# Writes one JSON event line for the Guardrails app when it asked for them (GUARDRAILS_EVENTS_FD names an
# open file descriptor). The terminal output stays the same; the app builds its review screen and its
# answers from these events, never from text it scraped off the terminal.
emit_event() {
  [[ ${GUARDRAILS_EVENTS_FD:-} =~ ^[3-9]$ ]] || return 0
  printf '%s\n' "$1" >&"$GUARDRAILS_EVENTS_FD"
}

# Reads "<marker>\t<path>" lines on stdin and prints them as a JSON array of {path, marker} objects.
files_json() {
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {marker: .[0], path: .[1]})'
}

# Prints the checks-<lang> job names a checkout's workflows define (the ruleset requires each one).
check_jobs() {
  local dir=$1 workflow
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    sed -nE 's/^  (checks-[a-z]+):$/\1/p' "$workflow"
  done | sort -u
}

# Removes the kit from a checkout, leaving it as before the kit was installed. Prints one line per file
# it kept on purpose or could only partly undo, so the owner can review them in the removal PR.
# Kept: specs/ (the team's record of decided requirements), dev dependencies, .gitignore entries.
remove_kit_files() {
  local dir=$1 workflow name makefile lang
  rm -rf "$dir/.agent"
  rm -f "$dir/.github/workflows/agent-guard.yml" "$dir/.github/workflows/security.yml" "$dir/.github/security-ignore" \
    "$dir/.github/workflows/agent-notify.yml"
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    name=${workflow##*/}
    if cmp -s "$template/ci/$name" "$workflow"; then
      rm -f "$workflow"
    else
      printf 'kept (differs from the kit, review it): .github/workflows/%s\n' "$name"
    fi
  done
  if [[ -f "$dir/.claude/settings.json" ]]; then
    if cmp -s "$template/.claude/settings.json" "$dir/.claude/settings.json"; then
      rm -f "$dir/.claude/settings.json"
      rmdir "$dir/.claude" 2>/dev/null || true
    else
      printf 'kept (differs from the kit, remove the kit hooks by hand): .claude/settings.json\n'
    fi
  fi
  if [[ -f "$dir/.cursor/hooks.json" ]]; then
    if cmp -s "$template/.cursor/hooks.json" "$dir/.cursor/hooks.json"; then
      rm -f "$dir/.cursor/hooks.json"
      rmdir "$dir/.cursor" 2>/dev/null || true
    else
      printf 'kept (differs from the kit, remove the kit hooks by hand): .cursor/hooks.json\n'
    fi
  fi
  makefile="$dir/Makefile"
  if [[ -f $makefile ]] && grep -F 'include .agent/common.mk' "$makefile" >/dev/null; then
    for lang in typescript javascript python rust swift; do
      if cmp -s "$template/makefiles/Makefile.$lang" "$makefile"; then
        rm -f "$makefile"
        break
      fi
    done
    if [[ -f $makefile ]]; then
      grep -vF 'include .agent/common.mk' "$makefile" >"$makefile.tmp"
      mv "$makefile.tmp" "$makefile"
      printf 'edited (kit include removed; targets that called .agent/ scripts need a look): Makefile\n'
    fi
  fi
  [[ -f "$dir/AGENTS.md" ]] && remove_agents_section "$dir/AGENTS.md"
  [[ -d "$dir/specs" ]] && printf 'kept (decided requirements stay as documentation): specs/\n'
  return 0
}

# Removes the kit's section from AGENTS.md: between the agent-guardrails start/end markers, or, for
# installations made before the markers existed, from "## Agent guardrails" to the next "## " heading.
remove_agents_section() {
  local file=$1
  if grep -F '<!-- agent-guardrails:start -->' "$file" >/dev/null; then
    awk '/<!-- agent-guardrails:start -->/ {skip = 1} !skip {print} /<!-- agent-guardrails:end -->/ {skip = 0}' "$file" >"$file.tmp"
  else
    awk '/^## Agent guardrails[[:space:]]*$/ {skip = 1; next} skip && /^## / {skip = 0} !skip {print}' "$file" >"$file.tmp"
  fi
  # Squeeze the blank lines the removed section leaves behind and drop trailing ones.
  cat -s "$file.tmp" | awk '{lines[NR] = $0} NF {last = NR} END {for (i = 1; i <= last; i++) print lines[i]}' >"$file"
  rm -f "$file.tmp"
}

# Reads `gh pr list --json number,title,url,isDraft,headRefOid,labels,statusCheckRollup,reviewDecision,
# autoMergeRequest[,author,updatedAt]` on stdin and prints one compact JSON object per PR: {number, url, title,
# kind, note, sha, draft, author, updated, autoMerge}. Argument: the numbers of the PRs in the repository's merge
# queue (JSON array, [] without a queue; see queued_prs). Kinds: queued (in the merge queue, so it merges once
# its group passes; nothing waits for the owner), answer (the agent asked a question: label needs-decision), draft (the agent's
# work in progress), approved (HEAD approved by merge-approval in status mode, or by the required review in
# review mode, where GitHub dismisses the review when a push changes the PR), wait (guard running), blocked (guard failed), approve (guard passed,
# HEAD not approved yet; the note sums up the security and checks-<lang> runs). Any failed run named guard wins
# over a later success, because a workflow added by the PR could report a run of that name (approve-head checks
# the real guard run). Titles are written by the agent, so control characters are replaced before they reach a
# terminal or the app.
pr_states() {
  jq -c --argjson queued "$1" '
    def latest(f): [.statusCheckRollup[]? | select(f)] | sort_by(.startedAt // .createdAt // "") | last;
    def clean: gsub("[[:cntrl:]]"; "?");
    .[]
    | .title |= clean
    | (latest(.__typename == "CheckRun" and .name == "guard")) as $latest_guard
    | (if any(.statusCheckRollup[]?; .__typename == "CheckRun" and .name == "guard" and .status == "COMPLETED"
           and (.conclusion | IN("SUCCESS", "CANCELLED", "SKIPPED", "NEUTRAL") | not))
       then {status: "COMPLETED", conclusion: "FAILURE"} else $latest_guard end) as $guard
    | (latest(.__typename == "StatusContext" and .context == "merge-approval")) as $approval
    | ([.statusCheckRollup[]? | select(.__typename == "CheckRun" and (.name == "security" or (.name | startswith("checks-"))))]) as $checks
    | (if ($checks | length) == 0 then "checks not started"
       elif any($checks[]; .status != "COMPLETED") then "checks running"
       elif all($checks[]; .conclusion == "SUCCESS") then "checks green"
       else "checks failing" end) as $checks_note
    | (if (.number as $n | $queued | index($n)) != null then ["queued", "in the merge queue; merges when its group passes"]
       elif any(.labels[]?; .name == "needs-decision") then ["answer", "the agent is waiting for your decision"]
       elif .isDraft then ["draft", "the agent is working on it"]
       elif ($approval.state // "") == "SUCCESS" or .reviewDecision == "APPROVED" then
         if .autoMergeRequest != null then ["approved", "approved; merges when checks pass"]
         else ["approved", "approved; auto-merge is off, so merge it yourself"] end
       elif $guard == null or $guard.status != "COMPLETED" then ["wait", "guard is running"]
       elif $guard.conclusion != "SUCCESS" then ["blocked", "guard failed: the agent has to fix the PR"]
       else ["approve", $checks_note] end) as $state
    | {number, url, title, kind: $state[0], note: $state[1], sha: (.headRefOid // ""), draft: .isDraft,
       author: ((.author.login // "") | clean), updated: (.updatedAt // ""), autoMerge: (.autoMergeRequest != null)}'
}

# Reads the same input as pr_states and prints one tab-separated line per PR that needs the owner:
# "<kind>\t<url>\t<title>\t<note>\t<sha>" for answer, approve, wait and blocked (sha: the PR's HEAD, last because
# it can be empty). Drafts, approved and queued PRs are left out. Argument: as for pr_states.
classify_prs() {
  pr_states "$1" | jq -r 'select(.kind | IN("answer", "approve", "wait", "blocked")) | [.kind, .url, .title, .note, .sha] | @tsv'
}

# Reads the nodes of the owner's repositories (GraphQL, see `guardrails projects`) and prints one compact
# JSON object per repo with its state for the app:
#   on        listed on this Mac and its agent-guardrails ruleset is active
#   alarm     listed but the ruleset is not active, or tagged with the topic but not listed, or (an enforced
#             repository another account owns, marked unreadable) GitHub could not read it
#   ready     an open /guardrails-init PR from this repo (not a fork), authored by the owner
#   no-admin  the owner cannot apply rulesets here
#   off       none of the above
# mode is "review" for an enforced repo whose agent-guardrails-review ruleset is active, "status" for another
# enforced repo, null otherwise. mergeQueue is true when the active agent-guardrails ruleset has a merge queue
# rule; organization is true for a repository an organization owns (only those can have one). agentApp is "installed" or "missing" for the agent App on this Mac, "none" when
# no App is registered here.
# Arguments: the owner's login, the enforced-repo list (one owner/repo per line), "registered" or "none" for
# the agent App, and the repositories it is installed on (one owner/repo per line).
project_states() {
  jq -c --arg login "$1" --arg listed "$2" --arg app "$3" --arg installed "$4" '
    def clean: gsub("[[:cntrl:]]"; "?");
    ($listed | ascii_downcase | split("\n") | map(select(length > 0))) as $registry
    | (.nameWithOwner | ascii_downcase) as $key
    | ($registry | index($key) != null) as $registered
    | ($installed | ascii_downcase | split("\n") | map(select(length > 0))) as $agent_repos
    | ([.rulesets.nodes[]? | select(.name == "agent-guardrails") | .enforcement | ascii_downcase] | first // "missing") as $ruleset
    | any(.repositoryTopics.nodes[]?; .topic.name == "agent-guardrails") as $tagged
    | ([.bootstrap.nodes[]? | select((.isCrossRepository | not) and .author.login == $login)] | first) as $bootstrap
    | (if .unreadable == true then ["alarm", "cannot read it from GitHub: deleted, moved, or your access changed"]
       elif $registered and $ruleset == "active" then ["on", "ruleset active"]
       elif $registered then ["alarm", "ruleset \($ruleset): restore it or check the audit log"]
       elif $tagged then ["alarm", "tagged agent-guardrails but not in this Mac'"'"'s list"]
       elif $ruleset == "active" then ["alarm", "agent-guardrails ruleset active but not in this Mac'"'"'s list"]
       elif .viewerPermission != "ADMIN" then ["no-admin", "you cannot apply rulesets here"]
       elif $bootstrap != null then ["ready", "bootstrap PR open"]
       else ["off", ""] end) as $state
    | {repo: .nameWithOwner, state: $state[0], note: $state[1], private: .isPrivate, fork: .isFork,
       branch: (.defaultBranchRef.name // ""), pushed: (.pushedAt // ""), openPRs: .pullRequests.totalCount,
       setupURL: ($bootstrap.url // ""), setupTitle: (($bootstrap.title // "") | clean),
       mode: (if $state[0] != "on" then null
              elif any(.rulesets.nodes[]?; .name == "agent-guardrails-review" and (.enforcement | ascii_downcase) == "active")
              then "review" else "status" end),
       agentApp: (if $app != "registered" then "none" elif ($agent_repos | index($key)) != null then "installed"
                  else "missing" end),
       mergeQueue: any(.rulesets.nodes[]?; .name == "agent-guardrails" and (.enforcement | ascii_downcase) == "active"
                       and any(.rules.nodes[]?; .type == "MERGE_QUEUE")),
       organization: (.owner.__typename == "Organization")}'
}

# jq definitions shared by the report functions.
#   epoch            a GitHub timestamp in seconds; REST answers carry fractions and offsets
#                    (2026-11-17T12:49:41.541+02:00), which jq's fromdateiso8601 refuses.
#   nearest_rank($q) the nearest-rank percentile of an array of numbers, null for an empty one.
#   ruleset_changes  the differences between two ruleset states {before, after} in words, one string each.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
report_jq_defs='
  def epoch: capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")
    | (.d + "Z" | fromdateiso8601)
      - (if .z == "Z" then 0
         else (if .z[0:1] == "-" then -1 else 1 end) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end);
  def nearest_rank($q): if length == 0 then null else sort | .[([(length * $q | ceil) - 1, 0] | max)] end;
  def stats: {count: length, median: nearest_rank(0.5), p90: nearest_rank(0.9)};
  def words: if type == "array" and length > 0 and all(.[]; type == "object" and has("context")) then map(.context) | join(", ")
    elif type == "array" and length == 0 then "none" elif type == "string" then . else tojson end;
  def actors: [.bypass_actors[]? | "\(.actor_type) \(.actor_id) (\(.bypass_mode))"] | if length == 0 then "nobody" else join(", ") end;
  def rule($s; $t): [$s.rules[]? | select(.type == $t)][0];
  def ruleset_changes:
    .before as $b | .after as $a
    | if $b == null then ["created: \($a.target // "branch") ruleset, \($a.enforcement), rules \([$a.rules[]?.type] | join(", "))"]
      else
        [ (if $b.name != $a.name then "renamed from \($b.name)" else empty end),
          (if $b.enforcement != $a.enforcement then "enforcement \($b.enforcement) → \($a.enforcement)" else empty end),
          (if ($b | actors) != ($a | actors) then "bypass list \($b | actors) → \($a | actors)" else empty end),
          (if $b.conditions != $a.conditions then "targets \($b.conditions | tojson) → \($a.conditions | tojson)" else empty end),
          (([$b.rules[]?.type] - [$a.rules[]?.type])[] | "removed rule \(.)"),
          (([$a.rules[]?.type] - [$b.rules[]?.type])[] | "added rule \(.)"),
          ([$a.rules[]?.type][] as $t | rule($b; $t) as $old | rule($a; $t) as $new | select($old != null)
            | ((($old.parameters // {}) | keys) + (($new.parameters // {}) | keys) | unique[]) as $k
            | select($old.parameters[$k] != $new.parameters[$k])
            | (if $k == "required_status_checks" then "required checks" else "\($t) \($k)" end) as $what
            | "\($what) \($old.parameters[$k] | words) → \($new.parameters[$k] | words)")
        ] | if length == 0 then ["saved without changes"] else . end
      end;
'

# Prints the start of a report window as a UTC timestamp. Arguments: now (epoch seconds), days.
report_since() {
  jq -n -r --argjson now "$1" --argjson days "$2" '$now - $days * 86400 | todate'
}

# Reads the pull requests a report covers (a JSON array of GraphQL PullRequest nodes, see `guardrails report`)
# and prints one compact JSON object with the window's numbers. A PR counts when it was open at some time in
# the window (still open, or closed or merged since then); the time and merge numbers count the PRs merged in it.
#   merged            {total, agent, people, otherBots}: merged PRs by author; agent is the agent App's bot
#   approve, merge    {count, median, p90} in seconds, from ready for review (the last ReadyForReviewEvent
#                     before the merge, else the PR's creation) to the first approval after it, and to the merge
#   reapproved        PRs approved on more than one commit: a push needed a new approval
#   guardFailed, checksFailed, failed, failedThenMerged
#                     PRs with a failed guard run, a failed checks-<lang> run, either, and of those the ones
#                     merged with guard and every checks-<lang> job green on the final commit
#   adminMerges       merged PRs with no approval on their final commit (no standing approving review, no
#                     merge-approval success): an admin bypassed the review rule, or the PR merged before the
#                     guardrails were on. {number, title, url, mergedBy, mergedAt}
#   partial           PRs with more commits or timeline events than the query reads; their numbers can be short
# An approval is an approving review (also one a later push dismissed) or a merge-approval success. Titles are
# written by the agent, so control characters are replaced. Arguments: window start (timestamp), agent App slug
# ("" when none is registered).
pr_report() {
  jq -c --arg since "$1" --arg agent "$2" "$report_jq_defs"'
    def clean: gsub("[[:cntrl:]]"; "?");
    def failed: .__typename == "CheckRun" and .status == "COMPLETED"
      and (.conclusion | IN("SUCCESS", "CANCELLED", "SKIPPED", "NEUTRAL") | not);
    def runs: [.commits.nodes[]? | .commit as $c | $c.statusCheckRollup.contexts.nodes[]? | . + {oid: $c.oid}];
    def head_runs: [.commits.nodes[-1]?.commit.statusCheckRollup.contexts.nodes[]?];
    def approvals:
      [.timelineItems.nodes[]? | select(.__typename == "ReviewDismissedEvent" and .previousReviewState == "APPROVED")
        | .review.id] as $dismissed
      | [(.timelineItems.nodes[]? | select(.__typename == "PullRequestReview"
            and (.state == "APPROVED" or (.state == "DISMISSED" and (.id as $id | $dismissed | index($id) != null))))
          | {at: (.submittedAt | epoch), oid: .commit.oid}),
         (runs[] | select(.__typename == "StatusContext" and .context == "merge-approval" and .state == "SUCCESS")
          | {at: (.createdAt | epoch), oid})]
      | sort_by(.at);
    def ready_at($until): ([.timelineItems.nodes[]? | select(.__typename == "ReadyForReviewEvent") | .createdAt | epoch
      | select(. <= $until)] | max) // (.createdAt | epoch);
    def green_head: head_runs as $runs
      | ([$runs[] | select(.__typename == "CheckRun" and (.name == "guard" or (.name | startswith("checks-"))))]
         | group_by(.name) | map(sort_by(.completedAt // "") | last)) as $latest
      | any($latest[]; .name == "guard") and all($latest[]; .conclusion == "SUCCESS");
    def standing_approval: any(.timelineItems.nodes[]?; .__typename == "PullRequestReview" and .state == "APPROVED")
      or any(head_runs[]; .__typename == "StatusContext" and .context == "merge-approval" and .state == "SUCCESS");
    def author_kind: (.author.login // "" | ascii_downcase | sub("\\[bot\\]$"; "")) as $login
      | if .author.__typename == "Bot" and $agent != "" and $login == ($agent | ascii_downcase) then "agent"
        elif .author.__typename == "Bot" then "otherBots" else "people" end;
    ($since | epoch) as $from
    | [.[] | select(.closedAt == null or (.closedAt | epoch) >= $from)] as $prs
    | [$prs[] | select(.mergedAt != null) | . + {merged_at: (.mergedAt | epoch)}] as $merged
    | [$prs[] | select(any(runs[]; failed and (.name == "guard" or (.name | startswith("checks-")))))] as $failed
    | {
        prs: ($prs | length),
        merged: ({total: ($merged | length), agent: 0, people: 0, otherBots: 0}
          + ($merged | group_by(author_kind) | map({key: (.[0] | author_kind), value: length}) | from_entries)),
        approve: [$merged[] | ready_at(.merged_at) as $ready | [approvals[] | select(.at >= $ready)][0]
          | select(. != null) | .at - $ready] | stats,
        merge: [$merged[] | .merged_at - ready_at(.merged_at)] | stats,
        reapproved: [$prs[] | select([approvals[].oid] | unique | length > 1)] | length,
        guardFailed: [$prs[] | select(any(runs[]; failed and .name == "guard"))] | length,
        checksFailed: [$prs[] | select(any(runs[]; failed and (.name | startswith("checks-"))))] | length,
        failed: ($failed | length),
        failedThenMerged: [$failed[] | select(.mergedAt != null and green_head)] | length,
        adminMerges: [$merged[] | select(standing_approval | not)
          | {number, title: (.title | clean), url, mergedBy: ((.mergedBy.login // "") | clean), mergedAt}],
        partial: [$prs[] | select(.commits.pageInfo.hasPreviousPage or .timelineItems.pageInfo.hasNextPage) | .number]
      }'
}

# Reads the history of one ruleset (GET /repos/{r}/rulesets/{id}/history, one version per line or as arrays)
# and prints the version IDs whose state the report needs: every version in the window, and the newest one before
# it, which the oldest change in the window is compared with. Argument: window start (timestamp).
ruleset_versions_needed() {
  jq -s -r --arg since "$1" "$report_jq_defs"'
    ($since | epoch) as $from
    | [.[] | if type == "array" then .[] else . end] | sort_by(.updated_at | epoch)
    | ([.[] | select((.updated_at | epoch) < $from)] | last // empty), (.[] | select((.updated_at | epoch) >= $from))
    | .version_id'
}

# Reads the versions of one ruleset as a JSON array (GET /repos/{r}/rulesets/{id}/history/{version}, each with
# a login: the actor's GitHub login, or null when the actor is not a user) and prints one compact JSON object per
# version in the window: {time (UTC), actor, ruleset, changes}. changes compares a version with the one before it;
# the oldest version a ruleset has is its creation. Arguments: window start (timestamp), ruleset name.
ruleset_audit() {
  jq -c --arg since "$1" --arg name "$2" "$report_jq_defs"'
    ($since | epoch) as $from
    | sort_by(.updated_at | epoch) as $versions
    | range(0; $versions | length) as $i
    | $versions[$i] | select((.updated_at | epoch) >= $from)
    | {time: (.updated_at | epoch | todate), actor: (.login // "\(.actor.type) \(.actor.id)"), ruleset: $name,
       changes: ({before: (if $i == 0 then null else $versions[$i - 1].state end), after: .state} | ruleset_changes)}'
}

# Reads report lines (one JSON object per repository, as `guardrails report --json` prints them) and prints them
# for a person to read.
report_text() {
  jq -r "$report_jq_defs"'
    def span: if . == null then "-" elif . < 60 then "\(.) s" elif . < 3600 then "\(. / 60 | floor) min"
      elif . < 172800 then "\(. / 3600 * 10 | floor / 10) h" else "\(. / 86400 * 10 | floor / 10) days" end;
    def prs($n): if $n == 1 then "1 PR" else "\($n) PRs" end;
    def day: .[0:16] | sub("T"; " ");
    "\(.repo), last \(.days) days (since \(.since | day) UTC)",
    "  pull requests    \(.merged.total) merged: \(.merged.agent) by the agent App, \(.merged.people) by people"
      + (if .merged.otherBots > 0 then ", \(.merged.otherBots) by other bots" else "" end)
      + " (\(prs(.prs)) open in the window)",
    "  time to approve  " + (if .approve.count == 0 then "no approved PR merged"
      else "median \(.approve.median | span), 90th percentile \(.approve.p90 | span) (\(prs(.approve.count)))" end),
    "  time to merge    " + (if .merge.count == 0 then "no PR merged"
      else "median \(.merge.median | span), 90th percentile \(.merge.p90 | span) (\(prs(.merge.count)))" end),
    "  re-approvals     \(prs(.reapproved)) needed a new approval after a push",
    "  guard and checks \(prs(.failed)) had a failing run (guard \(.guardFailed), checks-<lang> \(.checksFailed)); \(.failedThenMerged) merged after a later green run",
    "  admin merges     \(.adminMerges | length) merged without an approval on the final commit",
    (.adminMerges[] | "                   #\(.number) \(.title) (merged by \(.mergedBy) \(.mergedAt | day))"),
    "  ruleset changes  " + (if (.rulesetChanges | length) == 0 then "none" else "\(.rulesetChanges | length)" end),
    (.rulesetChanges[] | "                   \(.time | day)  \(.actor)  \(.ruleset): \(.changes | join("; "))"),
    (if (.partial | length) > 0 then
       "  note             " + (.partial | map("#\(.)") | join(", ")) + " have more commits or events than were read; their numbers may be short"
     else empty end),
    ""'
}

# Runs a read-only, paginated GraphQL query and prints its --jq output. A query GitHub cannot finish in time
# comes back as an HTML error page, which gh reports as "invalid character '<' looking for beginning of
# value"; the same call is then retried after $2, 2*$2, ... seconds with a warning per failed attempt. The
# output is buffered, so a failed attempt never prints part of a list.
# Arguments: attempts, base delay in seconds, query, jq filter.
graphql_with_retry() {
  local attempts=$1 delay=$2 query=$3 filter=$4 attempt=1 out err err_file
  err_file=$(mktemp)
  while :; do
    if out=$(gh api graphql --paginate -f query="$query" --jq "$filter" 2>"$err_file"); then
      rm -f "$err_file"
      [[ -z $out ]] || printf '%s\n' "$out"
      return 0
    fi
    err=$(<"$err_file")
    err=${err//$'\n'/ }
    [[ $attempt -lt $attempts ]] || break
    printf 'warning: GitHub GraphQL query failed (attempt %d of %d, retrying in %ds): %s\n' \
      "$attempt" "$attempts" $((attempt * delay)) "$err" >&2
    sleep $((attempt * delay))
    attempt=$((attempt + 1))
  done
  rm -f "$err_file"
  die "GitHub did not answer the GraphQL query after $attempts attempts. Last error: $err"
}

# The required checks of a kit repository as ruleset entries: guard, security and each checks-<lang> job, pinned
# to GitHub Actions (integration 15368) so no other App can report them. kit_drift has made sure the security
# workflow is the kit's before the ruleset requires it. Argument: checks-<lang> job names, one per line.
pinned_checks() {
  jq -c -n --arg jobs "$1" '["guard", "security"] + ($jobs | split("\n") | map(select(length > 0)))
    | map({context: ., integration_id: 15368})'
}

# The default-branch ruleset nobody bypasses, in both modes: no deletion, no force push, linear history,
# squash-merged PRs with resolved threads, and the required checks.
# Arguments: ruleset name, required checks (JSON array of {context[, integration_id]}).
branch_ruleset() {
  jq -c -n --arg name "$1" --argjson checks "$2" '{
    name: $name, target: "branch", enforcement: "active", bypass_actors: [],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"},
      {type: "pull_request", parameters: {
        required_approving_review_count: 0, require_code_owner_review: false,
        dismiss_stale_reviews_on_push: false, require_last_push_approval: false,
        required_review_thread_resolution: true, allowed_merge_methods: ["squash"]}},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false, required_status_checks: $checks}}
    ]}'
}

# The opt-in merge queue (`guardrails on --merge-queue`) as a branch ruleset rule, with conservative settings:
# squash like every other merge here; ALLGREEN, so each PR's own commit in a group must pass every required
# check (HEADGREEN would let a failing PR in if a later one in its group passes); at most 3 PRs per group and 3
# groups building at once, so a failure costs few reruns and few CI minutes; a group merges as soon as it is
# green (minimum 1); a required check that reports nothing for 60 minutes counts as failed (the language checks
# stop at 45, security at 30).
merge_queue_rule() {
  jq -c -n '{type: "merge_queue", parameters: {
    merge_method: "SQUASH", grouping_strategy: "ALLGREEN",
    max_entries_to_build: 3, max_entries_to_merge: 3, min_entries_to_merge: 1, min_entries_to_merge_wait_minutes: 5,
    check_response_timeout_minutes: 60}}'
}

# The branch ruleset with the merge queue rule added; nobody bypasses it, so every merge goes through the queue.
# Arguments: ruleset name, required checks (JSON array).
queued_branch_ruleset() {
  branch_ruleset "$1" "$2" | jq -c --argjson queue "$(merge_queue_rule)" '.rules += [$queue]'
}

# Prints why the merge queue cannot work on a repository, nothing when it can. GitHub offers merge queues only for
# repositories an organization owns. The queue also needs review mode: in status mode the owner approves a PR's
# head with the commit status merge-approval, which the queue's group commit never carries, so every group would
# wait until its timeout. Arguments: owner/repo, the owner's account type (Organization or User), approval mode
# (review or status).
merge_queue_refusal() {
  if [[ $2 != Organization ]]; then
    printf '%s belongs to a personal account, and GitHub offers merge queues only for repositories an organization owns. Run guardrails on %s without --merge-queue (or with --no-merge-queue if it had one); nothing changed.\n' "$1" "$1"
  elif [[ $3 != review ]]; then
    printf 'the merge queue needs review mode: in status mode your approval is the commit status merge-approval on the PR head, which the queue'"'"'s group commit never carries, so the queue would wait until its timeout. Install the agent App on %s first (guardrails agent create), or run guardrails on %s --no-merge-queue; nothing changed.\n' "$1" "$1"
  fi
}

# Reads a live ruleset (or nothing) and prints "true" when it has a merge queue rule, "false" otherwise.
ruleset_has_merge_queue() {
  jq -r -s 'any(.[0].rules[]?; .type == "merge_queue")'
}

# Status mode (the agent works with the owner's login, so a GitHub review cannot express the owner's
# approval): the branch ruleset also requires the owner's commit status merge-approval on the exact HEAD.
# Arguments: ruleset name, pinned checks (JSON array).
status_mode_ruleset() {
  branch_ruleset "$1" "$(jq -c '. + [{context: "merge-approval"}]' <<<"$2")"
}

# Review mode (the agent pushes as its App's bot): a separate ruleset holds only the review rule, so the
# owner's bypass for their own PRs skips the review and nothing else (checks, history, deletion stay). It needs
# one approving review from a code owner; bots cannot be code owners. A push that changes the diff or the
# merge base dismisses it, and the last push must be approved by someone other than its pusher. Admins may
# bypass it only by merging a PR, never by pushing. Repository role 5 is "admin" (not in GitHub's docs; checked
# on a real repository: the owner's admin merge skipped the review but was refused while a check failed).
# Argument: ruleset name.
review_ruleset() {
  jq -c -n --arg name "$1" '{
    name: $name, target: "branch", enforcement: "active",
    bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [{type: "pull_request", parameters: {
      required_approving_review_count: 1, require_code_owner_review: true,
      dismiss_stale_reviews_on_push: true, require_last_push_approval: true,
      required_review_thread_resolution: true, allowed_merge_methods: ["squash"]}}]}'
}

# Prints the repository's own ruleset with the given name (GET /repos/{r}/rulesets/{id}), nothing when it has
# none. Dies when GitHub cannot be read, so a failed lookup never reads as "no ruleset". It runs inside $(...),
# where `set -e` does not apply: callers write `x=$(ruleset_by_name ...) || exit 1`. Arguments: owner/repo, name.
ruleset_by_name() {
  local repo=$1 name=$2 id
  id=$(gh api --paginate "repos/$repo/rulesets?includes_parents=false" --jq ".[] | select(.name == \"$name\") | .id") ||
    die "cannot list the rulesets of $repo"
  id=${id%%$'\n'*}
  [[ -z $id ]] || gh api "repos/$repo/rulesets/$id" || die "cannot read ruleset $name of $repo"
}

# Prints the enforcement of the repository's ruleset with the given name (active, evaluate, disabled), or
# "missing". Arguments: owner/repo, name.
ruleset_enforcement() {
  local ruleset
  ruleset=$(ruleset_by_name "$1" "$2") || exit 1
  if [[ -z $ruleset ]]; then printf 'missing\n'; else jq -r .enforcement <<<"$ruleset"; fi
}

# jq definitions shared by ruleset_approval_mode and ruleset_problems, so an approval and the inbox judge the
# same thing as protection. An active ruleset protects only the refs its target and conditions select: one whose
# conditions.ref_name was retargeted, or that excludes the default branch, still reads as active with every rule
# in place, yet no longer applies to the default branch. GitHub's documented semantics (REST "Repository
# rules", "Creating rulesets for a repository"): include accepts ref names, fnmatch patterns and the keywords
# ~DEFAULT_BRANCH and ~ALL, one of which must match; no exclude entry may match. Patterns match the full ref
# (refs/heads/<branch>, refs/tags/<tag>) with File.fnmatch: `*` and `?` never match `/`, `**/` spans
# directories, [...] is a character set that never matches `/`, a backslash does not quote and braces do not
# expand. A pattern this reading cannot translate counts as not including and as excluding, and an exclude entry is
# also read against the bare branch name: when unsure, the ruleset does not count as covering the branch. A set is
# read only when it is plain: single characters and ascending ranges, no `-` at either end of its body and no
# chained range (a-c-e), whose meaning differs between fnmatch and a regex.
#   set_regex              the input [...] token as a regex that never matches `/`, null when it is not plain
#   fnmatch_regex          the input pattern as an anchored regex, null when this reading cannot translate it
#   ref_hit($refs)         whether the input include/exclude entry matches one of $refs: true, false, or null
#                          when it cannot tell
#   covers_default($b)     the input ruleset targets branches and covers refs/heads/$b
#   protects_default($b)   the input ruleset is active and covers_default($b)
#   covers_all_tags        the input ruleset targets tags and covers every tag as tag_ruleset sets it up
#                          (include ~ALL, no exclude)
#   bypass_list            the input ruleset's bypass actors, comparable as values
#   kit_bypass($kit)       the input ruleset's bypass list is exactly $kit's (a ruleset as a builder makes it)
#   unbypassed_default($b) protects_default($b) and nobody may bypass it, as branch_ruleset sets it up
#   actor_text             one bypass actor in words: "RepositoryRole 5 (always)"
# shellcheck disable=SC2016 # jq's $variables, not the shell's
ruleset_jq_defs='
def set_regex:
  (.[1:2] | IN("!", "^")) as $negated
  | (if $negated then .[2:-1] else .[1:-1] end) as $body
  | if ($body | test("^(?:[^-]|[^-]-[^-])+$") | not) then null
    elif any($body | scan("([^-])-([^-])"); (.[0] | explode[0]) > (.[1] | explode[0])) then null
    else "(?!/)[" + (if $negated then "^" else "" end) + $body + "]" end;
def fnmatch_regex:
  if test("\\\\") then null
  else [scan("\\[[!^]?[^\\]/\\[&]+\\]|\\*\\*/|\\*+|\\?|.")] as $tokens
  | [foreach $tokens[] as $t ({start: true};
        .re = (if $t == "**/" and .start then "(?:[^/]*/)*"
               elif $t == "**/" then "[^/]*/"
               elif ($t | startswith("*")) then "[^/]*"
               elif $t == "?" then "[^/]"
               elif $t == "[" then null
               elif ($t | length) > 1 then ($t | set_regex)
               elif ($t | test("[.^$|()+{}\\]]")) then "\\" + $t
               else $t end)
        | .start = ($t | endswith("/"));
        .re)] as $parts
  | if any($parts[]; . == null) then null else "^" + ($parts | join("")) + "$" end
  end;
def ref_hit($refs):
  if IN("~ALL", "~DEFAULT_BRANCH") then true
  elif startswith("~") then null
  else fnmatch_regex as $re | if $re == null then null else any($refs[]; test($re)) end end;
def covers_default($b):
  .target == "branch"
  and any(.conditions.ref_name.include[]?; ref_hit(["refs/heads/" + $b]) == true)
  and all(.conditions.ref_name.exclude[]?; ref_hit(["refs/heads/" + $b, $b]) == false);
def protects_default($b): .enforcement == "active" and covers_default($b);
def covers_all_tags:
  .target == "tag" and any(.conditions.ref_name.include[]?; . == "~ALL")
  and (.conditions.ref_name.exclude // []) == [];
def bypass_list: [.bypass_actors[]? | {actor_id, actor_type, bypass_mode}];
def kit_bypass($kit): (bypass_list | sort) == ($kit | bypass_list | sort);
def unbypassed_default($b): protects_default($b) and kit_bypass({bypass_actors: []});
def actor_text: [.actor_type, (.actor_id // empty | tostring), "(\(.bypass_mode))"] | join(" ");
'

# Prints "review", "status" or "-": how the live rulesets of a repository expect the owner's approval. Status
# mode needs the branch ruleset agent-guardrails to be active on the default branch with nobody to bypass it and
# require merge-approval; review mode needs it the same way next to the review ruleset agent-guardrails-review, also
# on the default branch, with every review setting on and only the bypass review_ruleset sets. These are the
# invariants ruleset_problems alarms on (ruleset_jq_defs). Arguments: owner/repo, its default branch.
approval_mode() {
  local branch review
  branch=$(ruleset_by_name "$1" agent-guardrails) || exit 1
  if [[ -n $branch && $(ruleset_approval_mode "$2" <<<"$branch") == status ]]; then
    printf 'status\n'
    return 0
  fi
  review=$(ruleset_by_name "$1" agent-guardrails-review) || exit 1
  if [[ -n $branch && $(jq -r --arg b "$2" "$ruleset_jq_defs"' unbypassed_default($b)' <<<"$branch") == true &&
    -n $review && $(ruleset_approval_mode "$2" <<<"$review") == review ]]; then
    printf 'review\n'
    return 0
  fi
  printf -- '-\n'
}

# Reads a live ruleset (GET /repos/{r}/rulesets/{id}) and prints its approval mode for the default branch:
# "status" when it is active on that branch, nobody may bypass it and it requires merge-approval; "review" when it
# is an active review ruleset on that branch as review_ruleset builds it (all four review settings on, admins may
# bypass it only through a PR); "-" otherwise. A ruleset that no longer covers the default branch, or that someone
# else may bypass, protects nothing an approval is for. Argument: the default branch.
ruleset_approval_mode() {
  jq -r --arg b "$1" --argjson review_kit "$(review_ruleset agent-guardrails-review)" "$ruleset_jq_defs"'
    if protects_default($b) | not then "-"
    elif any(.rules[]; .type == "required_status_checks"
      and any(.parameters.required_status_checks[]; .context == "merge-approval"))
    then (if kit_bypass({bypass_actors: []}) then "status" else "-" end)
    elif any(.rules[]; .type == "pull_request" and .parameters.required_approving_review_count >= 1
      and .parameters.require_code_owner_review and .parameters.dismiss_stale_reviews_on_push
      and .parameters.require_last_push_approval)
    then (if kit_bypass($review_kit) then "review" else "-" end)
    else "-" end'
}

# Reads {branch, review, tag, mergeQueue, defaultBranch}: the live rulesets agent-guardrails,
# agent-guardrails-review and agent-guardrails-tags (each null when missing), whether the owner turned the merge
# queue on for the repository (true or false) and the repository's current default branch, and prints one line per
# way they no longer protect what the kit set up: inactive or missing; a branch ruleset that no longer targets
# branches or no longer covers the default branch (see ruleset_jq_defs); a tag ruleset that no longer targets every
# tag or lost its creation, update or deletion rule; a bypass list other than the one `guardrails on` applies
# (nobody on the branch ruleset, admins through a PR on the review ruleset, admins on the tag ruleset); a lost rule;
# guard, security or every checks-<lang> job not required from GitHub Actions; other merge methods; no rule left
# that requires the owner's approval (neither merge-approval nor an intact review ruleset); and a merge queue that
# is gone or no longer squashes only PRs that pass. Prints nothing when they still hold. The exact list of
# checks-<lang> jobs is not compared: it depends on the repository's languages. Fails without defaultBranch, so a
# caller that forgot it cannot read as healthy.
ruleset_problems() {
  jq -r --argjson review_kit "$(review_ruleset agent-guardrails-review)" \
    --argjson tag_kit "$(tag_ruleset agent-guardrails-tags)" "$ruleset_jq_defs"'
    def rule($r; $t): [$r.rules[]? | select(.type == $t)][0];
    def checks($r): rule($r; "required_status_checks").parameters.required_status_checks // [];
    def pinned($r; f): any(checks($r)[]; (.context | f) and .integration_id == 15368);
    def bypass_problem($r; $name; $kit):
      ($r | bypass_list) as $live | ($kit | bypass_list) as $want
      | if $r | kit_bypass($kit) then empty
        else "the \($name) ruleset has a changed bypass list ("
          + ([($live - $want)[] | "unexpected " + actor_text] + [($want - $live)[] | "missing " + actor_text]
             | join(", ")) + ")" end;
    def branch_coverage_problem($r; $name; $default):
      if $r.target != "branch" then "the \($name) ruleset targets \($r.target | tojson) instead of \"branch\""
      elif ($r | covers_default($default)) then empty
      else "the \($name) ruleset no longer covers the default branch \($default) (ref_name \($r.conditions.ref_name // null | tojson))"
      end;
    (if (.defaultBranch | type) != "string" or .defaultBranch == "" then
       error("ruleset_problems needs the default branch (defaultBranch) to tell whether the rulesets cover it")
     else . end)
    | (.branch) as $b | (.review) as $v | (.tag) as $t | (.mergeQueue) as $wanted | (.defaultBranch) as $default
    # Without the branch ruleset nothing is enforced: that one line says it all.
    | if $b == null then "the agent-guardrails ruleset is missing" else
         (if $b.enforcement != "active" then "the agent-guardrails ruleset is \($b.enforcement)" else empty end),
         branch_coverage_problem($b; "agent-guardrails"; $default),
         bypass_problem($b; "agent-guardrails"; {bypass_actors: []}),
         (["deletion", "non_fast_forward", "required_linear_history", "pull_request", "required_status_checks"][]
           | select(rule($b; .) == null) | "the agent-guardrails ruleset lost its \(.) rule"),
         (if pinned($b; . == "guard") then empty else "guard is no longer a required check from GitHub Actions" end),
         # Repositories turned on before the kit had the security check also land here until their kit update.
         (if pinned($b; . == "security") then empty else "security is not a required check from GitHub Actions (a project set up before the kit had it needs a kit update PR first)" end),
         (if pinned($b; startswith("checks-")) then empty
          else "no checks-<lang> job is a required check from GitHub Actions any more" end),
         (if (rule($b; "pull_request").parameters.allowed_merge_methods // []) == ["squash"] then empty
          else "the agent-guardrails ruleset allows merges other than squash" end),
         (rule($b; "merge_queue") as $q
          | if $wanted != true then empty
            elif $q == null then "the merge queue is gone from the agent-guardrails ruleset, so PRs merge without being checked together"
            elif $q.parameters.merge_method != "SQUASH" or $q.parameters.grouping_strategy != "ALLGREEN"
            then "the merge queue no longer squashes only PRs that pass every check (merge method or grouping changed)"
            else empty end),
      (if any(checks($b)[]; .context == "merge-approval") then empty
       elif $v == null then "no ruleset requires your approval any more (neither merge-approval nor agent-guardrails-review)"
       else
         (if $v.enforcement != "active" then "the agent-guardrails-review ruleset is \($v.enforcement)" else empty end),
         branch_coverage_problem($v; "agent-guardrails-review"; $default),
         bypass_problem($v; "agent-guardrails-review"; $review_kit),
         (rule($v; "pull_request").parameters as $p
          | if ($p.required_approving_review_count // 0) >= 1 and $p.require_code_owner_review
              and $p.dismiss_stale_reviews_on_push and $p.require_last_push_approval then empty
            else "the agent-guardrails-review ruleset no longer requires a fresh code owner review" end)
       end),
      (if $t == null then "the agent-guardrails-tags ruleset is missing" else
         (if $t.enforcement != "active" then "the agent-guardrails-tags ruleset is \($t.enforcement)" else empty end),
         (if $t.target != "tag" then "the agent-guardrails-tags ruleset targets \($t.target | tojson) instead of \"tag\""
          elif ($t | covers_all_tags) then empty
          else "the agent-guardrails-tags ruleset no longer covers every tag (ref_name \($t.conditions.ref_name // null | tojson); the kit includes ~ALL and excludes nothing)"
          end),
         ($tag_kit.rules[].type | select(rule($t; .) == null) | "the agent-guardrails-tags ruleset lost its \(.) rule"),
         bypass_problem($t; "agent-guardrails-tags"; $tag_kit)
       end)
      end'
}

# Tags are created, moved and deleted by repository admins only, so a release workflow cannot be triggered by
# a tag the agent's bot made. In status mode the agent uses the owner's admin login, so this holds only for
# other writers there. Argument: ruleset name.
tag_ruleset() {
  jq -c -n --arg name "$1" '{
    name: $name, target: "tag", enforcement: "active",
    bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
    conditions: {ref_name: {include: ["~ALL"], exclude: []}},
    rules: [{type: "creation"}, {type: "update"}, {type: "deletion"}]}'
}

# Prints one line per problem with a checkout's CODEOWNERS for review mode, nothing when it is usable. GitHub
# uses the first of .github/CODEOWNERS, CODEOWNERS and docs/CODEOWNERS. Its first rule must be `*` owned by
# the given login (so every path has a human code owner), and every rule must name at least one owner (a rule
# without owners leaves its paths without a code owner). Owners are @user, @org/team or an email address;
# anything from a field starting with # is a comment, and `\ ` is an escaped space inside a pattern. Whether
# the owners exist and can write is GitHub's check (GET /repos/{r}/codeowners/errors), not this one's.
# Arguments: checkout directory, owner login.
codeowners_problems() {
  local dir=$1 login=$2 file="" candidate
  for candidate in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    if [[ -f $dir/$candidate ]]; then
      file=$candidate
      break
    fi
  done
  if [[ -z $file ]]; then
    printf 'no CODEOWNERS file; add .github/CODEOWNERS whose first line is: * @%s\n' "$login"
    return 0
  fi
  tr -d '\r' <"$dir/$file" | awk -v file="$file" -v login="@$(tr '[:upper:]' '[:lower:]' <<<"$login")" '
    {
      gsub(/\\ /, "\001")
      n = 0; owners = ""; mine = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^#/) break
        n++
        if (n == 1) { pattern = $i; continue }
        if ($i ~ /^@[^@]+$/ || $i ~ /^[^@]+@[^@]+$/) { owners = owners " " $i; if (tolower($i) == login) mine = 1 }
      }
      if (n == 0) next
      gsub(/\001/, "\\ ", pattern)
      rules++
      if (rules == 1 && (pattern != "*" || !mine))
        printf "%s: the first rule must be \"* %s\" (found \"%s%s\")\n", file, login, pattern, owners
      if (owners == "") printf "%s: \"%s\" names no owner, so its paths need no code owner review\n", file, pattern
    }
    END { if (rules == 0) printf "%s: no rules; its first line must be \"* %s\"\n", file, login }'
}

# Asks for a typed confirmation on the terminal (never stdin, which a caller could pipe) and dies unless it is
# exactly the expected text. Announces the step to the app first. Arguments: step, expected text, prompt.
confirm() {
  local step=$1 expected=$2 prompt=$3 typed
  emit_event "$(jq -n -c --arg step "$step" --arg expect "$expected" '{event: "confirm", step: $step, expect: $expect}')"
  read -r -p "$prompt" typed </dev/tty
  [[ $typed == "$expected" ]] || die "confirmation did not match; nothing changed"
}

# Prints a file of the kit install at a commit, or "unknown" when that commit has no such file.
kit_file_at() {
  kit_git show "$1:$2" 2>/dev/null || printf 'unknown\n'
}

# Prints the kit checkout whose bash-guard the owner's Claude Code settings run (the active install), nothing
# when no settings register it.
active_install() {
  local settings="$HOME/.claude/settings.json" guard
  [[ -f $settings ]] || return 0
  guard=$(jq -r '[.. | .command? // empty | strings | select(endswith("/hooks-global/bash-guard.sh"))][0] // empty' "$settings") ||
    die "cannot read $settings"
  [[ -z $guard ]] || printf '%s\n' "${guard%/hooks-global/bash-guard.sh}"
}

# Fast-forwards the kit install to its origin's main after the owner confirms the exact new commit, then runs
# install.sh again and, on macOS with the app installed, rebuilds the app. Refuses local changes, a branch
# other than main, and an origin main that does not contain the installed commit.
kit_update() {
  local origin current target commits from_version to_version active
  # Only the active install may update: install.sh moves every link and hook to the clone it runs from, and a
  # test build of the app once updated a scratch clone that way, leaving the owner's commands and hooks in it.
  active=$(active_install)
  [[ -z $active || $active == "$kit" ]] ||
    die "the active kit install is $active (its bash-guard runs in Claude Code), not $kit; update that one: $active/bin/guardrails update"
  [[ -z $(kit_local_changes) ]] ||
    die "the kit install at $kit has local changes, so it cannot be fast-forwarded. Inspect them with: git -C $kit status"
  [[ $(kit_git symbolic-ref --quiet --short HEAD) == main ]] ||
    die "the kit install at $kit is not on main. Switch it with: git -C $kit switch main"
  origin=$(kit_origin)
  kit_remote_git fetch --quiet "$origin" main || die "cannot fetch main from $origin"
  current=$(kit_git rev-parse HEAD)
  target=$(kit_git rev-parse FETCH_HEAD)
  if [[ $current == "$target" ]]; then
    printf 'the kit install is up to date (%s)\n' "${current:0:7}"
    return 0
  fi
  kit_git merge-base --is-ancestor "$current" "$target" ||
    die "main of the kit origin does not contain the installed commit ${current:0:7}; inspect it before updating"
  # Commit subjects come from the kit repository, where agents work too: no control characters reach the terminal.
  commits=$(kit_git log --format='%h %s' "$current..$target" | LC_ALL=C tr -d '\000-\010\013-\037\177')
  from_version=$(kit_file_at "$current" VERSION)
  to_version=$(kit_file_at "$target" VERSION)
  printf '\nUpdate the kit install at %s\nfrom %s (version %s) to %s (version %s):\n%s\n\n' "$kit" \
    "${current:0:7}" "$from_version" "${target:0:7}" "$to_version" "  ${commits//$'\n'/$'\n'  }"
  emit_event "$(jq -n -c --arg from "$current" --arg to "$target" \
    --arg fromVersion "$from_version" --arg toVersion "$to_version" --arg commits "$commits" \
    '{event: "plan", action: "update", from: $from, to: $to, fromVersion: $fromVersion, toVersion: $toVersion,
      commits: ($commits | split("\n") | map(select(length > 0)))}')"
  confirm commit "${target:0:7}" "Type ${target:0:7} to update the kit install to exactly this commit: "
  kit_git merge --quiet --ff-only "$target"
  "$kit/install.sh"
  if [[ $(uname) == Darwin && -d $HOME/Applications/Guardrails.app ]]; then
    "$kit/app/build.sh"
  fi
  printf 'updated the kit install to %s (version %s)\n' "${target:0:7}" "$to_version"
}
