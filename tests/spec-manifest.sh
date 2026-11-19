#!/usr/bin/env bash
# Exercise the checked-in PR and queue guard entry points against Git objects.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
bin="$kit/skills/guardrails-init/template/.agent/bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q -b main "$work/repo"
cd "$work/repo"
git config user.email fixture@example.invalid
git config user.name fixture
git config commit.gpgsign false

dir=specs/T-1
mkdir -p "$dir" tests src
printf 'tests/unit.txt\nsrc/contract.txt\n' >"$dir/locked-files"
printf 'src/implementation.txt\n' >"$dir/write-allow"
printf '%s\n' '- AC-1: fixture' >"$dir/acceptance-criteria.md"
printf 'No open questions.\n' >"$dir/OPEN_QUESTIONS.md"
printf 'tests/unit.txt::AC-1\n' >"$dir/tests.lock"
printf 'test\n' >tests/unit.txt
printf 'contract\n' >src/contract.txt
manifest() {
  shasum -a 256 "$dir/locked-files" "$dir/write-allow" "$dir/acceptance-criteria.md" \
    "$dir/OPEN_QUESTIONS.md" "$dir/tests.lock" tests/unit.txt "$@" >"$dir/spec.lock"
}
manifest src/contract.txt
git add -A
git commit -qm baseline
base=$(git rev-parse HEAD)

check_guards() {
  local expected=$1 head guard status
  head=$(git rev-parse HEAD)
  jq -n --arg base "$base" --arg head "$head" \
    '{merge_group:{base_sha:$base,head_sha:$head,base_ref:"refs/heads/main"},repository:{default_branch:"main"}}' \
    >"$work/event.json"
  for guard in pr queue; do
    status=0
    if [[ $guard == pr ]]; then
      "$bin/ci-guard" "$base" "$head" feat/T-1-fixture main main >"$work/out" 2>&1 || status=$?
    else
      "$bin/ci-guard-group" "$work/event.json" >"$work/out" 2>&1 || status=$?
    fi
    if [[ -z $expected && $status -eq 0 ]]; then continue; fi
    if [[ -n $expected && $status -ne 0 ]] && grep -F -- "$expected" "$work/out" >/dev/null; then continue; fi
    printf '%s guard: unexpected result (exit %s, expected diagnostic: %s)\n' "$guard" "$status" "$expected" >&2
    cat "$work/out" >&2
    exit 1
  done
}

printf 'implementation\n' >src/implementation.txt
git add -A
git commit -qm implementation
check_guards ''

printf 'tests/unit.txt\n' >"$dir/locked-files"
manifest
git add -A
git commit -qm narrower-manifest
git commit -qm after-manifest --allow-empty
check_guards 'spec lock scope reduced: specs/T-1/spec.lock no longer covers src/contract.txt'

git rm -q "$dir/spec.lock"
git commit -qm remove-manifest
check_guards 'missing or invalid spec lock: specs/T-1/spec.lock'
printf '%s\n' 'PR and merge queue spec manifest regression checks passed.'
