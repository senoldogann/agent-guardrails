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
project=$(new_project remove)
printf 'semgrep rule src/a.ts # accepted by the owner\n' >"$project/.github/security-ignore"
notes=$(remove_kit_files "$project")
expect_eq "only specs is noted" "$notes" "kept (decided requirements stay as documentation): specs/"
expect_eq "files left" "$(cd "$project" && find . -type f | sort)" "./.github/workflows/release.yml
./AGENTS.md
./specs/ABC-1/acceptance-criteria.md
./src/index.ts"
expect_eq "AGENTS.md keeps the project part" "$(cat "$project/AGENTS.md")" "# shop

Setup: pnpm install"

project=$(new_project legacy)
{
  printf '# shop\n\n'
  sed '/agent-guardrails:start/d; /agent-guardrails:end/d' "$template/AGENTS.section.md"
  printf '\n## Deploy\n\nmake deploy\n'
} >"$project/AGENTS.md"
printf 'deploy:\n\t./deploy.sh\n' >>"$project/Makefile"
printf '{"hooks": {}}\n' >"$project/.claude/settings.json"
printf '{"version": 1, "hooks": {}}\n' >"$project/.cursor/hooks.json"
notes=$(remove_kit_files "$project")
expect_eq "legacy section removed up to the next heading" "$(cat "$project/AGENTS.md")" "# shop

## Deploy

make deploy"
expect_eq "customised files are kept and noted" "$notes" "kept (differs from the kit, remove the kit hooks by hand): .claude/settings.json
kept (differs from the kit, remove the kit hooks by hand): .cursor/hooks.json
edited (kit include removed; targets that called .agent/ scripts need a look): Makefile
kept (decided requirements stay as documentation): specs/"
if grep -F 'include .agent/common.mk' "$project/Makefile" >/dev/null; then fail "kit include left in Makefile"; else ok; fi

echo "grants_check_or_status_writes"
# Every spelling of a grant is found; read access, comments and look-alike keys are not.
while IFS= read -r spelling; do
  if printf 'permissions:\n%b\n' "$spelling" | grants_check_or_status_writes; then ok; else fail "missed a grant: $spelling"; fi
done <<'EOF'
  checks: write
  statuses: "write"
  checks: 'write'
  statuses: !!str write
  statuses:\n    write
  statuses: >-\n    write
  {statuses: write, contents: read}
  "checks": write
permissions: "write-all"
EOF
while IFS= read -r spelling; do
  if printf 'permissions:\n%b\n' "$spelling" | grants_check_or_status_writes; then fail "false grant: $spelling"; else ok; fi
done <<'EOF'
  checks: read
  statuses: none
  contents: write
  # statuses: write
jobs:\n  checks:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm run write-docs
EOF

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
  node acme/tagged ADMIN '[]' '["agent-guardrails"]' '[]'
  node acme/unlisted ADMIN "$active" '[]' '[]'
  node acme/ready ADMIN '[]' '[]' "$own_setup"
  node acme/fork-pr ADMIN '[]' '[]' "$fork_setup"
  node acme/stranger ADMIN '[]' '[]' "$stranger_setup"
  node acme/readonly WRITE '[]' '[]' '[]'
)
expect_eq "project states" "$(project_states owner $'acme/on\nacme/disabled' none '' <<<"$nodes" | jq -r '"\(.repo) \(.state)"' | tr '\n' ' ')" \
  "acme/on on Acme/Disabled alarm acme/tagged alarm acme/unlisted alarm acme/ready ready acme/fork-pr off acme/stranger off acme/readonly no-admin "
expect_eq "a ready project carries its bootstrap PR" \
  "$(project_states owner '' none '' <<<"$nodes" | jq -r 'select(.state == "ready") | .setupURL')" "https://github.com/acme/ready/pull/1"
review_nodes=$(
  node acme/reviewed ADMIN '[{"name":"agent-guardrails","enforcement":"ACTIVE"},{"name":"agent-guardrails-review","enforcement":"ACTIVE"}]' '[]' '[]'
  node acme/status ADMIN "$active" '[]' '[]'
  node acme/plain ADMIN '[]' '[]' '[]'
)
expect_eq "mode and agent App per project" \
  "$(project_states owner $'acme/reviewed\nacme/status' registered $'Acme/Reviewed\nacme/plain' <<<"$review_nodes" |
    jq -r '"\(.repo) \(.mode) \(.agentApp)"' | tr '\n' ' ')" \
  "acme/reviewed review installed acme/status status missing acme/plain null installed "
expect_eq "no agent App on this Mac" "$(project_states owner acme/status none '' <<<"$review_nodes" | jq -r .agentApp | sort -u)" "none"
queue_nodes=$(
  node acme/queued ADMIN '[{"name":"agent-guardrails","enforcement":"ACTIVE","rules":{"nodes":[{"type":"PULL_REQUEST"},{"type":"MERGE_QUEUE"}]}},
    {"name":"agent-guardrails-review","enforcement":"ACTIVE"}]' '[]' '[]' | jq -c '.owner = {__typename: "Organization"}'
  node acme/other-queue ADMIN '[{"name":"agent-guardrails","enforcement":"ACTIVE"},
    {"name":"theirs","enforcement":"ACTIVE","rules":{"nodes":[{"type":"MERGE_QUEUE"}]}}]' '[]' '[]' | jq -c '.owner = {__typename: "Organization"}'
  node owner/personal ADMIN "$active" '[]' '[]' | jq -c '.owner = {__typename: "User"}'
)
expect_eq "merge queue and organization per project" \
  "$(project_states owner $'acme/queued\nacme/other-queue\nowner/personal' registered '' <<<"$queue_nodes" |
    jq -r '"\(.repo) \(.mergeQueue) \(.organization)"' | tr '\n' ' ')" \
  "acme/queued true true acme/other-queue false true owner/personal false false "
expect_eq "an enforced repository GitHub could not read is an alarm, not a missing row" \
  "$(jq -n -c '{nameWithOwner: "acme/gone", unreadable: true, isFork: false, isPrivate: true, pushedAt: "",
      viewerPermission: "READ", pullRequests: {totalCount: 0}}' | project_states owner acme/gone none '' |
    jq -r '"\(.state) \(.private) \(.openPRs) \(.mergeQueue)"')" "alarm true 0 false"

echo "events for the app"
expect_eq "no events without the descriptor" "$(GUARDRAILS_EVENTS_FD='' emit_event '{"event":"x"}' 3>&1)" ""
expect_eq "events go to the named descriptor" "$(GUARDRAILS_EVENTS_FD=3 emit_event '{"event":"x"}' 3>&1 >/dev/null)" '{"event":"x"}'
expect_eq "only descriptors 3-9 are used" "$(GUARDRAILS_EVENTS_FD=1 emit_event '{"event":"x"}')" ""
expect_eq "files as JSON" "$(printf '!!\t.github/workflows/x.yml\n\tsrc/a b.ts\n' | files_json)" \
  '[{"marker":"!!","path":".github/workflows/x.yml"},{"marker":"","path":"src/a b.ts"}]'

# A fake gh on PATH answers the calls of bin/guardrails and pr_snapshot_files from fixtures.
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case $args in
  "api user --jq .login") echo owner ;;
  "search repos "*) printf 'acme/shop\nacme/lost\n' ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails")'*) echo 7 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-tags")'*) echo 9 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*) echo "" ;;
  "api repos/acme/shop/rulesets/7") cat "$FAKE_RULESETS/branch.json" ;;
  "api repos/acme/shop/rulesets/9") cat "$FAKE_RULESETS/tag.json" ;;
  "api --paginate repos/acme/off/rulesets"* | "api --paginate repos/acme/broken/rulesets"*) echo "" ;;
  "pr list -R acme/broken "*) echo "HTTP 502" >&2; exit 1 ;;
  "pr list -R acme/shop "*) cat "$FAKE_PRS" ;;
  "pr list -R acme/off "*) echo '[]' ;;
  "search prs "*) printf 'acme/new\thttps://github.com/acme/new/pull/1\tchore: install the kit\n' ;;
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
run_cli() { HOME=$fake_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" "$kit/bin/guardrails" "$@" 2>&1; }
# Lines about the kit install itself depend on this checkout and the network; the tests skip them.
inbox_text=$(run_cli inbox | grep -v 'kit install\|kit origin')
expect_eq "inbox text" "$inbox_text" "ALARM  acme/lost carries the agent-guardrails topic but is not in $fake_home/.config/agent-guardrails/repos. If you did not remove it, restore with: guardrails on acme/lost
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
expect_eq "inbox json" "$inbox_json" '{"kind":"alarm","repo":"acme/lost","url":"","title":"","note":"acme/lost carries the agent-guardrails topic but is not in '"$fake_home"'/.config/agent-guardrails/repos. If you did not remove it, restore with: guardrails on acme/lost","sha":""}
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
if usage_text=$(run_cli on --merge-queue); then
  fail "on without a target must be refused"
else
  expect_eq "the queue flag alone is no target" "$(grep -c -- '--merge-queue' <<<"$usage_text")" "1"
fi

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
  '{branch: $b, review: $v, tag: $t}')
expect_eq "the kit's own rulesets in review mode hold" "$(ruleset_problems <<<"$review_mode")" ""
expect_eq "status mode needs no review ruleset" "$(jq -c --argjson b "$(status_mode_ruleset agent-guardrails "$checks")" \
  '.branch = $b | .review = null' <<<"$review_mode" | ruleset_problems)" ""
expect_eq "a review ruleset that lets anyone bypass it, or is gone, is an alarm" "$(jq -c \
  '.review.bypass_actors += [{actor_id: 1, actor_type: "Integration", bypass_mode: "always"}]' <<<"$review_mode" | ruleset_problems)
$(jq -c '.review = null' <<<"$review_mode" | ruleset_problems)" \
  "the agent-guardrails-review ruleset has a changed bypass list
no ruleset requires your approval any more (neither merge-approval nor agent-guardrails-review)"
expect_eq "lost required checks and a bypass on the branch ruleset are alarms" "$(jq -c \
  '.branch.rules |= map(select(.type != "required_status_checks")) | .branch.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' \
  <<<"$review_mode" | ruleset_problems)" "the agent-guardrails ruleset has a bypass list
the agent-guardrails ruleset lost its required_status_checks rule
guard is no longer a required check from GitHub Actions
security is not a required check from GitHub Actions (a project set up before the kit had it needs a kit update PR first)
no checks-<lang> job is a required check from GitHub Actions any more"
expect_eq "a check reported by another App does not count" "$(jq -c \
  '(.branch.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(del(.integration_id))' \
  <<<"$review_mode" | ruleset_problems)" "guard is no longer a required check from GitHub Actions
security is not a required check from GitHub Actions (a project set up before the kit had it needs a kit update PR first)
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
  "$(for r in "$status_rules" "$branch_rules" "$review_rules"; do ruleset_approval_mode <<<"$r"; done | tr '\n' ' ')" \
  "status - review "
expect_eq "a weakened review ruleset is no approval mode" \
  "$(jq -c '.rules[0].parameters.dismiss_stale_reviews_on_push = false' <<<"$review_rules" | ruleset_approval_mode) $(
    jq -c '.enforcement = "evaluate"' <<<"$status_rules" | ruleset_approval_mode)" "- -"
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
