#!/usr/bin/env bash
# Usage: scripts/release-notes.sh <version> <changelog>
# Prints the body of the "## [<version>]" section of a Keep a Changelog file, without its heading.
# Fails when the section is missing or empty, so a release cannot go out without notes.
set -euo pipefail
[[ $# -eq 2 ]] || { printf 'usage: %s <version> <changelog>\n' "$0" >&2; exit 2; }
version=$1
changelog=$2
notes=$(awk -v heading="## [$version]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' "$changelog")
# Trim leading and trailing blank lines.
notes=$(printf '%s\n' "$notes" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')
[[ -n $notes ]] || { printf 'error: %s has no notes for version %s\n' "$changelog" "$version" >&2; exit 1; }
printf '%s\n' "$notes"
