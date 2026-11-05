#!/usr/bin/env bash
# Tests install.sh in a throwaway HOME: fresh install, moving links and hooks over from another kit
# checkout, keeping unrelated hooks, refusing foreign files, and a second run changing nothing.
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

home="$work/home"
old="$work/old-kit"
mkdir -p "$old/hooks-global" "$old/skills/ticket-spec" "$old/bin" "$home/.claude/skills" "$home/.local/bin"
touch "$old/hooks-global/bash-guard.sh"
ln -s "$old/skills/ticket-spec" "$home/.claude/skills/ticket-spec"
ln -s "$old/bin/approve-head" "$home/.local/bin/approve-head"
jq -n --arg old "$old" '{hooks: {PreToolUse: [
  {matcher: "Bash", hooks: [{type: "command", command: "rtk hook claude"}]},
  {matcher: "Bash", hooks: [{type: "command", command: ($old + "/hooks-global/bash-guard.sh")}]}]}}' \
  >"$home/.claude/settings.json"
run_install() { HOME="$home" PATH="$home/.local/bin:$PATH" "$kit/install.sh"; }

echo "install.sh"
out=$(run_install)
check "skill link moved from the old kit" '[[ $(readlink "$home/.claude/skills/ticket-spec") == "$kit/skills/ticket-spec" ]]'
check "command link moved from the old kit" '[[ $(readlink "$home/.local/bin/approve-head") == "$kit/bin/approve-head" ]]'
check "guardrails command linked" '[[ $(readlink "$home/.local/bin/guardrails") == "$kit/bin/guardrails" ]]'
check "move is reported" 'grep -F "moved: $home/.claude/skills/ticket-spec" <<<"$out" >/dev/null'
commands=$(jq -r '.hooks.PreToolUse[].hooks[].command' "$home/.claude/settings.json")
check "unrelated hook kept" 'grep -Fx "rtk hook claude" <<<"$commands" >/dev/null'
check "old kit hook removed" '! grep -F "$old" <<<"$commands" >/dev/null'
check "new kit hook registered" 'grep -Fx "$kit/hooks-global/bash-guard.sh" <<<"$commands" >/dev/null'
out=$(run_install)
check "second run changes nothing" '! grep -E "^(linked|moved|registered)" <<<"$out" >/dev/null'
rm "$home/.local/bin/revoke-head"
printf 'mine\n' >"$home/.local/bin/revoke-head"
check "a foreign file is not replaced" '! run_install >/dev/null 2>&1'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
