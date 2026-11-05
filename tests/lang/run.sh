#!/usr/bin/env bash
# Usage: tests/lang/run.sh [typescript|javascript|python|rust|swift|swift-xcode]...
# Integration tests for the language Makefiles, results adapters, verify-red/verify-green and the
# integrity guards, against real throwaway projects (needs network for package installs; slow).
# With no arguments runs every language whose toolchain is installed and reports skipped ones.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
requires() {
  case $1 in
    typescript | javascript) printf 'pnpm node' ;;
    python) printf 'uv' ;;
    rust) printf 'cargo' ;;
    swift) printf 'swift' ;;
    swift-xcode) printf 'swift xcodebuild xcodegen' ;;
    *)
      printf 'unknown language: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

if [[ $# -gt 0 ]]; then langs=("$@"); else langs=(typescript javascript python rust swift swift-xcode); fi

status=0
for lang in "${langs[@]}"; do
  missing=""
  for tool in $(requires "$lang"); do
    command -v "$tool" >/dev/null || missing+=" $tool"
  done
  if [[ -n $missing ]]; then
    printf '%s: SKIPPED (missing:%s)\n' "$lang" "$missing"
    [[ $# -eq 0 ]] || status=1
    continue
  fi
  "$here/$lang.sh" || status=1
done
exit "$status"
