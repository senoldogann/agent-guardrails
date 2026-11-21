#!/usr/bin/env bash
# Offline tests for bin/guardrails-lib.sh (kit drift, kit removal, inbox classification) and the project
# bash-guard shim that guards teammates' agents. GitHub calls of bin/guardrails are covered by the
# end-to-end runs on real repositories.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$kit/bin/guardrails-lib.sh"
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

# A project as /guardrails-init leaves it: template files, a language Makefile, AGENTS.md with the section.
new_project() {
  local dir="$work/$1"
  mkdir -p "$dir/.github/workflows" "$dir/.claude" "$dir/.cursor" "$dir/specs/ABC-1" "$dir/src"
  cp -R "$template/.agent" "$dir/.agent"
  cp "$template/.claude/settings.json" "$dir/.claude/settings.json"
  cp "$template/.cursor/hooks.json" "$dir/.cursor/hooks.json"
  cp "$template/.github/workflows/agent-guard.yml" "$template/.github/workflows/security.yml" "$dir/.github/workflows/"
  cp "$template/.github/workflows/agent-notify.yml" "$dir/.github/workflows/"
  cp "$template/ci/checks-node.yml" "$dir/.github/workflows/"
  cp "$template/makefiles/Makefile.typescript" "$dir/Makefile"
  printf 'name: other\n' >"$dir/.github/workflows/release.yml"
  printf 'spec\n' >"$dir/specs/ABC-1/acceptance-criteria.md"
  printf 'code\n' >"$dir/src/index.ts"
  {
    printf '# shop\n\nSetup: pnpm install\n\n'
    cat "$template/AGENTS.section.md"
  } >"$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

echo "workflow templates on merge groups"
# Every required check must also report on a merge queue's group commit, or the queue waits until its timeout.
for workflow in "$template"/ci/checks-*.yml "$template/.github/workflows/security.yml" "$template/.github/workflows/agent-guard.yml"; do
  name=${workflow##*/}
  if grep -Fx '  merge_group:' "$workflow" >/dev/null && grep -Fx '    types: [checks_requested]' "$workflow" >/dev/null &&
    grep -F 'github.event.merge_group.head_ref }}' "$workflow" >/dev/null; then
    ok
  else
    fail "$name runs on merge groups with a concurrency group per group"
  fi
done
for workflow in "$template"/ci/checks-*.yml "$template/.github/workflows/security.yml"; do
  # shellcheck disable=SC2016 # a workflow expression, not the shell's
  grep -F 'ref: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha }}' "$workflow" >/dev/null ||
    fail "${workflow##*/} checks out the group commit on merge_group"
done
for workflow in "$template"/ci/checks-*.yml; do
  expect_eq "${workflow##*/} runs the full gate on a group commit" \
    "$(grep -A1 -F "if: github.event_name == 'merge_group'" "$workflow" | tail -1)" "        run: make check"
done
guard_workflow="$template/.github/workflows/agent-guard.yml"
# shellcheck disable=SC2016 # workflow expressions and the step's own shell variables, not this shell's
expect_eq "the guard checks out the default branch on merge_group, never the group's commit" \
  "$(grep -A4 -F "name: Check out the default branch (merge group)" "$guard_workflow" | grep -F 'ref:' | tr -s ' ')" \
  ' ref: refs/heads/${{ github.event.repository.default_branch }}'
# shellcheck disable=SC2016 # the step's own shell variables
expect_eq "the guard judges a group with the default branch's ci-guard-group" \
  "$(grep -c -F '.agent/bin/ci-guard-group "$GITHUB_EVENT_PATH" | tee guard.txt' "$guard_workflow")" "1"

echo "kit_drift"
project=$(new_project drift)
expect_eq "fresh install has no drift" "$(kit_drift "$project")" ""
printf '# extra\n' >>"$project/.agent/bin/ci-guard"
expect_eq "edited kit script is drift" "$(kit_drift "$project")" "differs from the kit: .agent/bin/ci-guard"
project=$(new_project drift2)
printf 'x\n' >"$project/.agent/bin/extra"
expect_eq "added kit file is drift" "$(kit_drift "$project")" "not in the kit: .agent/bin/extra"
project=$(new_project drift3)
printf '#\n' >>"$project/.github/workflows/agent-guard.yml"
printf '#\n' >>"$project/.github/workflows/checks-node.yml"
printf '#\n' >>"$project/.github/workflows/security.yml"
expect_eq "edited workflows are drift" "$(kit_drift "$project")" "differs or missing: .github/workflows/agent-guard.yml
differs or missing: .github/workflows/security.yml
differs from the kit: .github/workflows/checks-node.yml"
project=$(new_project drift3b)
rm "$project/.github/workflows/security.yml"
printf 'semgrep rule src/a.ts # accepted by the owner\n' >"$project/.github/security-ignore"
expect_eq "missing security workflow is drift; the project's ignore file is not" "$(kit_drift "$project")" \
  "differs or missing: .github/workflows/security.yml"
project=$(new_project drift-notify)
# The notification workflow holds the webhook secrets: pointing it elsewhere, or dropping it, is drift.
sed 's/GUARDRAILS_SLACK_WEBHOOK }}/OTHER_WEBHOOK }}/' "$template/.github/workflows/agent-notify.yml" \
  >"$project/.github/workflows/agent-notify.yml"
expect_eq "edited notify workflow is drift" "$(kit_drift "$project")" "differs or missing: .github/workflows/agent-notify.yml"
rm "$project/.github/workflows/agent-notify.yml"
expect_eq "missing notify workflow is drift" "$(kit_drift "$project")" "differs or missing: .github/workflows/agent-notify.yml"
printf '# extra\n' >>"$project/.agent/bin/notify-team"
cp "$template/.github/workflows/agent-notify.yml" "$project/.github/workflows/"
expect_eq "edited notify script is drift" "$(kit_drift "$project")" "differs from the kit: .agent/bin/notify-team"
project=$(new_project drift4)
rm "$project/.github/workflows/checks-node.yml"
expect_eq "missing checks workflow is drift" "$(kit_drift "$project")" "missing: .github/workflows/checks-<lang>.yml"
project=$(new_project drift5)
chmod -x "$project/.agent/bin/ci-guard"
expect_eq "lost executable bit is drift" "$(kit_drift "$project")" "file mode differs from the kit: .agent/bin/ci-guard"
project=$(new_project drift6)
mkdir -p "$project/scripts"
mv "$project/.agent/bin/ci-guard" "$project/scripts/guard"
ln -s ../../scripts/guard "$project/.agent/bin/ci-guard"
expect_eq "symlinked kit file is drift" "$(kit_drift "$project")" "symlink not allowed: .agent/bin/ci-guard"
project=$(new_project drift7)
printf '{"version": 1, "hooks": {}}\n' >"$project/.cursor/hooks.json"
expect_eq "edited Cursor hooks are drift" "$(kit_drift "$project")" "differs or missing: .cursor/hooks.json"
project=$(new_project drift8)
rm "$project/.cursor/hooks.json"
ln -s ../.claude/settings.json "$project/.cursor/hooks.json"
expect_eq "symlinked Cursor hooks are drift" "$(kit_drift "$project")" "symlink not allowed: .cursor/hooks.json
differs or missing: .cursor/hooks.json"
project=$(new_project drift9)
ln -s ../shared/rules "$project/.cursor/rules"
expect_eq "linked Cursor rules are the project's own" "$(kit_drift "$project")" ""
expect_eq "check jobs come from the checks workflows only (notify is never required)" "$(check_jobs "$(new_project jobs)")" "checks-node"

echo "remove_kit_files"
# Commits a project as a clone of it has it: remove_kit_files stages the removal in the index and leaves the working
# tree alone.
committed() {
  git -C "$1" init -q -b main
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m project
}
project=$(new_project remove)
printf 'semgrep rule src/a.ts # accepted by the owner\n' >"$project/.github/security-ignore"
committed "$project"
notes=$(remove_kit_files "$project")
expect_eq "only specs is noted" "$notes" "kept (decided requirements stay as documentation): specs/"
expect_eq "files left" "$(git -C "$project" ls-files)" ".github/workflows/release.yml
AGENTS.md
specs/ABC-1/acceptance-criteria.md
src/index.ts"
expect_eq "AGENTS.md keeps the project part" "$(git -C "$project" show :AGENTS.md)" "# shop

Setup: pnpm install"
expect_eq "the working tree is left alone" "$(cd "$project" && find .agent/bin/ci-guard Makefile -type f)" ".agent/bin/ci-guard
Makefile"

project=$(new_project legacy)
{
  printf '# shop\n\n'
  sed '/agent-guardrails:start/d; /agent-guardrails:end/d' "$template/AGENTS.section.md"
  printf '\n## Deploy\n\nmake deploy\n'
} >"$project/AGENTS.md"
printf 'deploy:\n\t./deploy.sh\n' >>"$project/Makefile"
printf '{"hooks": {}}\n' >"$project/.claude/settings.json"
printf '{"version": 1, "hooks": {}}\n' >"$project/.cursor/hooks.json"
committed "$project"
notes=$(remove_kit_files "$project")
expect_eq "legacy section removed up to the next heading" "$(git -C "$project" show :AGENTS.md)" "# shop

## Deploy

make deploy"
expect_eq "customised files are kept and noted" "$notes" "kept (differs from the kit, remove the kit hooks by hand): .claude/settings.json
kept (differs from the kit, remove the kit hooks by hand): .cursor/hooks.json
edited (kit include removed; targets that called .agent/ scripts need a look): Makefile
kept (decided requirements stay as documentation): specs/"
expect_eq "the Makefile keeps its own targets" "$(git -C "$project" show :Makefile | tail -2)" "deploy:
	./deploy.sh"
if git -C "$project" show :Makefile | grep -F 'include .agent/common.mk' >/dev/null; then
  fail "kit include left in Makefile"
else
  ok
fi

# The removal plan is prepared before the owner confirms it, from a clone of a repository the agent writes to:
# symbolic links where it reads and writes, into a directory outside the checkout, must not be followed. The old code
# read and rewrote AGENTS.md through its link, wrote AGENTS.md.tmp and Makefile.tmp through theirs, and deleted a
# kit-identical settings.json behind a linked .claude.
outside="$work/outside"
mkdir -p "$outside/claude"
{
  printf '# outside\n\n'
  cat "$template/AGENTS.section.md"
} >"$outside/agents.md"
cp "$template/.claude/settings.json" "$outside/claude/settings.json"
printf 'sentinel\n' >"$outside/sentinel"
project=$(new_project links)
rm "$project/AGENTS.md"
rm -r "$project/.claude"
ln -s "$outside/agents.md" "$project/AGENTS.md"
ln -s "$outside/claude" "$project/.claude"
ln -s "$outside/sentinel" "$project/AGENTS.md.tmp"
ln -s "$outside/sentinel" "$project/Makefile.tmp"
printf 'deploy:\n\t./deploy.sh\n' >>"$project/Makefile"
committed "$project"
outside_files() { (cd "$outside" && find . -type f -exec shasum {} + | sort); }
before=$(outside_files)
notes=$(remove_kit_files "$project")
expect_eq "nothing outside the checkout changes" "$(outside_files)" "$before"
expect_eq "linked files are noted, not followed" "$notes" "kept (a symbolic link or other non-directory, not followed; remove the kit hooks by hand): .claude
edited (kit include removed; targets that called .agent/ scripts need a look): Makefile
kept (a symbolic link or other non-file, not followed; remove the kit section by hand): AGENTS.md
kept (decided requirements stay as documentation): specs/"
expect_eq "the links stay links" "$(git -C "$project" ls-files -s -- .claude AGENTS.md AGENTS.md.tmp Makefile.tmp | cut -d' ' -f1 | sort -u)" \
  "120000"
expect_eq "the kit files still go" "$(git -C "$project" ls-files -- .agent .github/workflows/agent-guard.yml)" ""

# Pathspec settings in the environment would make the removal's pathspecs literal or case-blind and leave the kit in
# place without an error.
project=$(new_project pathspecs)
committed "$project"
notes=$(GIT_LITERAL_PATHSPECS=1 GIT_ICASE_PATHSPECS=1 remove_kit_files "$project")
expect_eq "pathspec settings in the environment change nothing" "$(git -C "$project" ls-files)" ".github/workflows/release.yml
AGENTS.md
specs/ABC-1/acceptance-criteria.md
src/index.ts"

echo "workflow_token_problems"
# The owner's side runs the same check.py as ci-guard. Every spelling YAML gives a grant is refused, and so is
# YAML the check does not read; read access, comments and look-alike keys are not.
token_problems() { printf 'on: pull_request\n%b\n' "$1" | workflow_token_problems; }
while IFS= read -r spelling; do
  if [[ -n $(token_problems "$spelling") ]]; then ok; else fail "missed a grant: $spelling"; fi
done <<'EOF'
permissions:\n  checks: write
permissions:\n  statuses: "write"
permissions:\n  checks: 'write'
permissions:\n  statuses: "wr\\x69te"
permissions:\n  statuses: "wr\\\n    ite"
permissions:\n  Statuses: WRITE
permissions:\n  statuses:\n    write
permissions:\n  statuses: >-\n    write
permissions: {statuses: write, contents: read}
permissions:\n  "checks": write
permissions: "write-all"
permissions: "wr\\x69te-all"
jobs:\n  lint:\n    permissions: write-all\n    runs-on: ubuntu-latest
permissions:\n  statuses: !!str write
permissions:\n  contents: read\n  contents: write
permissions: &read\n  checks: read
permissions:\n  checks: read\njobs:\n  lint:\n    permissions: {<<: {checks: write}}
permissions:\n  statuses: maybe
EOF
while IFS= read -r spelling; do
  if [[ -z $(token_problems "$spelling") ]]; then ok; else fail "false grant: $spelling"; fi
done <<'EOF'
permissions:\n  checks: read
permissions:\n  statuses: none
permissions:\n  contents: write
permissions: read-all
permissions: {}
permissions:\n  contents: read\n  # statuses: write
jobs:\n  checks:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm run write-docs
EOF
for workflow in "$template"/.github/workflows/*.yml "$template"/ci/*.yml; do
  expect_eq "the kit's ${workflow##*/} passes" "$(workflow_token_problems <"$workflow")" ""
done
# A bootstrap checkout's workflows are all checked, dot-named ones included.
checkout="$work/status-rights"
mkdir -p "$checkout/.github/workflows"
cp "$template"/.github/workflows/*.yml "$template"/ci/checks-node.yml "$checkout/.github/workflows/"
if (require_no_status_rights "$checkout") >/dev/null 2>&1; then ok; else fail "the kit's workflows refused"; fi
printf 'on: pull_request\npermissions: write-all\njobs: {}\n' >"$checkout/.github/workflows/.hidden.yml"
if (require_no_status_rights "$checkout") >/dev/null 2>&1; then fail "a dot-named workflow was skipped"; else ok; fi
# File names cannot change the contents API request.
expect_eq "contents path is encoded per segment" "$(contents_api_path '.github/workflows/x?ref=other&z#.yml')" \
  ".github/workflows/x%3Fref%3Dother%26z%23.yml"
expect_eq "a plain contents path is unchanged" "$(contents_api_path .github/workflows/ci.yml)" ".github/workflows/ci.yml"

echo "classify_prs"
fixture='[
 {"url":"u1","title":"spec(A-1): x","isDraft":true,"labels":[{"name":"needs-decision"}],"statusCheckRollup":[]},
 {"url":"u2","title":"spec(A-2): wip","isDraft":true,"labels":[],"statusCheckRollup":[]},
 {"url":"u3","title":"feat(A-3): ready","isDraft":false,"headRefOid":"abc123","labels":[],"statusCheckRollup":[
   {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"},
   {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"CheckRun","name":"checks-node","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-01-02T00:00:00Z"}]},
 {"url":"u4","title":"feat(A-4): approved","isDraft":false,"labels":[],"statusCheckRollup":[
   {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"StatusContext","context":"merge-approval","state":"SUCCESS","createdAt":"2026-01-02T00:00:00Z"}]},
 {"url":"u5","title":"feat(A-5): bad","isDraft":false,"labels":[],"statusCheckRollup":[
   {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-02T00:00:00Z"}]},
 {"url":"u6","title":"feat(A-6): new","isDraft":false,"labels":[],"statusCheckRollup":[]},
 {"url":"u7","title":"feat(A-7): revoked","isDraft":false,"labels":[],"statusCheckRollup":[
   {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"CheckRun","name":"checks-node","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"CheckRun","name":"security","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"StatusContext","context":"merge-approval","state":"FAILURE","createdAt":"2026-01-02T00:00:00Z"}]},
 {"url":"u8","title":"feat(A-8): leak","isDraft":false,"labels":[],"statusCheckRollup":[
   {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"CheckRun","name":"checks-node","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
   {"__typename":"CheckRun","name":"security","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-02T00:00:00Z"}]}
]'
tab=$'\t'
expect_eq "inbox items" "$(classify_prs "[]" <<<"$fixture")" "answer${tab}u1${tab}spec(A-1): x${tab}the agent is waiting for your decision${tab}
approve${tab}u3${tab}feat(A-3): ready${tab}checks running${tab}abc123
blocked${tab}u5${tab}feat(A-5): bad${tab}guard failed: the agent has to fix the PR${tab}
wait${tab}u6${tab}feat(A-6): new${tab}guard is running${tab}
approve${tab}u7${tab}feat(A-7): revoked${tab}checks green${tab}
approve${tab}u8${tab}feat(A-8): leak${tab}checks failing${tab}"

# A check that ran again counts by its newest run, as GitHub counts a required check.
rerun='[{"url":"u9","title":"feat(A-9): rerun","isDraft":false,"labels":[],"statusCheckRollup":[
  {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"},
  {"__typename":"CheckRun","name":"checks-node","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-02T00:00:00Z"},
  {"__typename":"CheckRun","name":"checks-node","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:05:00Z"},
  {"__typename":"CheckRun","name":"security","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z"}]}]'
expect_eq "a check that passed on its rerun is green" "$(pr_states "[]" <<<"$rerun" | jq -r .note)" "checks green"
expect_eq "a check that failed on its rerun is failing" \
  "$(jq -c '.[0].statusCheckRollup[1].conclusion = "SUCCESS" | .[0].statusCheckRollup[2].conclusion = "FAILURE"' <<<"$rerun" |
    pr_states "[]" | jq -r .note)" "checks failing"
# Runs started in the same second: the newer job (the higher ID in detailsUrl) counts, wherever the rollup lists it.
job() { printf 'https://github.com/o/r/actions/runs/1/job/%s' "$1"; }
same_second=$(jq -n -c --arg old "$(job 900)" --arg new "$(job 1000)" '[{"url":"u10","title":"feat(A-10): tie","isDraft":false,
  "labels":[],"statusCheckRollup":[
  {"__typename":"CheckRun","name":"guard","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-01-02T00:00:00Z","detailsUrl":$new},
  {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z","detailsUrl":$old},
  {"__typename":"CheckRun","name":"checks-node","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z","detailsUrl":$new},
  {"__typename":"CheckRun","name":"checks-node","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-02T00:00:00Z","detailsUrl":$old}]}]')
expect_eq "a guard run started in the same second as a finished one, and newer, is still running" \
  "$(pr_states "[]" <<<"$same_second" | jq -r .kind)" "wait"
expect_eq "a check run started in the same second as a failed one, and newer, decides" \
  "$(jq -c '.[0].statusCheckRollup[0].status = "COMPLETED" | .[0].statusCheckRollup[0].conclusion = "SUCCESS"' <<<"$same_second" |
    pr_states "[]" | jq -r .note)" "checks green"
# A queued run has no start time yet (gh writes year 1): its job ID still makes it the newest.
expect_eq "a newer guard run still queued keeps the PR waiting" \
  "$(jq -c '.[0].statusCheckRollup[0].status = "QUEUED" | .[0].statusCheckRollup[0].startedAt = "0001-01-01T00:00:00Z"' <<<"$same_second" |
    pr_states "[]" | jq -r .kind)" "wait"
# The job ID is the number after /actions/runs/<run>/job/, not any "/job/" in the repository's name.
job_repo=$(jq -c '(.[0].statusCheckRollup[] | .detailsUrl) |= sub("/o/r/"; "/job/2024/")' <<<"$same_second")
expect_eq "a repository named job/2024 does not hide the job ID" "$(pr_states "[]" <<<"$job_repo" | jq -r .kind)" "wait"

echo "pr_states"
expect_eq "every open PR has a kind" "$(pr_states "[]" <<<"$fixture" | jq -r '"\(.url) \(.kind)"' | tr '\n' ' ')" \
  "u1 answer u2 draft u3 approve u4 approved u5 blocked u6 wait u7 approve u8 approve "
auto=$(jq -c '[.[] | select(.url == "u4")] | [.[0], (.[0] | .autoMergeRequest = {"mergeMethod": "SQUASH"})]' <<<"$fixture" |
  pr_states "[]" | jq -r '"\(.autoMerge) \(.note)"')
expect_eq "an approved PR says whether it merges itself" "$auto" "false approved; auto-merge is off, so merge it yourself
true approved; merges when checks pass"
numbered=$(jq -c 'map(.number = (.url[1:] | tonumber))' <<<"$fixture")
expect_eq "a PR in the merge queue is queued, whatever else it shows" \
  "$(pr_states '[3, 7]' <<<"$numbered" | jq -r '"\(.url) \(.kind)"' | tr '\n' ' ')" \
  "u1 answer u2 draft u3 queued u4 approved u5 blocked u6 wait u7 queued u8 approve "
expect_eq "queued PRs do not wait for the owner" "$(classify_prs '[3, 7]' <<<"$numbered" | cut -f1,2 | tr '\t\n' ' ,')" \
  "answer u1,blocked u5,wait u6,approve u8,"

echo "project_states"
node() {
  jq -n -c --arg name "$1" --arg permission "$2" --argjson rulesets "$3" --argjson topics "$4" --argjson bootstrap "$5" '{
    nameWithOwner: $name, isFork: false, isPrivate: true, pushedAt: "2026-11-05T00:00:00Z", viewerPermission: $permission,
    repositoryTopics: {nodes: ($topics | map({topic: {name: .}}))}, rulesets: {nodes: $rulesets},
    pullRequests: {totalCount: 2}, bootstrap: {nodes: $bootstrap}}'
}
active='[{"name":"agent-guardrails","enforcement":"ACTIVE"}]'
own_setup='[{"url":"https://github.com/acme/ready/pull/1","title":"chore: install","isCrossRepository":false,"author":{"login":"owner"}}]'
fork_setup='[{"url":"https://github.com/acme/evil/pull/9","title":"chore: install","isCrossRepository":true,"author":{"login":"owner"}}]'
stranger_setup='[{"url":"https://github.com/acme/evil/pull/8","title":"chore: install","isCrossRepository":false,"author":{"login":"mallory"}}]'
nodes=$(
  node acme/on ADMIN "$active" '["agent-guardrails"]' '[]'
  node Acme/Disabled ADMIN '[{"name":"agent-guardrails","enforcement":"DISABLED"}]' '[]' '[]'
  node owner/tagged ADMIN '[]' '["agent-guardrails"]' '[]'
  node owner/unlisted ADMIN "$active" '[]' '[]'
  node acme/teammate-tagged ADMIN '[]' '["agent-guardrails"]' '[]'
  node acme/teammate-active ADMIN "$active" '[]' '[]'
  node acme/remembered ADMIN '[]' '[]' '[]'
  node acme/ready ADMIN '[]' '[]' "$own_setup"
  node acme/fork-pr ADMIN '[]' '[]' "$fork_setup"
  node acme/stranger ADMIN '[]' '[]' "$stranger_setup"
  node acme/readonly WRITE '[]' '[]' '[]'
)
expect_eq "project states" "$(project_states owner $'acme/on\nacme/disabled' none '' acme/remembered <<<"$nodes" | jq -r '"\(.repo) \(.state)"' | tr '\n' ' ')" \
  "acme/on on Acme/Disabled alarm owner/tagged alarm owner/unlisted alarm acme/teammate-tagged elsewhere acme/teammate-active elsewhere acme/remembered alarm acme/ready ready acme/fork-pr off acme/stranger off acme/readonly no-admin "
expect_eq "a ready project carries its bootstrap PR" \
  "$(project_states owner '' none '' '' <<<"$nodes" | jq -r 'select(.state == "ready") | .setupURL')" "https://github.com/acme/ready/pull/1"
review_nodes=$(
  node acme/reviewed ADMIN '[{"name":"agent-guardrails","enforcement":"ACTIVE"},{"name":"agent-guardrails-review","enforcement":"ACTIVE"}]' '[]' '[]'
  node acme/status ADMIN "$active" '[]' '[]'
  node acme/plain ADMIN '[]' '[]' '[]'
)
expect_eq "mode and agent App per project" \
  "$(project_states owner $'acme/reviewed\nacme/status' registered $'Acme/Reviewed\nacme/plain' '' <<<"$review_nodes" |
    jq -r '"\(.repo) \(.mode) \(.agentApp)"' | tr '\n' ' ')" \
  "acme/reviewed review installed acme/status status missing acme/plain null installed "
expect_eq "no agent App on this Mac" "$(project_states owner acme/status none '' '' <<<"$review_nodes" | jq -r .agentApp | sort -u)" "none"
queue_nodes=$(
  node acme/queued ADMIN '[{"name":"agent-guardrails","enforcement":"ACTIVE","rules":{"nodes":[{"type":"PULL_REQUEST"},{"type":"MERGE_QUEUE"}]}},
    {"name":"agent-guardrails-review","enforcement":"ACTIVE"}]' '[]' '[]' | jq -c '.owner = {__typename: "Organization"}'
  node acme/other-queue ADMIN '[{"name":"agent-guardrails","enforcement":"ACTIVE"},
    {"name":"theirs","enforcement":"ACTIVE","rules":{"nodes":[{"type":"MERGE_QUEUE"}]}}]' '[]' '[]' | jq -c '.owner = {__typename: "Organization"}'
  node owner/personal ADMIN "$active" '[]' '[]' | jq -c '.owner = {__typename: "User"}'
)
expect_eq "merge queue and organization per project" \
  "$(project_states owner $'acme/queued\nacme/other-queue\nowner/personal' registered '' '' <<<"$queue_nodes" |
    jq -r '"\(.repo) \(.mergeQueue) \(.organization)"' | tr '\n' ' ')" \
  "acme/queued true true acme/other-queue false true owner/personal false false "
expect_eq "an enforced repository GitHub could not read is an alarm, not a missing row" \
  "$(jq -n -c '{nameWithOwner: "acme/gone", unreadable: true, isFork: false, isPrivate: true, pushedAt: "",
      viewerPermission: "READ", pullRequests: {totalCount: 0}}' | project_states owner acme/gone none '' '' |
    jq -r '"\(.state) \(.private) \(.openPRs) \(.mergeQueue)"')" "alarm true 0 false"

echo "events for the app"
expect_eq "no events without the descriptor" "$(GUARDRAILS_EVENTS_FD='' emit_event '{"event":"x"}' 3>&1)" ""
expect_eq "events go to the named descriptor" "$(GUARDRAILS_EVENTS_FD=3 emit_event '{"event":"x"}' 3>&1 >/dev/null)" '{"event":"x"}'
expect_eq "only descriptors 3-9 are used" "$(GUARDRAILS_EVENTS_FD=1 emit_event '{"event":"x"}')" ""
expect_eq "files as JSON" "$(printf '!!\t.github/workflows/x.yml\n\tsrc/a b.ts\n' | files_json)" \
  '[{"marker":"!!","path":".github/workflows/x.yml"},{"marker":"","path":"src/a b.ts"}]'

# The repositories the fake gh's GitHub holds, as GraphQL repository nodes. The owner (login "owner") is a member
# of the organizations "acme" and "labs". Searches answer only for the owners their query names, the way GitHub's do.
# Only the 25 most recently pushed organization repositories fit a page of the projects list: acme/readonly (not
# an admin there), acme/teammate (a teammate enforced it from their Mac), 22 fillers and acme/shop. The kit's other
# repositories are older. acme/lost is in this Mac's history but no longer in its list; labs/tagged and
# elsewhere/tagged are teammates' and outside the page.
at() { jq -c --arg owner "$1" --arg pushed "$2" '.owner = {__typename: $owner} | .pushedAt = $pushed'; }
world=$(
  node owner/app ADMIN '[]' '[]' '[]' | at User 2026-11-12T00:00:00Z
  node owner/lost ADMIN '[]' '["agent-guardrails"]' '[]' | at User 2026-11-11T12:00:00Z
  node acme/readonly WRITE '[]' '[]' '[]' | at Organization 2026-11-14T00:00:00Z
  node acme/teammate ADMIN "$active" '["agent-guardrails"]' '[]' | at Organization 2026-11-13T01:00:00Z
  for i in $(seq 10 31); do node "acme/filler-$i" ADMIN '[]' '[]' '[]' | at Organization "2026-11-13T00:$i:00Z"; done
  node acme/shop ADMIN "$active" '["agent-guardrails"]' '[]' | at Organization 2026-11-11T00:00:00Z
  node acme/lost ADMIN '[]' '["agent-guardrails"]' '[]' | at Organization 2026-10-01T00:00:00Z
  node acme/new ADMIN '[]' '[]' \
    '[{"url":"https://github.com/acme/new/pull/1","title":"chore: install the kit","isCrossRepository":false,"author":{"login":"owner"}}]' |
    at Organization 2026-10-02T00:00:00Z
  node acme/noadmin WRITE '[]' '[]' \
    '[{"url":"https://github.com/acme/noadmin/pull/2","title":"chore: install the kit","isCrossRepository":false,"author":{"login":"owner"}}]' |
    at Organization 2026-10-03T00:00:00Z
  node acme/upstream ADMIN '[]' '[]' \
    '[{"url":"https://github.com/acme/upstream/pull/3","title":"chore: install the kit","isCrossRepository":true,"author":{"login":"owner"}}]' |
    at Organization 2026-10-04T00:00:00Z
  node acme/off ADMIN '[]' '[]' '[]' | at Organization 2026-09-01T00:00:00Z
  node labs/tagged ADMIN '[]' '["agent-guardrails"]' '[]' | at Organization 2026-08-01T00:00:00Z
  node elsewhere/tagged ADMIN '[]' '["agent-guardrails"]' '[]' | at Organization 2026-08-02T00:00:00Z
)
export FAKE_WORLD="$work/world.json"
jq -s -c . <<<"$world" >"$FAKE_WORLD"
export FAKE_QUERIES="$work/queries.txt"
: >"$FAKE_QUERIES"

# A fake gh on PATH answers the calls of bin/guardrails and pr_snapshot_files from fixtures.
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
args="$*"
if [[ $1 == api && $2 == graphql ]]; then
  query="" filter=. owner="" name=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case $1 in
      -f)
        case $2 in query=*) query=${2#query=} ;; owner=*) owner=${2#owner=} ;; name=*) name=${2#name=} ;; esac
        shift 2
        ;;
      --jq) filter=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$query" | tr '\n' ' ' >>"$FAKE_QUERIES"
  printf '\n' >>"$FAKE_QUERIES"
  pages='{pageInfo: {hasNextPage: false, endCursor: null}}'
  if [[ $query == *"search("* && -n ${FAKE_SEARCH_ANSWER:-} ]]; then
    response=$FAKE_SEARCH_ANSWER
  elif [[ $query == *"search("* ]]; then
    [[ $query == *"head:chore/agent-guardrails"* && $query == *"is:open"* ]] || { echo "fake gh: unexpected search: $query" >&2; exit 1; }
    users=$(grep -o 'user:[A-Za-z0-9-]*' <<<"$query" | cut -d: -f2 | jq -R -s -c 'split("\n") | map(select(length > 0) | ascii_downcase)')
    author=$(grep -o 'author:[A-Za-z0-9-]*' <<<"$query" | cut -d: -f2)
    response=$(jq -c --argjson users "$users" --arg author "$author" '{data: {
      tagged: ([.[] | select(any(.repositoryTopics.nodes[]; .topic.name == "agent-guardrails")
                 and ((.nameWithOwner | split("/")[0] | ascii_downcase) as $o | $users | index($o)) != null)]
               | {repositoryCount: length, nodes: map({nameWithOwner})}),
      bootstrap: ([.[] | . as $r | .bootstrap.nodes[] | select(.author.login == $author)
                   | . + {repository: {nameWithOwner: $r.nameWithOwner, viewerPermission: $r.viewerPermission}}]
                  | {issueCount: length, nodes: .})}}' "$FAKE_WORLD")
  elif [[ $query == *ORGANIZATION_MEMBER* ]]; then
    first=$(grep -o 'first: [0-9]*' <<<"$query" | head -1 | cut -d' ' -f2)
    response=$(jq -c --argjson first "$first" "{data: {viewer: {repositories: ($pages + {nodes: ([.[] | select(.owner.__typename == \"Organization\")]
      | sort_by(.pushedAt) | reverse | .[:\$first])})}}}" "$FAKE_WORLD")
  elif [[ $query == *"ownerAffiliations: OWNER,"* ]]; then
    response=$(jq -c "{data: {viewer: {repositories: ($pages + {nodes: ([.[] | select(.owner.__typename == \"User\")]
      | sort_by(.pushedAt) | reverse)})}}}" "$FAKE_WORLD")
  elif [[ -n $owner && -n $name ]]; then
    response=$(jq -c --arg r "$owner/$name" '{data: {repository: (first(.[] | select((.nameWithOwner | ascii_downcase) == ($r | ascii_downcase))) // null)}}' "$FAKE_WORLD")
  else
    echo "fake gh: unexpected query: $query" >&2
    exit 1
  fi
  jq -c "$filter" <<<"$response"
  exit
fi
case $args in
  "api user --jq .login") echo owner ;;
  "api repos/acme/"*" --jq .default_branch") echo main ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails")'*) echo 7 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-tags")'*) echo 9 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-review")'*)
    [[ ! -e $FAKE_RULESETS/review.json ]] || echo 8 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*) echo "" ;;
  "api repos/acme/shop/rulesets/7") cat "$FAKE_RULESETS/branch.json" ;;
  "api repos/acme/shop/rulesets/8") cat "$FAKE_RULESETS/review.json" ;;
  "api repos/acme/shop/rulesets/9") cat "$FAKE_RULESETS/tag.json" ;;
  "api --paginate repos/acme/off/rulesets"* | "api --paginate repos/acme/broken/rulesets"*) echo "" ;;
  "pr list -R acme/broken "*) echo "HTTP 502" >&2; exit 1 ;;
  "pr list -R acme/shop "*) cat "$FAKE_PRS" ;;
  "pr list -R acme/off "*) echo '[]' ;;
  "api repos/acme/shop/compare/1111111111111111111111111111111111111111...2222222222222222222222222222222222222222?per_page=1")
    echo '{"files":[{"filename":"src/a.ts","status":"modified"}]}' ;;
  "api repos/acme/shop/compare/1111111111111111111111111111111111111111...3333333333333333333333333333333333333333?per_page=1")
    echo "HTTP 502" >&2
    exit 1
    ;;
  *) echo "fake gh: unexpected call: $args" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/gh"
printf '%s' "$fixture" >"$work/prs.json"
# acme/shop's live rulesets are the kit's own, in status mode.
export FAKE_RULESETS="$work/rulesets"
mkdir -p "$FAKE_RULESETS"
status_mode_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$FAKE_RULESETS/branch.json"
tag_ruleset agent-guardrails-tags | jq -c '. + {id: 9}' >"$FAKE_RULESETS/tag.json"
fake_home="$work/fake-home"
mkdir -p "$fake_home/.config/agent-guardrails"
printf 'acme/shop\nacme/off\n' >"$fake_home/.config/agent-guardrails/repos"
printf 'acme/lost\n' >"$fake_home/.config/agent-guardrails/enforced-history"
run_cli() { HOME=$fake_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" "$kit/bin/guardrails" "$@" 2>&1; }
# Lines about the kit install itself depend on this checkout and the network; the tests skip them.
inbox_text=$(run_cli inbox | grep -v 'kit install\|kit origin')
expect_eq "inbox text" "$inbox_text" "ALARM  owner/lost carries the agent-guardrails topic but is not in $fake_home/.config/agent-guardrails/repos. If you did not remove it, restore with: guardrails on owner/lost
ALARM  acme/lost was enforced from this Mac but is not in $fake_home/.config/agent-guardrails/repos, and guardrails off did not remove it. If you did not remove it, restore with: guardrails on acme/lost
ALARM  acme/off: the agent-guardrails ruleset is missing. If you did not change it, check the audit log; restore with: guardrails on acme/off

acme/shop
  answer   spec(A-1): x
           u1 (the agent is waiting for your decision)
  approve  feat(A-3): ready (checks running)
           guardrails approve u3
  blocked  feat(A-5): bad (guard failed: the agent has to fix the PR)
  wait     feat(A-6): new (guard is running)
  approve  feat(A-7): revoked (checks green)
           guardrails approve u7
  approve  feat(A-8): leak (checks failing)
           guardrails approve u8

Not enforced yet
  turn on  chore: install the kit
           guardrails on https://github.com/acme/new/pull/1"
inbox_json=$(run_cli inbox --json | jq -c 'select(.repo != "")')
expect_eq "inbox json" "$inbox_json" '{"kind":"alarm","repo":"owner/lost","url":"","title":"","note":"owner/lost carries the agent-guardrails topic but is not in '"$fake_home"'/.config/agent-guardrails/repos. If you did not remove it, restore with: guardrails on owner/lost","sha":""}
{"kind":"alarm","repo":"acme/lost","url":"","title":"","note":"acme/lost was enforced from this Mac but is not in '"$fake_home"'/.config/agent-guardrails/repos, and guardrails off did not remove it. If you did not remove it, restore with: guardrails on acme/lost","sha":""}
{"kind":"repo","repo":"acme/shop","url":"","title":"","note":"active","sha":""}
{"kind":"answer","repo":"acme/shop","url":"u1","title":"spec(A-1): x","note":"the agent is waiting for your decision","sha":""}
{"kind":"approve","repo":"acme/shop","url":"u3","title":"feat(A-3): ready","note":"checks running","sha":"abc123"}
{"kind":"blocked","repo":"acme/shop","url":"u5","title":"feat(A-5): bad","note":"guard failed: the agent has to fix the PR","sha":""}
{"kind":"wait","repo":"acme/shop","url":"u6","title":"feat(A-6): new","note":"guard is running","sha":""}
{"kind":"approve","repo":"acme/shop","url":"u7","title":"feat(A-7): revoked","note":"checks green","sha":""}
{"kind":"approve","repo":"acme/shop","url":"u8","title":"feat(A-8): leak","note":"checks failing","sha":""}
{"kind":"repo","repo":"acme/off","url":"","title":"","note":"missing","sha":""}
{"kind":"alarm","repo":"acme/off","url":"","title":"","note":"acme/off: the agent-guardrails ruleset is missing. If you did not change it, check the audit log; restore with: guardrails on acme/off","sha":""}
{"kind":"turn-on","repo":"acme/new","url":"https://github.com/acme/new/pull/1","title":"chore: install the kit","note":"","sha":""}'

# A teammate's tagged repositories raise no alarm: the topic search covers only the owner's own account, and the
# history only what this Mac enforced. The inbox copied the list into the history, so an organization repository
# that later drops out of the list raises an alarm.
expect_eq "the inbox remembers what this Mac enforced" \
  "$(sort "$fake_home/.config/agent-guardrails/enforced-history" | tr '\n' ' ')" "acme/lost acme/off acme/shop "
lost_home="$work/lost-home"
mkdir -p "$lost_home/.config/agent-guardrails"
printf 'acme/shop\n' >"$lost_home/.config/agent-guardrails/repos"
HOME=$lost_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" "$kit/bin/guardrails" inbox --json >/dev/null 2>&1
: >"$lost_home/.config/agent-guardrails/repos"
expect_eq "an organization repository this Mac enforced raises an alarm once it drops out of the list" \
  "$(HOME=$lost_home PATH="$fake_bin:$PATH" "$kit/bin/guardrails" inbox --json 2>&1 | jq -r 'select(.kind == "alarm" and .repo != "") | .repo' | tr '\n' ' ')" \
  "owner/lost acme/shop "

echo "kit search answers"
search_fails() {
  local name=$1 answer=$2 needle=$3 out
  if out=$(FAKE_SEARCH_ANSWER=$answer run_cli inbox --json); then
    fail "$name: the inbox must fail, got: $out"
  elif [[ $out == *"$needle"* ]]; then ok; else fail "$name: the error lacks '$needle': $out"; fi
}
search_fails "an answer without the tagged nodes" '{"data":{"tagged":null,"bootstrap":{"issueCount":0,"nodes":[]}}}' \
  "lacks its node lists or totals"
search_fails "an answer without data" '{"data":null}' "lacks its node lists or totals"
search_fails "more tagged repositories than the search returned" \
  '{"data":{"tagged":{"repositoryCount":101,"nodes":[{"nameWithOwner":"owner/lost"}]},"bootstrap":{"issueCount":0,"nodes":[]}}}' \
  "101 of your repositories carry the topic, more than the 1 one search returns"
search_fails "more bootstrap PRs than the search returned" \
  '{"data":{"tagged":{"repositoryCount":0,"nodes":[]},"bootstrap":{"issueCount":51,"nodes":[]}}}' \
  "you have 51 open bootstrap PRs, more than the 0 one search returns"

# The organization repositories outside the projects page still get a row when the kit is in them (enforced,
# remembered, or with the owner's bootstrap PR), read by name; others there stay out, and so do repositories the
# owner cannot administer, unless the kit is in them. A teammate's enforced repository in the page is information.
: >"$FAKE_QUERIES"
projects=$(run_cli projects --json)
expect_eq "projects: the kit's repositories of every owner, newest push first" \
  "$(jq -r 'select(.repo | startswith("acme/filler-") | not) | "\(.repo) \(.state)"' <<<"$projects" | tr '\n' ',')" \
  "acme/teammate elsewhere,owner/app off,owner/lost alarm,acme/shop on,acme/noadmin no-admin,acme/new ready,acme/lost alarm,acme/off alarm,"
expect_eq "projects: the organization page lists the repositories the owner administers, each once" \
  "$(jq -r .repo <<<"$projects" | grep -c '^acme/filler-')|$(jq -r .repo <<<"$projects" | sort | uniq -d)" "22|"
expect_eq "projects: a ready organization repository carries its bootstrap PR" \
  "$(jq -r 'select(.repo == "acme/new") | .setupURL' <<<"$projects")" "https://github.com/acme/new/pull/1"
expect_eq "projects: one search, one page of personal and one of organization repositories, one read per other row" \
  "$(grep -c 'search(' "$FAKE_QUERIES")|$(grep -c 'ORGANIZATION_MEMBER' "$FAKE_QUERIES")|$(grep -c 'repository(owner' "$FAKE_QUERIES")" \
  "1|1|4"

broken_home="$work/broken-home"
mkdir -p "$broken_home/.config/agent-guardrails"
printf 'acme/shop\nacme/broken\n' >"$broken_home/.config/agent-guardrails/repos"
if broken=$(HOME=$broken_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" "$kit/bin/guardrails" inbox --json 2>&1); then
  fail "an unreadable repository must fail the inbox, not shorten it: $broken"
else
  expect_eq "the inbox names what it could not read" "$(tail -1 <<<"$broken")" "error: cannot list the open PRs of acme/broken"
fi

echo "merge queue in the inbox and on the command line"
queue_home="$work/queue-home"
mkdir -p "$queue_home/.config/agent-guardrails"
printf 'acme/shop\n' >"$queue_home/.config/agent-guardrails/repos"
printf 'acme/shop\n' >"$queue_home/.config/agent-guardrails/merge-queue"
queue_alarm=$(HOME=$queue_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" "$kit/bin/guardrails" inbox --json 2>&1 |
  jq -r 'select(.kind == "alarm" and .repo == "acme/shop") | .note')
expect_eq "a repository listed with the merge queue whose ruleset lost it raises an alarm" "$queue_alarm" \
  "acme/shop: the merge queue is gone from the agent-guardrails ruleset, so PRs merge without being checked together. If you did not change it, check the audit log; restore with: guardrails on acme/shop"
expect_eq "both queue flags at once are refused before anything runs" \
  "$(run_cli on acme/shop --merge-queue --no-merge-queue)" "error: give --merge-queue or --no-merge-queue once"
no_target="error: guardrails on needs the repository (owner/repo) or a /guardrails-init PR link, for example: guardrails on octo/app"
expect_eq "on without a target names what is missing" "$(run_cli on)" "$no_target"
expect_eq "the queue flag alone is no target" "$(run_cli on --merge-queue)" "$no_target"

echo "ruleset coverage in the inbox and in approval mode"
# An active ruleset with every rule in place protects nothing once its conditions no longer select the default
# branch; the inbox and approval_mode must both see that, the way they read the live rulesets.
coverage_home="$work/coverage-home"
mkdir -p "$coverage_home/.config/agent-guardrails"
printf 'acme/shop\n' >"$coverage_home/.config/agent-guardrails/repos"
coverage_alarms() {
  HOME=$coverage_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" FAKE_RULESETS=$1 "$kit/bin/guardrails" inbox --json 2>&1 |
    jq -r 'select(.kind == "alarm" and .repo == "acme/shop") | .note'
}
coverage_mode() { PATH="$fake_bin:$PATH" FAKE_RULESETS=$1 approval_mode acme/shop main; }
retargeted="$work/rulesets-retargeted"
mkdir -p "$retargeted"
jq -c '.conditions.ref_name.include = ["refs/heads/scratch"]' "$FAKE_RULESETS/branch.json" >"$retargeted/branch.json"
cp "$FAKE_RULESETS/tag.json" "$retargeted/tag.json"
expect_eq "the kit's status mode setup raises no alarm and is status mode" \
  "$(coverage_alarms "$FAKE_RULESETS")|$(coverage_mode "$FAKE_RULESETS")" "|status"
expect_eq "a branch ruleset retargeted away from the default branch raises an alarm" "$(coverage_alarms "$retargeted")" \
  'acme/shop: the agent-guardrails ruleset no longer covers the default branch main (ref_name {"include":["refs/heads/scratch"],"exclude":[]}). If you did not change it, check the audit log; restore with: guardrails on acme/shop'
expect_eq "a retargeted status mode ruleset is no approval mode" "$(coverage_mode "$retargeted")" "-"
# A branch ruleset without the security check: a repository behind the kit has no security workflow yet, so that is
# a note pointing at the kit update; with the workflow on the default branch it is an alarm.
unsecured="$work/rulesets-unsecured"
mkdir -p "$unsecured"
cp "$FAKE_RULESETS"/*.json "$unsecured/"
jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "security"))' \
  "$FAKE_RULESETS/branch.json" >"$unsecured/branch.json"
jq -c 'map(if .nameWithOwner == "acme/shop" then . + {securityWorkflow: {id: "w"}} else . end)' "$FAKE_WORLD" \
  >"$work/world-secured.json"
shop_items() {
  HOME=$coverage_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" FAKE_RULESETS=$unsecured FAKE_WORLD=$1 \
    "$kit/bin/guardrails" inbox --json 2>&1 | jq -r 'select((.kind == "alarm" or .kind == "note") and .repo == "acme/shop") | "\(.kind): \(.note)"'
}
expect_eq "no security check and no security workflow is a note about the kit update" "$(shop_items "$FAKE_WORLD")" \
  "note: acme/shop needs the kit update: its default branch has no security workflow yet, so the ruleset cannot require the security check. Open the kit update PR (README, \"Updating a project's kit files\"), approve it, then run: guardrails on acme/shop"
expect_eq "no security check while the workflow is there is an alarm" "$(shop_items "$work/world-secured.json")" \
  "alarm: acme/shop: security is not a required check from GitHub Actions. If you did not change it, check the audit log; restore with: guardrails on acme/shop"
reviewed="$work/rulesets-review"
mkdir -p "$reviewed"
branch_ruleset agent-guardrails "$(pinned_checks checks-node)" | jq -c '. + {id: 7}' >"$reviewed/branch.json"
review_ruleset agent-guardrails-review | jq -c '. + {id: 8}' >"$reviewed/review.json"
cp "$FAKE_RULESETS/tag.json" "$reviewed/tag.json"
expect_eq "the kit's review mode setup raises no alarm and is review mode" \
  "$(coverage_alarms "$reviewed")|$(coverage_mode "$reviewed")" "|review"
review_excluded="$work/rulesets-review-excluded"
mkdir -p "$review_excluded"
cp "$reviewed"/*.json "$review_excluded/"
jq -c '.conditions.ref_name.exclude = ["refs/heads/main"]' "$reviewed/review.json" >"$review_excluded/review.json"
branch_bypassed="$work/rulesets-branch-bypassed"
mkdir -p "$branch_bypassed"
cp "$reviewed"/*.json "$branch_bypassed/"
jq -c '.bypass_actors = [{actor_id: 123, actor_type: "Integration", bypass_mode: "always"}]' "$reviewed/branch.json" \
  >"$branch_bypassed/branch.json"
expect_eq "a branch ruleset someone may bypass raises an alarm and is no approval mode, even with an intact review ruleset" \
  "$(coverage_alarms "$branch_bypassed")|$(coverage_mode "$branch_bypassed")" \
  'acme/shop: the agent-guardrails ruleset has a changed bypass list (unexpected Integration 123 (always)). If you did not change it, check the audit log; restore with: guardrails on acme/shop|-'
expect_eq "a review ruleset that excludes the default branch raises an alarm and is no approval mode" \
  "$(coverage_alarms "$review_excluded")|$(coverage_mode "$review_excluded")" \
  'acme/shop: the agent-guardrails-review ruleset no longer covers the default branch main (ref_name {"include":["~DEFAULT_BRANCH"],"exclude":["refs/heads/main"]}). If you did not change it, check the audit log; restore with: guardrails on acme/shop|-'

review_case_excluded="$work/rulesets-review-case-excluded"
mkdir -p "$review_case_excluded"
cp "$reviewed"/*.json "$review_case_excluded/"
jq -c '.conditions.ref_name.exclude = ["refs/heads/MAIN"]' "$reviewed/review.json" >"$review_case_excluded/review.json"
expect_eq "a review ruleset that excludes the default branch in another case raises an alarm and is no approval mode" \
  "$(coverage_alarms "$review_case_excluded")|$(coverage_mode "$review_case_excluded")" \
  'acme/shop: the agent-guardrails-review ruleset no longer covers the default branch main (ref_name {"include":["~DEFAULT_BRANCH"],"exclude":["refs/heads/MAIN"]}). If you did not change it, check the audit log; restore with: guardrails on acme/shop|-'

echo "compared_files and pr_snapshot_files"
expect_eq "plain file names pass" "$(compared_files 1 <<<'{"files":[{"filename":"src/a.ts","status":"modified"}]}')" "src/a.ts"
expect_eq "a rename lists its old path too" "$(compared_files 2 <<<'{"files":[
  {"filename":"src/moved.yml","previous_filename":".github/workflows/checks-node.yml","status":"renamed"},
  {"filename":"src/a.ts","status":"modified"}]}')" ".github/workflows/checks-node.yml
src/a.ts
src/moved.yml"
expect_refused() {
  local name=$1 expected=$2 comparison=$3 needle=$4 out
  if out=$(compared_files "$expected" <<<"$comparison"); then
    fail "$name: must be refused, got: $out"
  elif [[ $out == *"$needle"* ]]; then ok; else fail "$name: the reason lacks '$needle': $out"; fi
}
expect_refused "a file name with control characters" 1 '{"files":[{"filename":"src/\u001b[2Kfake","status":"added"}]}' \
  "control characters: src/?[2Kfake"
expect_refused "an empty old name of a rename" 1 '{"files":[{"filename":"src/a.ts","previous_filename":"","status":"renamed"}]}' \
  "empty file names"
expect_refused "a comparison without its file list" 1 '{"status":"ahead"}' "without its list of files"
expect_refused "a comparison at GitHub's limit of 300 files" 300 \
  "$(jq -n -c '{files: [range(300) | {filename: "src/f\(.).ts", status: "added"}]}')" "at most 300 files"
expect_refused "a list shorter than the PR's count of changed files" 3001 '{"files":[{"filename":"src/a.ts","status":"added"}]}' \
  "lists 1 files, but the PR reports 3001"
expect_refused "an answer that is not JSON" 1 'HTTP 502' "other than JSON"
expect_eq "the snapshot names both commits" \
  "$(PATH="$fake_bin:$PATH" pr_snapshot_files acme/shop 1 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 1)" \
  "src/a.ts"
if snapshot=$(PATH="$fake_bin:$PATH" pr_snapshot_files acme/shop 1 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 2 2>&1); then
  fail "a comparison that disagrees with the PR's count must be refused: $snapshot"
else
  expect_eq "the refusal says why and what to do" "$(tail -1 <<<"$snapshot")" \
    "error: cannot show the complete list of files PR #1 in acme/shop changes between 1111111 and 2222222: the comparison lists 1 files, but the PR reports 2 changed files for the same head. Refusing to show or approve a partial list; split the PR if it is that large, otherwise run the command again."
fi
if (PATH="$fake_bin:$PATH" pr_snapshot_files acme/shop 1 1111111111111111111111111111111111111111 3333333333333333333333333333333333333333 1 >/dev/null 2>&1); then
  fail "a failed comparison must be refused"
else ok; fi

echo "changes_enforcement"
for path in .github/workflows/ci.yml .github/security-ignore .github/CODEOWNERS .agent/bin/run-checks .claude/settings.json Makefile \
  sub/Makefile .agent/common.mk CODEOWNERS .cursor/hooks.json .codex/hooks.json .github/workflows/agent-notify.yml \
  .agent/bin/notify-team; do
  if changes_enforcement "$path"; then ok; else fail "$path changes what CI enforces"; fi
done
for path in src/Makefile.ts specs/A-1/spec.lock README.md; do
  if changes_enforcement "$path"; then fail "$path does not change what CI enforces"; else ok; fi
done

echo "guard_conclusion"
runs='{"workflow_runs":[
 {"path":".github/workflows/agent-guard.yml","created_at":"2026-01-01T00:00:00Z","conclusion":"failure","pull_requests":[{"number":5,"base":{"ref":"main"}}]},
 {"path":".github/workflows/agent-guard.yml","created_at":"2026-01-02T00:00:00Z","conclusion":"success","pull_requests":[{"number":6,"base":{"ref":"scratch"}}]},
 {"path":".github/workflows/lookalike.yml","created_at":"2026-01-03T00:00:00Z","conclusion":"success","pull_requests":[{"number":5,"base":{"ref":"main"}}]}]}'
expect_eq "a newer run of another PR into another branch does not count" "$(guard_conclusion 5 main <<<"$runs")" "failure"
expect_eq "a PR with no guard run into the default branch is missing" "$(guard_conclusion 6 main <<<"$runs")" "missing"
# GitHub lists the newest run first; of two created in the same second, the higher run ID is the newer.
tie='{"workflow_runs":[
 {"id":20,"path":".github/workflows/agent-guard.yml","created_at":"2026-01-04T00:00:00Z","conclusion":"failure","pull_requests":[{"number":7,"base":{"ref":"main"}}]},
 {"id":19,"path":".github/workflows/agent-guard.yml","created_at":"2026-01-04T00:00:00Z","conclusion":"success","pull_requests":[{"number":7,"base":{"ref":"main"}}]}]}'
expect_eq "of two runs created in the same second, the newer one decides" "$(guard_conclusion 7 main <<<"$tie")" "failure"
expect_eq "the run number, which counts the workflow's runs, comes before the run ID" \
  "$(jq -c '.workflow_runs[0].run_number = 7 | .workflow_runs[1].run_number = 8' <<<"$tie" | guard_conclusion 7 main)" "success"

echo "kit install checks"
fake_kit="$work/fake-kit"
git init -q "$fake_kit"
printf 'x\n' >"$fake_kit/tool"
git -C "$fake_kit" add tool
git -C "$fake_kit" -c user.name=t -c user.email=t@t commit -q -m init
expect_eq "clean install has no local changes" "$(kit=$fake_kit kit_local_changes)" ""
printf 'y\n' >"$fake_kit/tool"
git -C "$fake_kit" update-index --skip-worktree tool
expect_eq "skip-worktree cannot hide an edit" "$(kit=$fake_kit kit_local_changes)" "not watched by git: tool"
git -C "$fake_kit" update-index --no-skip-worktree tool
git -C "$fake_kit" checkout -q tool
git -C "$fake_kit" config status.showUntrackedFiles no
printf 'z\n' >"$fake_kit/new-tool"
expect_eq "untracked files show despite the repo config" "$(kit=$fake_kit kit_local_changes)" "?? new-tool"
rm "$fake_kit/new-tool"
git -C "$fake_kit" config core.fsmonitor "touch $work/fsmonitor-ran; false"
kit=$fake_kit kit_local_changes >/dev/null 2>&1 || true
if [[ -e "$work/fsmonitor-ran" ]]; then fail "core.fsmonitor ran while checking the install"; else ok; fi
git -C "$fake_kit" config --unset core.fsmonitor
# The origin is an https GitHub repository or a local path; the remote's upload program never runs, and a
# rewrite to the ext transport is refused.
git init -q --bare "$work/mirror"
git -C "$fake_kit" remote add origin "$work/mirror"
git -C "$fake_kit" config remote.origin.uploadpack "touch $work/uploadpack-ran; git-upload-pack"
kit=$fake_kit kit_remote_git ls-remote "$(kit=$fake_kit kit_origin)" >/dev/null
if [[ -e "$work/uploadpack-ran" ]]; then fail "checking the origin ran the remote's upload program"; else ok; fi
git -C "$fake_kit" remote set-url origin "ext::sh -c touch% $work/ext-ran"
if (kit=$fake_kit kit_origin >/dev/null 2>&1); then fail "an ext:: origin must not be accepted"; else ok; fi
git -C "$fake_kit" remote set-url origin https://github.com/acme/agent-guardrails.git
expect_eq "an https GitHub origin is accepted" "$(kit=$fake_kit kit_origin)" "https://github.com/acme/agent-guardrails.git"
git -C "$fake_kit" config url."ext::sh -c touch% $work/ext-ran".insteadOf https://github.com/acme/agent-guardrails.git
kit=$fake_kit kit_remote_git ls-remote "$(kit=$fake_kit kit_origin)" >/dev/null 2>&1 || true
if [[ -e "$work/ext-ran" ]]; then fail "a rewrite to the ext transport ran a program"; else ok; fi

echo "project bash-guard shim"
shim="$template/.agent/hooks/bash-guard.sh"
shim_project=$(new_project shim)
git -C "$shim_project" init -q
run_shim() {
  local home=$1 command=$2
  set +e
  jq -n --arg c "$command" --arg d "$shim_project" '{cwd: $d, tool_input: {command: $c}}' | HOME=$home "$shim" >/dev/null 2>&1
  printf '%s' $?
  set -e
}
echo "ruleset_problems"
checks=$(pinned_checks checks-node)
review_mode=$(jq -n -c --argjson b "$(branch_ruleset agent-guardrails "$checks")" \
  --argjson v "$(review_ruleset agent-guardrails-review)" --argjson t "$(tag_ruleset agent-guardrails-tags)" \
  '{branch: $b, review: $v, tag: $t, defaultBranch: "main"}')
expect_eq "the kit's own rulesets in review mode hold" "$(ruleset_problems <<<"$review_mode")" ""
expect_eq "status mode needs no review ruleset" "$(jq -c --argjson b "$(status_mode_ruleset agent-guardrails "$checks")" \
  '.branch = $b | .review = null' <<<"$review_mode" | ruleset_problems)" ""
if (jq -c 'del(.defaultBranch)' <<<"$review_mode" | ruleset_problems >/dev/null 2>&1); then
  fail "ruleset_problems without the default branch must fail, not read as healthy"
else ok; fi
expect_eq "a review ruleset that lets anyone bypass it, or is gone, is an alarm" "$(jq -c \
  '.review.bypass_actors += [{actor_id: 1, actor_type: "Integration", bypass_mode: "always"}]' <<<"$review_mode" | ruleset_problems)
$(jq -c '.review = null' <<<"$review_mode" | ruleset_problems)" \
  "the agent-guardrails-review ruleset has a changed bypass list (unexpected Integration 1 (always))
no ruleset requires your approval any more (neither merge-approval nor agent-guardrails-review)"
expect_eq "lost required checks and a bypass on the branch ruleset are alarms" "$(jq -c \
  '.branch.rules |= map(select(.type != "required_status_checks")) | .branch.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' \
  <<<"$review_mode" | ruleset_problems)" "the agent-guardrails ruleset has a changed bypass list (unexpected RepositoryRole 5 (always))
the agent-guardrails ruleset lost its required_status_checks rule
guard is no longer a required check from GitHub Actions
security is not a required check from GitHub Actions
no checks-<lang> job is a required check from GitHub Actions any more"
expect_eq "a check reported by another App does not count" "$(jq -c \
  '(.branch.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(del(.integration_id))' \
  <<<"$review_mode" | ruleset_problems)" "guard is no longer a required check from GitHub Actions
security is not a required check from GitHub Actions
no checks-<lang> job is a required check from GitHub Actions any more"
queued_mode=$(jq -c --argjson b "$(queued_branch_ruleset agent-guardrails "$checks")" '.branch = $b | .mergeQueue = true' <<<"$review_mode")
expect_eq "the kit's rulesets with the merge queue hold" "$(ruleset_problems <<<"$queued_mode")" ""
expect_eq "a repository that had the merge queue and lost it is an alarm" \
  "$(jq -c '.branch.rules |= map(select(.type != "merge_queue"))' <<<"$queued_mode" | ruleset_problems)" \
  "the merge queue is gone from the agent-guardrails ruleset, so PRs merge without being checked together"
expect_eq "a merge queue that lets failing PRs through is an alarm" \
  "$(jq -c '(.branch.rules[] | select(.type == "merge_queue") | .parameters.grouping_strategy) = "HEADGREEN"' <<<"$queued_mode" |
    ruleset_problems)" \
  "the merge queue no longer squashes only PRs that pass every check (merge method or grouping changed)"
expect_eq "without the merge queue turned on, its absence is no alarm" \
  "$(jq -c '.mergeQueue = false' <<<"$review_mode" | ruleset_problems)" ""
expect_eq "a branch ruleset moved to another target or excluding the default branch is an alarm" "$(jq -c \
  '.branch.target = "tag" | .review.conditions.ref_name.exclude = ["~DEFAULT_BRANCH"]' <<<"$review_mode" | ruleset_problems)" \
  'the agent-guardrails ruleset targets "tag" instead of "branch"
the agent-guardrails-review ruleset no longer covers the default branch main (ref_name {"include":["~DEFAULT_BRANCH"],"exclude":["~DEFAULT_BRANCH"]})'
expect_eq "a ruleset naming the old default branch no longer covers the current one" "$(jq -c \
  '.branch.conditions.ref_name.include = ["refs/heads/main"]' <<<"$review_mode" | ruleset_problems)|$(jq -c \
  '.branch.conditions.ref_name.include = ["refs/heads/main"] | .defaultBranch = "trunk" | .review = null | .tag = null' \
  <<<"$review_mode" | ruleset_problems)" '|the agent-guardrails ruleset no longer covers the default branch trunk (ref_name {"include":["refs/heads/main"],"exclude":[]})
no ruleset requires your approval any more (neither merge-approval nor agent-guardrails-review)
the agent-guardrails-tags ruleset is missing'
expect_eq "a tag ruleset with a lost rule, a narrower target or another bypass list is an alarm" "$(jq -c \
  '.tag.rules |= map(select(.type != "deletion")) | .tag.conditions.ref_name.exclude = ["refs/tags/v*"]
   | .tag.bypass_actors = [{actor_id: 1, actor_type: "Integration", bypass_mode: "always"}]' <<<"$review_mode" | ruleset_problems)" \
  'the agent-guardrails-tags ruleset no longer covers every tag (ref_name {"include":["~ALL"],"exclude":["refs/tags/v*"]}; the kit includes ~ALL and excludes nothing)
the agent-guardrails-tags ruleset lost its deletion rule
the agent-guardrails-tags ruleset has a changed bypass list (unexpected Integration 1 (always), missing RepositoryRole 5 (always))'
expect_eq "a tag ruleset retargeted to branches is an alarm" "$(jq -c '.tag.target = "branch"' <<<"$review_mode" | ruleset_problems)" \
  'the agent-guardrails-tags ruleset targets "branch" instead of "tag"'

echo "ruleset coverage of the default branch (GitHub ref_name semantics)"
# Each line: include, exclude, default branch, whether the ruleset covers it. Unsupported pattern syntax (braces,
# backslashes, an unclosed set, a set with a leading or trailing "-", a chained or reversed range) never counts as
# including and always counts as excluding. A set never matches "/", even when its range spans it (".-0"). The
# expected values agree with Ruby's File.fnmatch(pattern, ref, File::FNM_PATHNAME) where it can tell.
coverage_cases='[["~DEFAULT_BRANCH"],[],"main",true]
[["~ALL"],[],"main",true]
[["refs/heads/main"],[],"main",true]
[["main"],[],"main",false]
[["refs/heads/ma*"],[],"main",true]
[["refs/heads/*"],[],"release/1",false]
[["refs/heads/**/*"],[],"release/1",true]
[["refs/heads/[!m]ain"],[],"main",false]
[["refs/heads/m.in"],[],"main",false]
[["refs/heads/{main,dev}"],[],"main",false]
[["~ALL"],["refs/heads/m*"],"main",false]
[["~ALL"],["main"],"main",false]
[["~ALL"],["refs/heads/dev*"],"main",true]
[["~ALL"],["~ALL"],"main",false]
[["~ALL"],["refs/heads/[m"],"main",false]
[["refs/heads/[a-z]ain"],[],"main",true]
[["refs/heads/[!a-l]ain"],[],"main",true]
[["refs/heads[.-0]main"],[],"main",false]
[["refs/heads/[-m]ain"],[],"main",false]
[["~ALL"],["refs/heads/[!-~]ain"],"main",false]
[["~ALL"],["refs/heads/[^-z]*"],"main",false]
[["~ALL"],["refs/heads/[!a-]*"],"main",false]
[["~ALL"],["refs/heads/[z-a]ain"],"main",false]
[["~ALL"],["refs/heads/[a-c-e]ain"],"main",false]
[["~ALL"],["refs/heads/[!n-z]ain"],"main",false]
[["~ALL"],["refs/heads/[!a-z]ain"],"main",true]
[["refs/heads/MAIN"],[],"main",false]
[["refs/heads/Ma*"],[],"main",false]
[["refs/heads/main"],[],"Main",false]
[["refs/heads/[A-Z]ain"],[],"main",false]
[["~ALL"],["refs/heads/MAIN"],"main",false]
[["~ALL"],["refs/heads/Ma*"],"main",false]
[["~ALL"],["MAIN"],"main",false]
[["~ALL"],["refs/heads/main"],"Main",false]
[["~ALL"],["refs/heads/[M]ain"],"main",false]
[["~ALL"],["refs/heads/[A-Z]ain"],"main",false]
[["~ALL"],["refs/heads/[!a-z]ain"],"Main",false]
[["~ALL"],["refs/heads/[!M]ain"],"main",false]
[["~ALL"],["refs/Heads/main"],"main",false]
[["~ALL"],["~default_branch"],"main",false]
[["~ALL"],["refs/heads/DEV*"],"main",true]'
expect_eq "include, exclude and fnmatch patterns" "$(jq -s -c "$ruleset_jq_defs"'
  map(. as [$include, $exclude, $branch]
    | {target: "branch", conditions: {ref_name: {include: $include, exclude: $exclude}}} | covers_default($branch))' \
  <<<"$coverage_cases")" "$(jq -s -c 'map(.[3])' <<<"$coverage_cases")"

echo "merge queue"
queued_rules=$(queued_branch_ruleset agent-guardrails "$checks")
expect_eq "the merge queue rule: squash, all green, small groups, a check timeout, nobody bypasses" \
  "$(jq -c '[[.rules[].type], (.rules[] | select(.type == "merge_queue") | .parameters), .bypass_actors]' <<<"$queued_rules")" \
  '[["deletion","non_fast_forward","required_linear_history","pull_request","required_status_checks","merge_queue"],{"merge_method":"SQUASH","grouping_strategy":"ALLGREEN","max_entries_to_build":3,"max_entries_to_merge":3,"min_entries_to_merge":1,"min_entries_to_merge_wait_minutes":5,"check_response_timeout_minutes":60},[]]'
expect_eq "the queued ruleset keeps every rule of the branch ruleset" \
  "$(jq -c '.rules |= map(select(.type != "merge_queue"))' <<<"$queued_rules")" "$(branch_ruleset agent-guardrails "$checks")"
expect_eq "a live ruleset says whether it has the queue" \
  "$(ruleset_has_merge_queue <<<"$queued_rules") $(branch_ruleset agent-guardrails "$checks" | ruleset_has_merge_queue) $(ruleset_has_merge_queue </dev/null)" \
  "true false false"
expect_eq "an organization's repository in review mode can have the queue" "$(merge_queue_refusal acme/team Organization review)" ""
expect_eq "a personal repository cannot" "$(merge_queue_refusal owner/mine User review | cut -d, -f1)" \
  "owner/mine belongs to a personal account"
expect_eq "status mode cannot" "$(merge_queue_refusal acme/team Organization status | cut -d: -f1)" \
  "the merge queue needs review mode"

echo "rulesets and CODEOWNERS"
checks=$(pinned_checks $'checks-node\n')
expect_eq "checks pinned to GitHub Actions" "$checks" \
  '[{"context":"guard","integration_id":15368},{"context":"security","integration_id":15368},{"context":"checks-node","integration_id":15368}]'
status_rules=$(status_mode_ruleset agent-guardrails "$checks")
expect_eq "status mode requires merge-approval, no review" \
  "$(jq -c '[(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks | map(.context)),
    (.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count), .bypass_actors]' <<<"$status_rules")" \
  '[["guard","security","checks-node","merge-approval"],0,[]]'
branch_rules=$(branch_ruleset agent-guardrails "$checks")
expect_eq "review mode's branch ruleset: the checks, no merge-approval, nobody bypasses" \
  "$(jq -c '[(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks | map(.context)),
    .bypass_actors]' <<<"$branch_rules")" '[["guard","security","checks-node"],[]]'
expect_eq "both modes keep history linear and the branch undeletable" \
  "$(jq -c '[.rules[].type]' <<<"$branch_rules") $(jq -c '[.rules[].type]' <<<"$status_rules")" \
  '["deletion","non_fast_forward","required_linear_history","pull_request","required_status_checks"] ["deletion","non_fast_forward","required_linear_history","pull_request","required_status_checks"]'
review_rules=$(review_ruleset agent-guardrails-review)
expect_eq "the review ruleset holds only a fresh code owner review" \
  "$(jq -c '[[.rules[].type], (.rules[0].parameters
      | [.required_approving_review_count, .require_code_owner_review, .dismiss_stale_reviews_on_push, .require_last_push_approval])]' \
    <<<"$review_rules")" '[["pull_request"],[1,true,true,true]]'
expect_eq "only admins bypass the review, and only through a PR" "$(jq -c .bypass_actors <<<"$review_rules")" \
  '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]'
expect_eq "approval mode of each ruleset" \
  "$(for r in "$status_rules" "$branch_rules" "$review_rules"; do ruleset_approval_mode main <<<"$r"; done | tr '\n' ' ')" \
  "status - review "
expect_eq "a weakened review ruleset is no approval mode" \
  "$(jq -c '.rules[0].parameters.dismiss_stale_reviews_on_push = false' <<<"$review_rules" | ruleset_approval_mode main) $(
    jq -c '.enforcement = "evaluate"' <<<"$status_rules" | ruleset_approval_mode main)" "- -"
expect_eq "a ruleset that does not target the default branch is no approval mode" \
  "$(jq -c '.target = "tag"' <<<"$review_rules" | ruleset_approval_mode main) $(
    jq -c '.conditions.ref_name.exclude = ["refs/heads/main"]' <<<"$status_rules" | ruleset_approval_mode main) $(
    jq -c '.conditions.ref_name.include = ["refs/heads/main"]' <<<"$status_rules" | ruleset_approval_mode trunk)" "- - -"
# Approval mode applies the bypass lists `guardrails on` sets, like ruleset_problems: an approval is no protection
# when someone else may skip the rule that requires it.
expect_eq "a ruleset with a bypass list other than the kit's is no approval mode" \
  "$(jq -c '.bypass_actors = [{actor_id: 123, actor_type: "Integration", bypass_mode: "always"}]' <<<"$status_rules" |
    ruleset_approval_mode main) $(
    jq -c '.bypass_actors += [{actor_id: 123, actor_type: "Integration", bypass_mode: "always"}]' <<<"$review_rules" |
      ruleset_approval_mode main) $(jq -c '.bypass_actors = []' <<<"$review_rules" | ruleset_approval_mode main)" "- - -"
expect_eq "tags: every tag, admins only" "$(tag_ruleset agent-guardrails-tags | jq -c '[.target, .conditions.ref_name.include, [.rules[].type], .bypass_actors[0].bypass_mode]')" \
  '["tag",["~ALL"],["creation","update","deletion"],"always"]'
owners="$work/owners"
mkdir -p "$owners/.github" "$owners/docs"
expect_eq "missing CODEOWNERS" "$(codeowners_problems "$owners" Alice)" \
  "no CODEOWNERS file; add .github/CODEOWNERS whose first line is: * @Alice"
printf '# owners\n\n* @alice @acme/devs\nsrc/pay/ @acme/payments\n' >"$owners/.github/CODEOWNERS"
printf 'docs/\n' >"$owners/docs/CODEOWNERS"
expect_eq "catch-all owned by the login (any case) is usable; later files are ignored" "$(codeowners_problems "$owners" Alice)" ""
printf '* @bob\n' >"$owners/.github/CODEOWNERS"
expect_eq "catch-all owned by someone else" "$(codeowners_problems "$owners" alice)" \
  '.github/CODEOWNERS: the first rule must be "* @alice" (found "* @bob")'
printf 'src/ @alice\n* @alice\n' >"$owners/.github/CODEOWNERS"
expect_eq "catch-all not first" "$(codeowners_problems "$owners" alice)" \
  '.github/CODEOWNERS: the first rule must be "* @alice" (found "src/ @alice")'
printf '* @alice\nvendor/\n' >"$owners/.github/CODEOWNERS"
expect_eq "a rule without owners" "$(codeowners_problems "$owners" alice)" \
  '.github/CODEOWNERS: "vendor/" names no owner, so its paths need no code owner review'
printf '* # @alice\nvendor/ # @alice\nmy\\ dir/\nlib/ dev@acme.dev\r\n' >"$owners/.github/CODEOWNERS"
expect_eq "owners inside comments do not count; escaped spaces stay in the pattern; emails are owners" \
  "$(codeowners_problems "$owners" alice)" '.github/CODEOWNERS: the first rule must be "* @alice" (found "*")
.github/CODEOWNERS: "*" names no owner, so its paths need no code owner review
.github/CODEOWNERS: "vendor/" names no owner, so its paths need no code owner review
.github/CODEOWNERS: "my\ dir/" names no owner, so its paths need no code owner review'
printf '# only comments\n' >"$owners/.github/CODEOWNERS"
expect_eq "a file without rules" "$(codeowners_problems "$owners" alice)" \
  '.github/CODEOWNERS: no rules; its first line must be "* @alice"'
rm "$owners/.github/CODEOWNERS"
printf '* @alice\n' >"$owners/CODEOWNERS"
expect_eq "root CODEOWNERS is used before docs/" "$(codeowners_problems "$owners" alice)" ""
reviewed=$(jq -c '[.[] | select(.url == "u3" or .url == "u7") | .reviewDecision = "APPROVED"]' <<<"$fixture" |
  pr_states "[]" | jq -r .kind | tr '\n' ' ')
expect_eq "review mode: an approving review decision counts as approved" "$reviewed" "approved approved "
pending=$(jq -c '[.[] | select(.url == "u3") | .reviewDecision = "REVIEW_REQUIRED"]' <<<"$fixture" | pr_states "[]" | jq -r .kind)
expect_eq "review mode: a required review still waits for the owner" "$pending" "approve"

echo "graphql_with_retry"
# A fake gh fails as GitHub does on a timed-out query until $FLAKY_FAILS calls have failed.
flaky_bin="$work/flaky-bin"
mkdir -p "$flaky_bin"
# shellcheck disable=SC2016 # the lines are the fake's source and expand when it runs
printf '%s\n' '#!/usr/bin/env bash' \
  'n=$(($(cat "$FLAKY_COUNT") + 1)); echo "$n" >"$FLAKY_COUNT"' \
  'if [[ $n -le $FLAKY_FAILS ]]; then echo "invalid character '"'<'"' looking for beginning of value" >&2; exit 1; fi' \
  'printf "{\"a\":1}\n{\"a\":2}\n"' >"$flaky_bin/gh"
chmod +x "$flaky_bin/gh"
flaky() {
  echo 0 >"$work/flaky-count"
  (PATH="$flaky_bin:$PATH" FLAKY_COUNT="$work/flaky-count" FLAKY_FAILS=$1 graphql_with_retry 3 0 'query' '.') 2>"$work/flaky-err"
}
expect_eq "a failed attempt is retried" "$(flaky 2)" $'{"a":1}\n{"a":2}'
expect_eq "one warning per failed attempt" "$(grep -c '^warning: ' "$work/flaky-err")" 2
if flaky 3 >/dev/null; then fail "three failures stop the query"; else ok; fi
expect_eq "the final error names the attempts and the last error" "$(tail -1 "$work/flaky-err")" \
  "error: GitHub did not answer the GraphQL query after 3 attempts. Last error: invalid character '<' looking for beginning of value"

bare_home="$work/bare-home"
mkdir -p "$bare_home"
expect_eq "no kit: gh is blocked" "$(run_shim "$bare_home" 'gh pr create --title x')" 2
expect_eq "no kit: git push is blocked" "$(run_shim "$bare_home" 'git push -u origin feat/x')" 2
expect_eq "no kit: other commands run" "$(run_shim "$bare_home" 'make check')" 0
kit_home="$work/kit-home"
mkdir -p "$kit_home/.claude/skills"
ln -s "$kit/skills/guardrails-init" "$kit_home/.claude/skills/guardrails-init"
expect_eq "kit installed: its bash-guard decides (allowed)" "$(run_shim "$kit_home" 'gh pr create --title x')" 0
expect_eq "kit installed: its bash-guard decides (blocked)" "$(run_shim "$kit_home" 'gh pr merge 1 --admin')" 2
expect_eq "kit installed: owner commands blocked" "$(run_shim "$kit_home" 'guardrails off acme/shop')" 2

echo "project Cursor shim"
cursor_shim="$template/.agent/hooks/cursor-guard.sh"
# Prints the permission the shim answers. Arguments: HOME, the hook input as a jq filter over $d (the project).
run_cursor_shim() {
  jq -n -c --arg d "$shim_project" "$2" | HOME=$1 "$cursor_shim" 2>/dev/null | jq -r .permission
}
# shellcheck disable=SC2016 # $d is a jq variable
shell_input() {
  printf '{hook_event_name: "beforeShellExecution", workspace_roots: [$d], cwd: $d, command: "%s"}' "$1"
}
# shellcheck disable=SC2016 # $d is a jq variable
read_input() {
  printf '{hook_event_name: "beforeReadFile", workspace_roots: [$d], file_path: "%s", content: ""}' "$1"
}
expect_eq "kit files point Cursor at the shim" "$(jq -r '[.hooks[][].command] | unique | .[]' "$shim_project/.cursor/hooks.json")" \
  ".agent/hooks/cursor-guard.sh"
expect_eq "no kit: gh is denied" "$(run_cursor_shim "$bare_home" "$(shell_input 'gh pr create --title x')")" deny
expect_eq "no kit: git push is denied" "$(run_cursor_shim "$bare_home" "$(shell_input 'git push -u origin feat/x')")" deny
expect_eq "no kit: other commands run" "$(run_cursor_shim "$bare_home" "$(shell_input 'make check')")" allow
expect_eq "no kit: reads run" "$(run_cursor_shim "$bare_home" "$(read_input "$shim_project/README.md")")" allow
expect_eq "kit installed: its guard decides (allowed)" "$(run_cursor_shim "$kit_home" "$(shell_input 'gh pr create --title x')")" allow
expect_eq "kit installed: its guard decides (blocked)" "$(run_cursor_shim "$kit_home" "$(shell_input 'gh pr merge 1 --admin')")" deny
old_kit="$work/old-kit"
mkdir -p "$old_kit/hooks-global" "$old_kit/skills/guardrails-init" "$work/old-kit-home/.claude/skills"
cp "$kit/hooks-global/bash-guard.sh" "$old_kit/hooks-global/"
ln -s "$old_kit/skills/guardrails-init" "$work/old-kit-home/.claude/skills/guardrails-init"
expect_eq "kit without cursor-guard: shell commands denied" \
  "$(run_cursor_shim "$work/old-kit-home" "$(shell_input 'make check')")" deny
expect_eq "kit installed: credential reads denied" \
  "$(run_cursor_shim "$kit_home" "$(read_input "$kit_home/.config/gh/hosts.yml")")" deny

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
