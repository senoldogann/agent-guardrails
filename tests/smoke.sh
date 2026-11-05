#!/usr/bin/env bash
# Smoke tests for the template scripts and hooks against a throwaway git repository with a fake
# language Makefile (test IDs and results come from fixture files instead of a real test runner).
set -euo pipefail

kit=$(cd "$(dirname "$0")/.." && pwd -P)
template="$kit/skills/guardrails-init/template"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
fake_home="$work/home"
mkdir -p "$repo" "$fake_home/.claude"

passed=0
failed=0
ok() {
  passed=$((passed + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  failed=$((failed + 1))
  printf '  FAIL %s\n' "$1"
}
show_out() { sed 's/^/       /' "$work/out"; }
expect_success() {
  local name=$1
  shift
  if "$@" >"$work/out" 2>&1; then ok "$name"; else
    fail "$name"
    show_out
  fi
}
expect_failure() {
  local name=$1
  shift
  if "$@" >"$work/out" 2>&1; then
    fail "$name (unexpectedly succeeded)"
    show_out
  else ok "$name"; fi
}
expect_exit() {
  local name=$1 code=$2 actual
  shift 2
  set +e
  "$@" >"$work/out" 2>&1
  actual=$?
  set -e
  if [[ $actual -eq $code ]]; then ok "$name"; else
    fail "$name (exit $actual, want $code)"
    show_out
  fi
}
expect_out() {
  local name=$1 needle=$2
  if grep -F -- "$needle" "$work/out" >/dev/null; then ok "$name"; else
    fail "$name (missing '$needle')"
    show_out
  fi
}

guard() {
  printf '{"tool_input":{"file_path":"%s"}}' "$1" |
    HOME="$fake_home" CLAUDE_PROJECT_DIR="$repo" "$repo/.agent/hooks/write-guard.sh"
}
stop_hook() {
  printf '{"session_id":"s1","stop_hook_active":false}' |
    CLAUDE_PROJECT_DIR="$repo" "$repo/.agent/hooks/stop-check.sh"
}
implement() { printf '// IMPLEMENTED\nexport {};\n' >src/domain/percent.ts; }
unimplement() { printf 'export {};\n' >src/domain/percent.ts; }
ci_guard() {
  local head=$1 branch=$2 pr_base=$3 base
  base=$(git merge-base main "$head")
  .agent/bin/ci-guard "$base" "$head" "$branch" main "$pr_base"
}

cd "$repo"
git init -q -b main
git config user.email smoke@example.invalid
git config user.name smoke
cp -R "$template/.agent" .agent
printf '@AGENTS.md\n' >CLAUDE.md
printf '# Project\n\nCurrent state only. API version 2023-06-01 is fine in prose.\n' >AGENTS.md
cat >Makefile <<'EOF'
include .agent/common.mk
typecheck lint fmt-check: ; @echo "$@ ok"
test-ids: ; @cat fixture-ids
test:
	@mkdir -p .agent/reports/results
	@if grep -q IMPLEMENTED src/domain/percent.ts || grep -q WEAK src/domain/percent.prop.test.ts; then s=passed; m=''; else s=failed; m='Error: NotImplemented: makePercent'; fi; \
	{ grep '^src/domain/percent.prop.test.ts::' fixture-ids | while IFS= read -r id; do printf '%s\t%s\t%s\n' "$$id" "$$s" "$$m"; done; \
	  printf '%s\t%s\t%s\n' 'src/other.test.ts::unit' passed ''; } >.agent/reports/results/test.tsv; \
	[ "$$s" = passed ]
test-prop: test
EOF
printf '%s\n' 'src/domain/percent.prop.test.ts::AC-1: zero discount keeps price' \
  'src/domain/percent.prop.test.ts::AC-2: full discount gives zero' 'src/other.test.ts::unit' >fixture-ids
mkdir -p src/domain specs/ABC-1
printf 'export {};\n' >src/domain/percent.contract.ts
printf 'export {};\n' >src/domain/percent.ts
printf 'test\n' >src/domain/percent.prop.test.ts
printf 'test\n' >src/other.test.ts
printf -- '- AC-1: zero discount keeps price\n- AC-2: 100%% discount gives zero\n' >specs/ABC-1/acceptance-criteria.md
printf '## Q1: Rounding?\nDecision:\n' >specs/ABC-1/OPEN_QUESTIONS.md
printf 'src/domain/percent.contract.ts\nsrc/domain/percent.prop.test.ts\n' >specs/ABC-1/locked-files
printf 'src/domain/percent.ts\n' >specs/ABC-1/write-allow
cp "$template/gitignore.append" .gitignore
git add AGENTS.md CLAUDE.md .gitignore && git commit -qm init

echo "questions-check"
expect_failure "empty decision fails" .agent/bin/questions-check ABC-1
printf '## Q1: Rounding?\nDecision: tbd\n' >specs/ABC-1/OPEN_QUESTIONS.md
expect_failure "lowercase tbd fails" .agent/bin/questions-check ABC-1
printf '## Q1: Rounding?\ndecision: half-even\n### Q 2: Currency?\nDecision:\n' >specs/ABC-1/OPEN_QUESTIONS.md
expect_failure "'### Q 2' heading is checked too" .agent/bin/questions-check ABC-1
printf '## Q1: Rounding?\nDecision: half-even to 2 decimals\n' >specs/ABC-1/OPEN_QUESTIONS.md
expect_success "decided question passes" .agent/bin/questions-check ABC-1

echo "questions-lint"
expect_failure "question without recommendation and evidence fails" .agent/bin/questions-lint ABC-1
printf '## Q1: Rounding?\nOptions: A) half-even / B) half-up\nRecommendation: A because ledgers sum many lines\nDecision: half-even to 2 decimals\n' >specs/ABC-1/OPEN_QUESTIONS.md
expect_failure "question without evidence fails" .agent/bin/questions-lint ABC-1
printf '## Q1: Rounding?\nOptions: A) half-even / B) half-up\nRecommendation: A because ledgers sum many lines\nEvidence: IEEE 754 default rounding\nDecision: half-even to 2 decimals\n' >specs/ABC-1/OPEN_QUESTIONS.md
expect_success "question with recommendation and evidence passes" .agent/bin/questions-lint ABC-1

echo "docs-check"
expect_success "prose dates allowed" .agent/bin/docs-check
printf 'Keep\n' >.gitignore
expect_failure "CLAUDE.local.md not ignored fails" .agent/bin/docs-check
cp "$template/gitignore.append" .gitignore
mkdir -p docs && printf '# Guide\n## History\n' >docs/guide.md && git add docs/guide.md
expect_failure "history heading in docs/ fails" .agent/bin/docs-check
git rm -q --cached docs/guide.md && rm -r docs
printf '## 2026-11-05 update\n' >>AGENTS.md
expect_failure "dated heading fails" .agent/bin/docs-check
printf '# Project\n\nCurrent state only.\n' >AGENTS.md
printf 'see AGENTS.md\n' >CLAUDE.md
expect_failure "CLAUDE.md not @AGENTS.md fails" .agent/bin/docs-check
printf '@AGENTS.md\n' >CLAUDE.md

echo "spec-lock"
git add -A && git commit -qm base
printf '*\n' >specs/ABC-1/write-allow
expect_failure "bare wildcard rejected" .agent/bin/spec-lock ABC-1
printf 'src/domain/*\n' >specs/ABC-1/write-allow
expect_failure "pattern covering a locked file rejected" .agent/bin/spec-lock ABC-1
printf 'src/*.ts\n' >specs/ABC-1/write-allow
expect_failure "pattern covering a test file rejected" .agent/bin/spec-lock ABC-1
printf 'src/domain/percent.ts\n' >specs/ABC-1/write-allow
expect_success "spec-lock succeeds" .agent/bin/spec-lock ABC-1
expect_out "tests.lock has the 2 locked tests" "and 2 tests"
expect_success "lock-verify passes" .agent/bin/lock-verify ABC-1
expect_success "tests-lock-check passes" .agent/bin/tests-lock-check
cp fixture-ids "$work/ids.bak"
grep -v 'AC-2' "$work/ids.bak" >fixture-ids
expect_failure "tests-lock-check catches a dropped locked test" .agent/bin/tests-lock-check
cp "$work/ids.bak" fixture-ids

echo "trace-check"
expect_success "every AC traced" .agent/bin/trace-check
printf -- '- AC-1: a\n- AC-2: b\n- AC-3: c\n' >specs/ABC-1/acceptance-criteria.md
expect_failure "AC without a locked test fails" .agent/bin/trace-check
printf -- '- AC-1: a\n' >specs/ABC-1/acceptance-criteria.md
expect_failure "test naming an unknown AC fails" .agent/bin/trace-check
printf -- '- AC-1: zero discount keeps price\n- AC-2: 100%% discount gives zero\n' >specs/ABC-1/acceptance-criteria.md
cp specs/ABC-1/tests.lock "$work/tl.bak"
printf '%s\n' 'src/domain/percent.prop.test.ts::AC-1 AC-2 covers both' >specs/ABC-1/tests.lock
expect_failure "one test naming two ACs fails" .agent/bin/trace-check
cp "$work/tl.bak" specs/ABC-1/tests.lock
printf 'Feature: d\n  Scenario Outline: x\n' >specs/ABC-1/d.feature
expect_failure "Scenario Outline in optional feature fails" .agent/bin/trace-check
printf 'Feature: d\n  @wip\n  Scenario: x\n' >specs/ABC-1/d.feature
expect_failure "@wip tag fails" .agent/bin/trace-check
rm specs/ABC-1/d.feature

echo "spec gate"
expect_success "check-spec passes while locked tests fail on NotImplemented" make --no-print-directory check-spec SPEC_TICKET=ABC-1
implement
expect_failure "check-spec fails when locked tests pass against stubs" make --no-print-directory check-spec SPEC_TICKET=ABC-1
expect_success "check passes when implemented" make --no-print-directory check
unimplement
expect_failure "check fails while not implemented" make --no-print-directory check

echo "write-guard (spec phase)"
expect_exit "inactive guard allows anything" 0 guard "$repo/AGENTS.md"
.agent/bin/start-spec ABC-1 >/dev/null
expect_exit "new file allowed" 0 guard "$repo/src/domain/discount.ts"
expect_exit "file created in this phase editable" 0 guard "$repo/src/domain/discount.ts"
expect_exit "existing unlocked file denied" 2 guard "$repo/src/domain/percent.ts"
expect_exit "own locked file editable when amending" 0 guard "$repo/src/domain/percent.prop.test.ts"
expect_exit "own specs dir allowed" 0 guard "$repo/specs/ABC-1/properties.md"
expect_exit "spec.lock denied" 2 guard "$repo/specs/ABC-1/spec.lock"
expect_exit "tests.lock denied" 2 guard "$repo/specs/ABC-1/tests.lock"
expect_exit "other ticket specs denied" 2 guard "$repo/specs/ABC-2/x.md"
expect_exit ".agent denied" 2 guard "$repo/.agent/active"
expect_exit "AGENTS.md denied" 2 guard "$repo/AGENTS.md"
expect_exit "home .claude dir denied" 2 guard "$fake_home/.claude/settings.json"
expect_exit "dot-dot path denied" 2 guard "$repo/src/../.agent/active"
implement
expect_failure "finish refuses while the spec gate fails" .agent/bin/finish
unimplement
expect_success "finish passes the spec gate" .agent/bin/finish

echo "write-guard (implement phase)"
expect_success "start-implement verifies and activates" .agent/bin/start-implement ABC-1
expect_exit "write-allowed file allowed" 0 guard "$repo/src/domain/percent.ts"
expect_exit "locked test denied" 2 guard "$repo/src/domain/percent.prop.test.ts"
expect_exit "locked contract denied" 2 guard "$repo/src/domain/percent.contract.ts"
expect_exit "file outside write-allow denied" 2 guard "$repo/src/other.ts"
expect_exit "human-owned config denied" 2 guard "$repo/src/domain/vitest.setup.ts"
expect_exit "specs denied" 2 guard "$repo/specs/ABC-1/OPEN_QUESTIONS.md"

echo "stop-check / block / report"
expect_exit "red checks block stop" 2 stop_hook
expect_out "stop message points to block" ".agent/bin/block"
expect_exit "second failure blocks" 2 stop_hook
expect_exit "third failure blocks" 2 stop_hook
expect_exit "fourth failure releases with warning" 0 stop_hook
expect_out "warning emitted" "systemMessage"
.agent/bin/block "Is rounding half-even?" >/dev/null
expect_exit "blocked agent may stop" 0 stop_hook
expect_out "question shown to the human" "Is rounding half-even?"
.agent/bin/unblock >/dev/null
implement
expect_exit "green checks allow stop" 0 stop_hook
expect_success "report-checks renders the fresh log" .agent/bin/report-checks ABC-1
expect_out "report is the real log" "ALL PASSED"
printf '// IMPLEMENTED\nexport const x = 1;\n' >src/domain/percent.ts
expect_failure "report-checks refuses a stale log" .agent/bin/report-checks ABC-1
implement
expect_success "finish passes the implement gate" .agent/bin/finish
unimplement
.agent/bin/start-spec ABC-1 >/dev/null
expect_success "abort leaves without a gate" .agent/bin/abort "ticket dropped"
if [[ ! -f .agent/active ]]; then ok "no active phase after abort"; else fail "no active phase after abort"; fi

echo "escape-check"
git add -A && git commit -qm "spec(ABC-1): lock"
expect_success "spec-commit-ticket names the locking commit" .agent/bin/spec-commit-ticket
expect_out "ticket detected" "ABC-1"
expect_success "clean ts passes" .agent/bin/escape-check ts
printf '// @ts-ignore\nexport {};\n' >src/domain/percent.ts
git add -A
expect_failure "@ts-ignore fails" .agent/bin/escape-check ts
git reset -q --hard
printf '#[expect(dead_code)]\nfn x() {}\n' >src/lib.rs
git add -A
expect_failure "rust #[expect] fails" .agent/bin/escape-check rs
git reset -q --hard

echo "ci-guard"
git checkout -q -b feat/ABC-1-impl
implement
git commit -qam "feat(ABC-1): implement"
expect_success "spec-commit-ticket is empty after implementation" .agent/bin/spec-commit-ticket
expect_success "implementation-only PR passes" ci_guard feat/ABC-1-impl feat/ABC-1-impl main
expect_out "no human-owned paths listed" "no human-owned paths changed"
expect_failure "PR not targeting the default branch fails" ci_guard feat/ABC-1-impl feat/ABC-1-impl release

git checkout -q -b feat/ABC-1-weaken
printf 'weakened\n' >src/domain/percent.prop.test.ts
git commit -qam weaken
expect_failure "changed locked test without re-lock fails" ci_guard feat/ABC-1-weaken feat/ABC-1-weaken main

git checkout -q feat/ABC-1-impl
git checkout -q -b feat/ABC-1-relock
printf 'WEAK\n' >src/domain/percent.prop.test.ts
git commit -qam weaken
.agent/bin/spec-lock ABC-1 >/dev/null
git add -A
git commit -qm relock
expect_failure "HEAD that is a spec commit fails the guard" ci_guard feat/ABC-1-relock feat/ABC-1-relock main
printf '// IMPLEMENTED\nexport const y = 2;\n' >src/domain/percent.ts
git commit -qam "feat(ABC-1): more"
expect_success "amended spec with implementation passes the guard" ci_guard feat/ABC-1-relock feat/ABC-1-relock main
expect_out "re-lock is flagged for review" "specs/ABC-1/spec.lock"

echo "ci-run"
git checkout -q feat/ABC-1-impl
expect_success "honest implementation passes ci-run" .agent/bin/ci-run main
git checkout -q feat/ABC-1-relock
expect_failure "test weakened and re-locked mid-PR fails ci-run (spec gate at the last lock)" .agent/bin/ci-run main
expect_out "spec gate ran at the re-lock commit" "=== spec gate for ABC-1"
if [[ -z $(git status --porcelain) ]]; then ok "ci-run restored HEAD"; else fail "ci-run restored HEAD"; fi

git checkout -q feat/ABC-1-impl
git checkout -q -b feat/ABC-1-symlink
ln -s ../other.test.ts src/domain/helper.ts
git add -A
git commit -qm symlink
expect_failure "symlink fails" ci_guard feat/ABC-1-symlink feat/ABC-1-symlink main

git checkout -q feat/ABC-1-impl
git checkout -q -b feat/ABC-1-vendor
mkdir -p src/domain/node_modules/fast-check
printf 'module.exports = {};\n' >src/domain/node_modules/fast-check/index.js
git add -A
git commit -qm vendor
expect_failure "nested node_modules fails" ci_guard feat/ABC-1-vendor feat/ABC-1-vendor main

git checkout -q feat/ABC-1-impl
git checkout -q -b feat/ABC-1-merge
git merge -q --no-ff -m merge feat/ABC-1-symlink
expect_failure "merge commit fails" ci_guard feat/ABC-1-merge feat/ABC-1-merge main

git checkout -q main
git checkout -q -b feat/ABC-2-two
mkdir -p specs/ABC-2 specs/ABC-3
printf 'x\n' >specs/ABC-2/a.md
printf 'x\n' >specs/ABC-3/a.md
git add -A
git commit -qm two
expect_failure "two tickets in one PR fail" ci_guard feat/ABC-2-two feat/ABC-2-two main
git checkout -q -b feat/ABC-2-one main
mkdir -p specs/ABC-2
printf 'x\n' >specs/ABC-2/a.md
git add -A
git commit -qm one
expect_failure "unlocked draft spec is not mergeable" ci_guard feat/ABC-2-one feat/ABC-2-one main
expect_out "draft reason is explained" "spec for ABC-2 is not locked yet"
expect_failure "branch not naming the ticket fails" ci_guard feat/ABC-2-one feat/other main
expect_out "branch mismatch is explained" "does not name ticket ABC-2"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
