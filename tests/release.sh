#!/usr/bin/env bash
# Tests the release inputs: VERSION is a semantic version with release notes in CHANGELOG.md, and
# scripts/release-notes.sh extracts one section and refuses a missing one.
# shellcheck disable=SC2016,SC2034 # check() evaluates its condition string, which uses these variables
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
check() {
  if eval "$2"; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf '  FAIL %s\n' "$1"
  fi
}

echo "release"
version=$(<"$kit/VERSION")
check "VERSION is a semantic version" '[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
check "CHANGELOG has notes for VERSION" '"$kit/scripts/release-notes.sh" "$version" "$kit/CHANGELOG.md" >/dev/null'
printf '# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-01-02\n\n### Added\n\n- b\n\n## [1.0.0] - 2026-01-01\n\n- a\n' \
  >"$work/CHANGELOG.md"
notes=$("$kit/scripts/release-notes.sh" 1.1.0 "$work/CHANGELOG.md")
check "one section, no heading, no blank edges" '[[ $notes == $'"'"'### Added\n\n- b'"'"' ]]'
check "a missing version fails" '! "$kit/scripts/release-notes.sh" 2.0.0 "$work/CHANGELOG.md" 2>/dev/null'
check "an empty section fails" '! "$kit/scripts/release-notes.sh" Unreleased "$work/CHANGELOG.md" 2>/dev/null'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
