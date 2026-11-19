#!/usr/bin/env bash
# Tests install.sh in a throwaway HOME: fresh install, moving links and hooks over from another kit
# checkout, keeping unrelated hooks, refusing foreign files, a second run changing nothing, and stopping
# before any change when required tools are missing.
# shellcheck disable=SC2016,SC2034 # check() evaluates its condition string, which uses these variables
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
# Resolved, because install.sh names hook files by their resolved directory (macOS's temp dir is a link).
work=$(cd "$(mktemp -d)" && pwd -P)
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
# Cursor and Codex are set up in this HOME, each with a hook of the user's and one of the old kit checkout.
mkdir -p "$home/.cursor" "$home/.codex"
jq -n --arg old "$old" '{version: 1, hooks: {beforeShellExecution: [
  {command: ($old + "/hooks-global/cursor-guard.sh"), failClosed: true}, {command: "./audit.sh"}]}}' \
  >"$home/.cursor/hooks.json"
jq -n --arg old "$old" '{hooks: {PreToolUse: [
  {matcher: "Bash", hooks: [{type: "command", command: ($old + "/hooks-global/bash-guard.sh")}]},
  {matcher: "Bash", hooks: [{type: "command", command: "rtk hook codex"}]}]}}' >"$home/.codex/hooks.json"
# CODEX_HOME is cleared so a developer's own setting cannot point the test at their real Codex config.
run_install() { HOME="$home" CODEX_HOME="" PATH="$home/.local/bin:$PATH" "$kit/install.sh"; }

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
check "identity hook renews tokens before Bash" 'grep -Fx "$kit/hooks-global/agent-identity.sh" <<<"$commands" >/dev/null'
check "identity hook starts sessions" '[[ $(jq -r ".hooks.SessionStart[].hooks[].command" "$home/.claude/settings.json") == "$kit/hooks-global/agent-identity.sh" ]]'
cursor_file="$home/.cursor/hooks.json"
check "cursor: the kit hook guards shell commands, moved in place before the user's hook" \
  '[[ $(jq -c "[.hooks.beforeShellExecution[] | .command]" "$cursor_file") == "$(jq -n -c --arg g "$kit/hooks-global/cursor-guard.sh" "[\$g, \"./audit.sh\"]")" ]]'
check "cursor: the kit hook guards file reads and fails closed" \
  '[[ $(jq -c ".hooks.beforeReadFile" "$cursor_file") == "$(jq -n -c --arg g "$kit/hooks-global/cursor-guard.sh" "[{command: \$g, failClosed: true}]")" ]]'
check "cursor: the version is kept" '[[ $(jq .version "$cursor_file") == 1 ]]'
check "cursor: a backup was written" 'compgen -G "$cursor_file.bak-*" >/dev/null'
codex_file="$home/.codex/hooks.json"
check "codex: bash-guard replaces the old kit's where it stood, the user's hook stays second" \
  '[[ $(jq -c "[.hooks.PreToolUse[].hooks[].command]" "$codex_file") == "$(jq -n -c --arg g "$kit/hooks-global/bash-guard.sh" "[\$g, \"rtk hook codex\"]")" ]]'
check "codex: prompt-reminder registered" \
  '[[ $(jq -r ".hooks.UserPromptSubmit[].hooks[].command" "$codex_file") == "$kit/hooks-global/prompt-reminder.sh" ]]'
check "codex: agent-identity is not registered (Codex cannot hand a session its environment)" \
  '! grep -F agent-identity "$codex_file" >/dev/null'
check "codex: a backup was written" 'compgen -G "$codex_file.bak-*" >/dev/null'
check "codex: the user is told to trust the hooks" 'grep -F "open /hooks in Codex" <<<"$out" >/dev/null'
out=$(run_install)
check "second run changes nothing" '! grep -E "^(linked|moved|registered)" <<<"$out" >/dev/null'
check "second run does not ask to trust again" '! grep -F "open /hooks in Codex" <<<"$out" >/dev/null'
check "agent-guardrails is the same command" '[[ $(readlink "$home/.local/bin/agent-guardrails") == "$kit/bin/guardrails" ]]'
rm "$home/.local/bin/revoke-head"
printf 'mine\n' >"$home/.local/bin/revoke-head"
check "a foreign file is not replaced" '! run_install >/dev/null 2>&1'

# A foreign file in the way stops a fresh install before any link or hook exists.
fresh_home="$work/fresh-home"
mkdir -p "$fresh_home/.local/bin"
printf 'mine\n' >"$fresh_home/.local/bin/agent-guardrails"
fresh_out=$(HOME="$fresh_home" PATH="$fresh_home/.local/bin:$PATH" "$kit/install.sh" 2>&1) && fresh_status=0 || fresh_status=$?
check "a foreign file stops the install" '[[ $fresh_status -ne 0 ]] && grep -F "$fresh_home/.local/bin/agent-guardrails" <<<"$fresh_out" >/dev/null'
check "a foreign file leaves no link and no hook" '[[ ! -e $fresh_home/.claude/skills && ! -e $fresh_home/.local/bin/guardrails ]] &&
  [[ $(jq -c . "$fresh_home/.claude/settings.json") == "{}" ]]'

# Neither Cursor nor Codex set up: no hook file of theirs is created.
check "no cursor or codex config without their directories" '[[ ! -e $fresh_home/.cursor && ! -e $fresh_home/.codex ]]'

# Set up but without hook files: they are created. A CODEX_HOME outside HOME is left alone.
new_home="$work/new-home"
outside="$work/outside-codex"
mkdir -p "$new_home/.local/bin" "$new_home/.cursor" "$new_home/.codex" "$outside"
new_out=$(HOME="$new_home" CODEX_HOME="$outside" PATH="$new_home/.local/bin:$PATH" "$kit/install.sh" 2>&1)
check "cursor hook file created" '[[ $(jq -r ".hooks.beforeShellExecution[0].command" "$new_home/.cursor/hooks.json") == "$kit/hooks-global/cursor-guard.sh" ]]'
check "a CODEX_HOME outside HOME is not written" '[[ ! -e $outside/hooks.json && ! -e $new_home/.codex/hooks.json ]]'
check "a CODEX_HOME outside HOME is reported" 'grep -F "Codex config directory $outside is not inside your home directory" <<<"$new_out" >/dev/null'
HOME="$new_home" CODEX_HOME="$new_home/../outside-codex" PATH="$new_home/.local/bin:$PATH" "$kit/install.sh" >/dev/null 2>&1
check "a CODEX_HOME that leaves HOME through .. is not written" '[[ ! -e $outside/hooks.json ]]'
HOME="$new_home" CODEX_HOME="$new_home/.codex" PATH="$new_home/.local/bin:$PATH" "$kit/install.sh" >/dev/null
check "codex hook file created under CODEX_HOME" '[[ $(jq -r ".hooks.PreToolUse[0].hooks[0].command" "$new_home/.codex/hooks.json") == "$kit/hooks-global/bash-guard.sh" ]]'

# A hook file whose hooks are not in the documented shape stops the install before any link or hook changes.
for broken in '{"hooks": []}' '{"hooks": {"PreToolUse": ["oops"]}}' '{"hooks": {"beforeShellExecution": {"command": "/x"}}}'; do
  broken_home="$work/broken-home"
  rm -rf "$broken_home"
  mkdir -p "$broken_home/.local/bin" "$broken_home/.codex" "$broken_home/.cursor"
  printf '%s\n' "$broken" >"$broken_home/.codex/hooks.json"
  printf '%s\n' "$broken" >"$broken_home/.cursor/hooks.json"
  broken_out=$(HOME="$broken_home" CODEX_HOME="" PATH="$broken_home/.local/bin:$PATH" "$kit/install.sh" 2>&1) && broken_status=0 || broken_status=$?
  check "a broken hook file stops the install: $broken" '[[ $broken_status -ne 0 ]] && grep -F "$broken_home/" <<<"$broken_out" | grep -F "fix it" >/dev/null'
  check "a broken hook file leaves everything as it was: $broken" '[[ ! -e $broken_home/.claude/skills && ! -e $broken_home/.local/bin/guardrails ]] &&
    [[ $(jq -c . "$broken_home/.claude/settings.json") == "{}" ]] &&
    [[ $(cat "$broken_home/.codex/hooks.json") == "$broken" && $(cat "$broken_home/.cursor/hooks.json") == "$broken" ]]'
done

# Without jq and gh on PATH the install stops before touching anything.
bare_home="$work/bare-home"
bare_bin="$work/bare-bin"
mkdir -p "$bare_home" "$bare_bin"
for tool in bash dirname git; do ln -s "$(command -v "$tool")" "$bare_bin/$tool"; done
bare_out=$(HOME="$bare_home" PATH="$bare_bin" "$kit/install.sh" 2>&1) && bare_status=0 || bare_status=$?
check "missing tools stop the install" '[[ $bare_status -ne 0 ]] && grep -F "missing required tools: gh jq" <<<"$bare_out" >/dev/null'
check "a stopped install changes nothing" '[[ ! -e $bare_home/.claude ]]'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
