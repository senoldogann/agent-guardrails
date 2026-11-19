#!/usr/bin/env bash
# Spec lock manifests through the real entry points: spec-lock writes the lock, lock-verify checks it locally, and
# both trusted guards (ci-guard for a PR, ci-guard-group for a merge queue's group commit) must reject a manifest
# that is empty, malformed, duplicated, outside the repository, incomplete, stale or removed, and must name every
# change of a lock's scope against the base for the owner, so that legitimate amendments pass in plain view.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
template="$kit/skills/guardrails-init/template"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
ok() {
  passed=$((passed + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  failed=$((failed + 1))
  printf '  FAIL %s\n' "$1"
  sed 's/^/       /' "$work/out"
}
# Runs both guards against HEAD of the current branch, judged against main (the merge base for the PR, the group's
# base for the queue). Arguments: name, "pass" or "fail", text the output of both must contain ("" for none).
expect_guards() {
  local name=$1 want=$2 needle=$3 head base status guard
  head=$(git rev-parse HEAD)
  base=$(git merge-base main "$head")
  jq -n --arg base "$base" --arg head "$head" \
    '{merge_group: {base_sha: $base, head_sha: $head, base_ref: "refs/heads/main"}, repository: {default_branch: "main"}}' \
    >"$work/event.json"
  for guard in ci-guard ci-guard-group; do
    status=0
    if [[ $guard == ci-guard ]]; then
      .agent/bin/ci-guard "$base" "$head" "$(git branch --show-current)" main main >"$work/out" 2>&1 || status=$?
    else
      .agent/bin/ci-guard-group "$work/event.json" >"$work/out" 2>&1 || status=$?
    fi
    if [[ $want == pass && $status -ne 0 ]] || [[ $want == fail && $status -eq 0 ]]; then
      fail "$guard: $name (exit $status, want $want)"
    elif [[ -n $needle ]] && ! grep -F -- "$needle" "$work/out" >/dev/null; then
      fail "$guard: $name (output lacks: $needle)"
    else
      ok "$guard: $name"
    fi
  done
}
expect_local() {
  local name=$1 want=$2 needle=$3 status=0
  .agent/bin/lock-verify T-1 >"$work/out" 2>&1 || status=$?
  if [[ $want == pass && $status -ne 0 ]] || [[ $want == fail && $status -eq 0 ]]; then
    fail "lock-verify: $name (exit $status, want $want)"
  elif [[ -n $needle ]] && ! grep -F -- "$needle" "$work/out" >/dev/null; then
    fail "lock-verify: $name (output lacks: $needle)"
  else
    ok "lock-verify: $name"
  fi
}
# Starts a PR branch from main. Argument: branch name.
branch() { git checkout -q -B "$1" main; }
commit() {
  git add -A
  git commit -qm "$1"
}
# The implementation commit after a re-lock: HEAD may not be the spec commit.
implement() {
  printf 'implementation %s\n' "$1" >src/impl.txt
  commit "feat(T-1): $1"
}
# Rewrites the committed manifest with an edit (a sed script), keeping every remaining checksum valid.
edit_manifest() {
  sed -E "$1" specs/T-1/spec.lock >"$work/lock"
  cp "$work/lock" specs/T-1/spec.lock
}

repo="$work/repo"
mkdir -p "$repo"
cd "$repo"
git init -q -b main
git config user.email fixture@example.invalid
git config user.name fixture
git config commit.gpgsign false
cp -R "$template/.agent" .agent
printf 'test-ids: ; @cat fixture-ids\n' >Makefile
printf '%s\n' 'tests/a.test.txt::AC-1 first' 'tests/b.test.txt::AC-2 second' 'tests/c.test.txt::AC-3 third' >fixture-ids
mkdir -p specs/T-1 src tests
printf 'a\n' >tests/a.test.txt
printf 'b\n' >tests/b.test.txt
printf 'c\n' >tests/c.test.txt
printf 'contract\n' >src/contract.txt
printf 'stub\n' >src/impl.txt
printf -- '- AC-1: first\n- AC-2: second\n- AC-3: third\n' >specs/T-1/acceptance-criteria.md
printf 'No open questions.\n' >specs/T-1/OPEN_QUESTIONS.md
printf 'tests/a.test.txt\ntests/b.test.txt\nsrc/contract.txt\n' >specs/T-1/locked-files
printf 'src/impl.txt\n' >specs/T-1/write-allow
.agent/bin/spec-lock T-1 >/dev/null
commit "spec(T-1): lock"
implement first

echo "spec-lock and lock-verify"
expect_local "the lock spec-lock wrote passes" pass ""
printf 'tests/a.test.txt\ntests/a.test.txt\n' >specs/T-1/locked-files
if .agent/bin/spec-lock T-1 >"$work/out" 2>&1; then fail "spec-lock refuses a locked file listed twice"; else ok "spec-lock refuses a locked file listed twice"; fi
printf 'tests/a.test.txt\n../outside.txt\n' >specs/T-1/locked-files
if .agent/bin/spec-lock T-1 >"$work/out" 2>&1; then fail "spec-lock refuses a path outside the repository"; else ok "spec-lock refuses a path outside the repository"; fi
if [[ -z $(git ls-files --others --exclude-standard) ]]; then ok "a refused spec-lock leaves no files behind"; else
  git ls-files --others --exclude-standard >"$work/out"
  fail "a refused spec-lock leaves no files behind"
fi
git checkout -q -- specs
edit_manifest '/tests\/b\.test\.txt$/d'
expect_local "an omitted locked file fails" fail "specs/T-1/spec.lock does not cover tests/b.test.txt"
git checkout -q -- specs

echo "valid lock"
branch feat/T-1-valid
implement second
expect_guards "a lock written by spec-lock passes" pass "no human-owned paths changed"

echo "omitted entries"
branch feat/T-1-omit-test
edit_manifest '/tests\/b\.test\.txt$/d'
commit "drop a locked test from the manifest"
implement omitted
expect_guards "a manifest without a declared locked file fails" fail \
  "spec lock specs/T-1/spec.lock does not cover tests/b.test.txt, which specs/T-1/locked-files declares"
branch feat/T-1-omit-meta
edit_manifest '/specs\/T-1\/tests\.lock$/d'
commit "drop tests.lock from the manifest"
implement omitted
expect_guards "a manifest without a metadata file fails" fail "spec lock specs/T-1/spec.lock does not cover specs/T-1/tests.lock"

echo "malformed and duplicate entries"
branch feat/T-1-empty
: >specs/T-1/spec.lock
commit "empty manifest"
implement empty
expect_guards "an empty manifest fails" fail "spec lock specs/T-1/spec.lock is empty"
branch feat/T-1-malformed
printf 'not a checksum line\n' >>specs/T-1/spec.lock
commit "malformed manifest"
implement malformed
expect_guards "a malformed line fails" fail "spec lock specs/T-1/spec.lock line 9 is not"
branch feat/T-1-outside
printf '%s  ../outside.txt\n' "$(printf 'x\n' | shasum -a 256 | cut -d' ' -f1)" >>specs/T-1/spec.lock
commit "path outside the repository"
implement outside
expect_guards "a path outside the repository fails" fail \
  "spec lock specs/T-1/spec.lock line 9 names '../outside.txt', which is not a plain repository-relative path"
branch feat/T-1-duplicate
entry=$(grep -F 'tests/a.test.txt' specs/T-1/spec.lock)
printf '%s\n' "$entry" >>specs/T-1/spec.lock
commit "duplicate entry"
implement duplicate
expect_guards "a duplicate entry fails" fail "spec lock specs/T-1/spec.lock lists tests/a.test.txt twice"
branch feat/T-1-extra
shasum -a 256 src/impl.txt >>specs/T-1/spec.lock
commit "undeclared entry"
implement extra
expect_guards "an entry nobody declared fails" fail \
  "spec lock specs/T-1/spec.lock lists src/impl.txt, which is neither spec metadata nor in specs/T-1/locked-files"

echo "checksums"
branch feat/T-1-mismatch
printf 'weakened\n' >tests/a.test.txt
commit "weaken a locked test"
expect_guards "a changed locked file fails" fail "lock mismatch: specs/T-1/spec.lock records tests/a.test.txt"

echo "scope against the base"
branch feat/T-1-removed
git rm -q specs/T-1/spec.lock
commit "remove the lock"
implement removed
expect_guards "removing a lock fails" fail "spec lock specs/T-1/spec.lock is on the base and missing at the head"
branch feat/T-1-reduced
printf 'tests/a.test.txt\nsrc/contract.txt\n' >specs/T-1/locked-files
.agent/bin/spec-lock T-1 >/dev/null
commit "spec(T-1): unlock tests/b.test.txt"
implement reduced
expect_guards "a re-lock that drops a locked file passes and names the reduction" pass \
  "  specs/T-1/spec.lock no longer locks tests/b.test.txt"
expect_guards "the owner sees the reduction under its own heading" pass "SPEC LOCK SCOPE CHANGED"

echo "legitimate amendment"
branch feat/T-1-amend
printf 'tests/a.test.txt\ntests/b.test.txt\ntests/c.test.txt\nsrc/contract.txt\n' >specs/T-1/locked-files
printf 'c amended\n' >tests/c.test.txt
.agent/bin/spec-lock T-1 >/dev/null
commit "spec(T-1): lock the third test"
implement amended
expect_guards "an amendment re-locked with spec-lock passes" pass "  specs/T-1/spec.lock now also locks tests/c.test.txt"
expect_local "the amended lock passes locally" pass ""

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
