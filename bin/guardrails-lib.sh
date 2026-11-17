# shellcheck shell=bash
# Shared by bin/guardrails and its tests. Source it after lib.sh; do not execute it.
# Functions that only read or change a local checkout are kept free of GitHub calls so tests can run offline.

# shellcheck disable=SC2154 # kit is set by the sourcing script
template="$kit/skills/guardrails-init/template"

# Prints every way the kit-owned files of a checkout differ from the installed kit's template, one per line.
# Nothing printed means the checkout carries exactly this kit: .agent/, .claude/settings.json, the guard
# workflow and each checks-<lang> workflow. The Makefile and AGENTS.md hold project judgment and are not compared.
kit_drift() {
  local dir=$1 workflow name
  [[ -d "$dir/.agent" ]] || {
    printf 'missing: .agent/\n'
    return 0
  }
  diff -rq "$template/.agent" "$dir/.agent" | sed -E \
    -e "s#^Files $template/(.*) and .* differ\$#differs from the kit: \\1#" \
    -e "s#^Only in $template/(.*): (.*)\$#missing: \\1/\\2#" \
    -e "s#^Only in $dir/(.*): (.*)\$#not in the kit: \\1/\\2#" || true
  # diff and cmp follow symlinks and ignore modes, so check both separately.
  find "$dir/.agent" "$dir/.claude" "$dir/.github" -type l 2>/dev/null | sed "s#^$dir/#symlink not allowed: #"
  (cd "$template" && find .agent -type f) | while IFS= read -r file; do
    [[ -f "$dir/$file" && ! -L "$dir/$file" ]] || continue
    if [[ -x "$template/$file" && ! -x "$dir/$file" ]] || [[ ! -x "$template/$file" && -x "$dir/$file" ]]; then
      printf 'file mode differs from the kit: %s\n' "$file"
    fi
  done
  cmp -s "$template/.claude/settings.json" "$dir/.claude/settings.json" ||
    printf 'differs or missing: .claude/settings.json\n'
  cmp -s "$template/.github/workflows/agent-guard.yml" "$dir/.github/workflows/agent-guard.yml" ||
    printf 'differs or missing: .github/workflows/agent-guard.yml\n'
  local found=0
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    found=1
    name=${workflow##*/}
    cmp -s "$template/ci/$name" "$workflow" || printf 'differs from the kit: .github/workflows/%s\n' "$name"
  done
  [[ $found -eq 1 ]] || printf 'missing: .github/workflows/checks-<lang>.yml\n'
}

# Git on the kit install without the repository settings that run programs (fsmonitor, hooks, pager), so
# checking the install cannot itself execute code someone left in its .git/config.
kit_git() {
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -C "$kit" "$@"
}

# Prints the kit install's local changes, one per line: edits and untracked files (whatever the repository
# config says about showing them) and files git was told to stop looking at (assume-unchanged, skip-worktree).
kit_local_changes() {
  kit_git status --porcelain --untracked-files=all
  kit_git ls-files -v | awk '$1 != "H" { sub(/^[^ ]+ /, ""); print "not watched by git: " $0 }'
}

# Dies unless the kit install is exactly the reviewed main of its origin: no local changes, HEAD equal to
# origin's main. The owner's commands and the template they compare against come from this checkout, so
# a change an agent made there must not silently become the reference.
require_reviewed_kit() {
  local local_sha remote_sha origin
  origin=$(kit_git remote get-url origin)
  [[ -z $(kit_local_changes) ]] ||
    die "the kit install at $kit has local changes, so this command may not be the reviewed one. Inspect them with: git -C $kit status"
  local_sha=$(kit_git rev-parse HEAD)
  remote_sha=$(kit_git ls-remote origin refs/heads/main | cut -f1) ||
    die "could not reach $origin to confirm the kit install is its reviewed main"
  [[ -n $remote_sha ]] || die "$origin has no main branch"
  [[ $local_sha == "$remote_sha" ]] ||
    die "the kit install at $kit is at ${local_sha:0:7}, not at main of $origin (${remote_sha:0:7}). Update it with: git -C $kit switch main && git -C $kit pull --ff-only"
}

# Prints the files a PR changes, one per line; dies when GitHub cannot list them or when a file name holds a
# control character. Names are written by the agent, and a newline or escape sequence in one could forge
# lines of the review the owner reads (or a confirmation prompt the app answers).
pr_files() {
  local files unsafe
  files=$(gh api --paginate "repos/$1/pulls/$2/files?per_page=100" \
    --jq '.[].filename | if test("[[:cntrl:]]") then "control-character " + gsub("[[:cntrl:]]"; "?") else . end')
  [[ -n $files ]] || die "could not list the files of PR #$2 in $1"
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
  rm -f "$dir/.github/workflows/agent-guard.yml"
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

# Reads `gh pr list --json number,title,url,isDraft,headRefOid,labels,statusCheckRollup,reviewDecision
# [,author,updatedAt]` on stdin and prints one compact JSON object per PR: {number, url, title, kind, note, sha,
# draft, author, updated}. Kinds: answer (the agent asked a question: label needs-decision), draft (the agent's
# work in progress), approved (HEAD approved by merge-approval in status mode, or by the required review in
# review mode, where GitHub dismisses the review when a push changes the PR), wait (guard running), blocked (guard failed), approve (guard passed,
# HEAD not approved yet). Any failed run named guard wins over a later success, because a workflow added by
# the PR could report a run of that name (approve-head checks the real guard run). Titles are written by
# the agent, so control characters are replaced before they reach a terminal or the app.
pr_states() {
  jq -c '
    def latest(f): [.statusCheckRollup[]? | select(f)] | sort_by(.startedAt // .createdAt // "") | last;
    def clean: gsub("[[:cntrl:]]"; "?");
    .[]
    | .title |= clean
    | (latest(.__typename == "CheckRun" and .name == "guard")) as $latest_guard
    | (if any(.statusCheckRollup[]?; .__typename == "CheckRun" and .name == "guard" and .status == "COMPLETED"
           and (.conclusion | IN("SUCCESS", "CANCELLED", "SKIPPED", "NEUTRAL") | not))
       then {status: "COMPLETED", conclusion: "FAILURE"} else $latest_guard end) as $guard
    | (latest(.__typename == "StatusContext" and .context == "merge-approval")) as $approval
    | ([.statusCheckRollup[]? | select(.__typename == "CheckRun" and (.name | startswith("checks-")))]) as $checks
    | (if ($checks | length) == 0 then "checks not started"
       elif any($checks[]; .status != "COMPLETED") then "checks running"
       elif all($checks[]; .conclusion == "SUCCESS") then "checks green"
       else "checks failing" end) as $checks_note
    | (if any(.labels[]?; .name == "needs-decision") then ["answer", "the agent is waiting for your decision"]
       elif .isDraft then ["draft", "the agent is working on it"]
       elif ($approval.state // "") == "SUCCESS" or .reviewDecision == "APPROVED" then ["approved", "approved; merges when checks pass"]
       elif $guard == null or $guard.status != "COMPLETED" then ["wait", "guard is running"]
       elif $guard.conclusion != "SUCCESS" then ["blocked", "guard failed: the agent has to fix the PR"]
       else ["approve", $checks_note] end) as $state
    | {number, url, title, kind: $state[0], note: $state[1], sha: (.headRefOid // ""), draft: .isDraft,
       author: ((.author.login // "") | clean), updated: (.updatedAt // "")}'
}

# Reads the same input as pr_states and prints one tab-separated line per PR that needs the owner:
# "<kind>\t<url>\t<title>\t<note>" for answer, approve, wait and blocked. Drafts and approved PRs are left out.
classify_prs() {
  pr_states | jq -r 'select(.kind | IN("answer", "approve", "wait", "blocked")) | [.kind, .url, .title, .note] | @tsv'
}

# Reads the nodes of the owner's repositories (GraphQL, see `guardrails projects`) and prints one compact
# JSON object per repo with its state for the app:
#   on        listed on this Mac and its agent-guardrails ruleset is active
#   alarm     listed but the ruleset is not active, or tagged with the topic but not listed
#   ready     an open /guardrails-init PR from this repo (not a fork), authored by the owner
#   no-admin  the owner cannot apply rulesets here
#   off       none of the above
# mode is "review" for an enforced repo whose agent-guardrails-review ruleset is active, "status" for another
# enforced repo, null otherwise. agentApp is "installed" or "missing" for the agent App on this Mac, "none" when
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
    | (if $registered and $ruleset == "active" then ["on", "ruleset active"]
       elif $registered then ["alarm", "ruleset \($ruleset): restore it or check the audit log"]
       elif $tagged then ["alarm", "tagged agent-guardrails but not in this Mac'"'"'s list"]
       elif $ruleset == "active" then ["alarm", "agent-guardrails ruleset active but not in this Mac'"'"'s list"]
       elif .viewerPermission != "ADMIN" then ["no-admin", "you cannot apply rulesets here"]
       elif $bootstrap != null then ["ready", "set-up PR open"]
       else ["off", ""] end) as $state
    | {repo: .nameWithOwner, state: $state[0], note: $state[1], private: .isPrivate, fork: .isFork,
       branch: (.defaultBranchRef.name // ""), pushed: (.pushedAt // ""), openPRs: .pullRequests.totalCount,
       setupURL: ($bootstrap.url // ""), setupTitle: (($bootstrap.title // "") | clean),
       mode: (if $state[0] != "on" then null
              elif any(.rulesets.nodes[]?; .name == "agent-guardrails-review" and (.enforcement | ascii_downcase) == "active")
              then "review" else "status" end),
       agentApp: (if $app != "registered" then "none" elif ($agent_repos | index($key)) != null then "installed"
                  else "missing" end)}'
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

# The required checks of a kit repository as ruleset entries: guard and each checks-<lang> job, pinned to
# GitHub Actions (integration 15368) so no other App can report them. Argument: job names, one per line.
pinned_checks() {
  jq -c -n --arg jobs "$1" '["guard"] + ($jobs | split("\n") | map(select(length > 0)))
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

# Reads a live ruleset (GET /repos/{r}/rulesets/{id}) and prints its approval mode for the default branch:
# "status" when it is active and requires merge-approval, "review" when it is an active review ruleset as
# review_ruleset builds it (all four review settings on), "-" otherwise.
ruleset_approval_mode() {
  jq -r 'if .enforcement != "active" then "-"
    elif any(.rules[]; .type == "required_status_checks"
      and any(.parameters.required_status_checks[]; .context == "merge-approval")) then "status"
    elif any(.rules[]; .type == "pull_request" and .parameters.required_approving_review_count >= 1
      and .parameters.require_code_owner_review and .parameters.dismiss_stale_reviews_on_push
      and .parameters.require_last_push_approval) then "review"
    else "-" end'
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
