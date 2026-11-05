# shellcheck shell=bash
# Shared harness for tests/lang/*.sh: builds a throwaway project from the template and runs the
# evidence pipeline (test-ids -> make test -> results TSV -> verify-red / verify-green) against
# implementations the language script writes. Source it; do not execute it.

kit=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
template="$kit/skills/guardrails-init/template"
ticket=T-1

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

# Runs a command in the project, capturing its output in $project/.out; shows the output on failure.
expect_success() {
  local name=$1
  shift
  if (cd "$project" && "$@") >"$project/.out" 2>&1; then ok "$name"; else
    fail "$name"
    sed 's/^/       /' "$project/.out" | tail -40
  fi
}
expect_failure() {
  local name=$1
  shift
  if (cd "$project" && "$@") >"$project/.out" 2>&1; then
    fail "$name (unexpectedly succeeded)"
    sed 's/^/       /' "$project/.out" | tail -40
  else ok "$name"; fi
}
# Fails unless the last command's output contains a fixed string.
expect_output() {
  local name=$1 needle=$2
  if grep -F -- "$needle" "$project/.out" >/dev/null; then ok "$name"; else
    fail "$name (output lacks: $needle)"
    sed 's/^/       /' "$project/.out" | tail -40
  fi
}
# Fails unless the results TSV has a line for <id> with <status> whose message contains <needle>.
expect_result() {
  local name=$1 id=$2 status=$3 needle=$4
  if awk -F'\t' -v id="$id" -v status="$status" -v needle="$needle" \
    '$1 == id && $2 == status && index($3, needle) > 0 { found = 1 } END { exit !found }' \
    "$project/.agent/reports/results/test.tsv"; then ok "$name"; else
    fail "$name (no '$status' result for '$id' containing '$needle')"
    sed 's/^/       /' "$project/.agent/reports/results/test.tsv"
  fi
}

# Creates $project: a git repository with the template's .agent/ and the language Makefile.
new_project() {
  local lang=$1
  project=$(mktemp -d "${TMPDIR:-/tmp}/kit-lang-$lang.XXXXXX")
  cp -R "$template/.agent" "$project/.agent"
  cp "$template/makefiles/Makefile.$lang" "$project/Makefile"
  git -C "$project" init -q
}

# Locks the IDs from `make test-ids` that live in <locked test file>, exactly as spec-lock does,
# and checks them against the expected IDs given on stdin.
lock_tests() {
  local locked_file=$1 expected ids
  expected=$(cat)
  if ! ids=$(cd "$project" && make --no-print-directory -s test-ids 2>"$project/.out"); then
    fail "make test-ids"
    sed 's/^/       /' "$project/.out" | tail -40
    return
  fi
  ok "make test-ids"
  mkdir -p "$project/specs/$ticket"
  awk -F'::' -v file="$locked_file" '$1 == file' <<<"$ids" >"$project/specs/$ticket/tests.lock"
  if [[ $(cat "$project/specs/$ticket/tests.lock") == "$expected" ]]; then ok "locked test IDs are the expected ones"; else
    fail "locked test IDs are the expected ones"
    printf '       expected:\n%s\n       got (all IDs):\n%s\n' "$expected" "$ids" | sed 's/^/       /'
  fi
}

# The language-independent part: stub -> red, correct -> green, wrong -> not green.
# Arguments name the language script's functions that write each implementation.
run_red_green() {
  local write_stub=$1 write_correct=$2 write_wrong=$3
  "$write_stub"
  expect_failure "stub: make test fails" make --no-print-directory test
  expect_success "stub: verify-red passes" .agent/bin/verify-red "$ticket"
  expect_failure "stub: verify-green fails" .agent/bin/verify-green "$ticket"

  "$write_correct"
  expect_success "correct: make test passes" make --no-print-directory test
  expect_success "correct: verify-green passes" .agent/bin/verify-green "$ticket"
  expect_failure "correct: verify-red fails" .agent/bin/verify-red "$ticket"

  "$write_wrong"
  expect_failure "wrong: make test fails" make --no-print-directory test
  expect_failure "wrong: verify-green fails" .agent/bin/verify-green "$ticket"
  expect_failure "wrong: verify-red fails (failures are assertions, not NotImplemented)" .agent/bin/verify-red "$ticket"
}

finish() {
  printf '%s: %d passed, %d failed\n' "$1" "$passed" "$failed"
  if [[ $failed -eq 0 ]]; then rm -rf "$project"; else printf '  project kept at %s\n' "$project"; fi
  [[ $failed -eq 0 ]]
}
