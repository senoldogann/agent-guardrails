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
  mkdir -p "$dir/.github/workflows" "$dir/.claude" "$dir/specs/ABC-1" "$dir/src"
  cp -R "$template/.agent" "$dir/.agent"
  cp "$template/.claude/settings.json" "$dir/.claude/settings.json"
  cp "$template/.github/workflows/agent-guard.yml" "$dir/.github/workflows/"
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
expect_eq "edited workflows are drift" "$(kit_drift "$project")" "differs or missing: .github/workflows/agent-guard.yml
differs from the kit: .github/workflows/checks-node.yml"
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
expect_eq "check jobs come from the workflows" "$(check_jobs "$(new_project jobs)")" "checks-node"

echo "remove_kit_files"
project=$(new_project remove)
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
notes=$(remove_kit_files "$project")
expect_eq "legacy section removed up to the next heading" "$(cat "$project/AGENTS.md")" "# shop

## Deploy

make deploy"
expect_eq "customised files are kept and noted" "$notes" "kept (differs from the kit, remove the kit hooks by hand): .claude/settings.json
edited (kit include removed; targets that called .agent/ scripts need a look): Makefile
kept (decided requirements stay as documentation): specs/"
if grep -F 'include .agent/common.mk' "$project/Makefile" >/dev/null; then fail "kit include left in Makefile"; else ok; fi

echo "classify_prs"
fixture='[
 {"url":"u1","title":"spec(A-1): x","isDraft":true,"labels":[{"name":"needs-decision"}],"statusCheckRollup":[]},
 {"url":"u2","title":"spec(A-2): wip","isDraft":true,"labels":[],"statusCheckRollup":[]},
 {"url":"u3","title":"feat(A-3): ready","isDraft":false,"labels":[],"statusCheckRollup":[
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
   {"__typename":"StatusContext","context":"merge-approval","state":"FAILURE","createdAt":"2026-01-02T00:00:00Z"}]}
]'
tab=$'\t'
expect_eq "inbox items" "$(classify_prs <<<"$fixture")" "answer${tab}u1${tab}spec(A-1): x${tab}the agent is waiting for your decision
approve${tab}u3${tab}feat(A-3): ready${tab}checks running
blocked${tab}u5${tab}feat(A-5): bad${tab}guard failed: the agent has to fix the PR
wait${tab}u6${tab}feat(A-6): new${tab}guard is running
approve${tab}u7${tab}feat(A-7): revoked${tab}checks green"

echo "pr_states"
expect_eq "every open PR has a kind" "$(pr_states <<<"$fixture" | jq -r '"\(.url) \(.kind)"' | tr '\n' ' ')" \
  "u1 answer u2 draft u3 approve u4 approved u5 blocked u6 wait u7 approve "

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
  node acme/ready ADMIN '[]' '[]' "$own_setup"
  node acme/fork-pr ADMIN '[]' '[]' "$fork_setup"
  node acme/stranger ADMIN '[]' '[]' "$stranger_setup"
  node acme/readonly WRITE '[]' '[]' '[]'
)
expect_eq "project states" "$(project_states owner $'acme/on\nacme/disabled' <<<"$nodes" | jq -r '"\(.repo) \(.state)"' | tr '\n' ' ')" \
  "acme/on on Acme/Disabled alarm acme/tagged alarm acme/ready ready acme/fork-pr off acme/stranger off acme/readonly no-admin "
expect_eq "a ready project carries its set-up PR" \
  "$(project_states owner '' <<<"$nodes" | jq -r 'select(.state == "ready") | .setupURL')" "https://github.com/acme/ready/pull/1"

echo "events for the app"
expect_eq "no events without the descriptor" "$(GUARDRAILS_EVENTS_FD='' emit_event '{"event":"x"}' 3>&1)" ""
expect_eq "events go to the named descriptor" "$(GUARDRAILS_EVENTS_FD=3 emit_event '{"event":"x"}' 3>&1 >/dev/null)" '{"event":"x"}'
expect_eq "only descriptors 3-9 are used" "$(GUARDRAILS_EVENTS_FD=1 emit_event '{"event":"x"}')" ""
expect_eq "files as JSON" "$(printf '!!\t.github/workflows/x.yml\n\tsrc/a b.ts\n' | files_json)" \
  '[{"marker":"!!","path":".github/workflows/x.yml"},{"marker":"","path":"src/a b.ts"}]'

# A fake gh on PATH answers the calls of bin/guardrails and pr_files from fixtures.
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case $args in
  "api user --jq .login") echo owner ;;
  "search repos "*) printf 'acme/shop\nacme/lost\n' ;;
  "api repos/acme/shop/rulesets "*) echo active ;;
  "api repos/acme/off/rulesets "*) echo "" ;;
  "pr list -R acme/shop "*) cat "$FAKE_PRS" ;;
  "pr list -R acme/off "*) echo '[]' ;;
  "search prs "*) printf 'acme/new\thttps://github.com/acme/new/pull/1\tchore: install the kit\n' ;;
  "api --paginate repos/acme/shop/pulls/1/files"*) printf 'src/a.ts\n' ;;
  "api --paginate repos/acme/shop/pulls/2/files"*) printf 'src/a.ts\ncontrol-character src/??fake\n' ;;
  *) echo "fake gh: unexpected call: $args" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/gh"
printf '%s' "$fixture" >"$work/prs.json"
fake_home="$work/fake-home"
mkdir -p "$fake_home/.config/agent-guardrails"
printf 'acme/shop\nacme/off\n' >"$fake_home/.config/agent-guardrails/repos"
run_cli() { HOME=$fake_home PATH="$fake_bin:$PATH" FAKE_PRS="$work/prs.json" "$kit/bin/guardrails" "$@" 2>&1; }
# Lines about the kit install itself depend on this checkout and the network; the tests skip them.
inbox_text=$(run_cli inbox | grep -v 'kit install\|kit origin')
expect_eq "inbox text" "$inbox_text" "ALARM  acme/lost carries the agent-guardrails topic but is not in $fake_home/.config/agent-guardrails/repos. If you did not remove it, restore with: guardrails on acme/lost
ALARM  acme/off: ruleset missing. If you did not change it, check the audit log; restore with: guardrails on acme/off

acme/shop
  answer   spec(A-1): x
           u1 (the agent is waiting for your decision)
  approve  feat(A-3): ready (checks running)
           approve-head u3
  blocked  feat(A-5): bad (guard failed: the agent has to fix the PR)
  wait     feat(A-6): new (guard is running)
  approve  feat(A-7): revoked (checks green)
           approve-head u7

Not enforced yet
  turn on  chore: install the kit
           guardrails on https://github.com/acme/new/pull/1"
inbox_json=$(run_cli inbox --json | jq -c 'select(.repo != "")')
expect_eq "inbox json" "$inbox_json" '{"kind":"alarm","repo":"acme/lost","url":"","title":"","note":"acme/lost carries the agent-guardrails topic but is not in '"$fake_home"'/.config/agent-guardrails/repos. If you did not remove it, restore with: guardrails on acme/lost"}
{"kind":"repo","repo":"acme/shop","url":"","title":"","note":"active"}
{"kind":"answer","repo":"acme/shop","url":"u1","title":"spec(A-1): x","note":"the agent is waiting for your decision"}
{"kind":"approve","repo":"acme/shop","url":"u3","title":"feat(A-3): ready","note":"checks running"}
{"kind":"blocked","repo":"acme/shop","url":"u5","title":"feat(A-5): bad","note":"guard failed: the agent has to fix the PR"}
{"kind":"wait","repo":"acme/shop","url":"u6","title":"feat(A-6): new","note":"guard is running"}
{"kind":"approve","repo":"acme/shop","url":"u7","title":"feat(A-7): revoked","note":"checks green"}
{"kind":"repo","repo":"acme/off","url":"","title":"","note":"missing"}
{"kind":"alarm","repo":"acme/off","url":"","title":"","note":"acme/off: ruleset missing. If you did not change it, check the audit log; restore with: guardrails on acme/off"}
{"kind":"turn-on","repo":"acme/new","url":"https://github.com/acme/new/pull/1","title":"chore: install the kit","note":""}'

echo "pr_files"
expect_eq "plain file names pass" "$(PATH="$fake_bin:$PATH" pr_files acme/shop 1)" "src/a.ts"
if (PATH="$fake_bin:$PATH" pr_files acme/shop 2 >/dev/null 2>&1); then
  fail "a file name with control characters must be refused"
else ok; fi

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

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
