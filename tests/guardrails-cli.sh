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
