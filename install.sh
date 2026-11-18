#!/usr/bin/env bash
# Usage: ./install.sh
# Run it from a clone of the kit that nobody develops in (for example ~/.local/share/agent-guardrails,
# kept on main with `git pull --ff-only`): the owner's commands refuse to run from a checkout with local
# changes or one that is not at its origin's main, and the template they compare projects against is
# this checkout. Running it from another clone moves every link and hook over to that clone.
# 1. Symlinks this kit's skills into ~/.claude/skills (/guardrails-init, /ticket-spec,
#    /ticket-implement, /process-fix).
# 2. Registers the global hooks in ~/.claude/settings.json (idempotent, keeps other hooks):
#    PreToolUse Bash -> hooks-global/bash-guard.sh, UserPromptSubmit -> hooks-global/prompt-reminder.sh,
#    SessionStart and PreToolUse Bash -> hooks-global/agent-identity.sh.
#    A backup of settings.json is written next to it before any change.
# 3. Links the owner-only commands guardrails (also as agent-guardrails), approve-head and revoke-head into
#    the first writable directory on PATH among ~/.local/bin, /opt/homebrew/bin and /usr/local/bin.
# Refuses, before changing anything, to replace a file that is not a link into a kit checkout.
set -euo pipefail
kit=$(cd "$(dirname "$0")" && pwd -P)

# Everything the install needs is checked before anything changes, so a failed run leaves no half install.
missing=""
# curl and openssl sign the agent App's requests (creating the App and the agent-identity hook).
for tool in git gh jq curl openssl; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
[[ -z $missing ]] || {
  printf 'error: missing required tools:%s (on macOS: brew install%s)\n' "$missing" "$missing" >&2
  exit 1
}
bin_dir=""
for candidate in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  if [[ ":$PATH:" == *":$candidate:"* && -d $candidate && -w $candidate ]]; then
    bin_dir=$candidate
    break
  fi
done
[[ -n $bin_dir ]] || {
  printf 'error: none of ~/.local/bin, /opt/homebrew/bin, /usr/local/bin is a writable directory on PATH\n' >&2
  exit 1
}
mkdir -p "$HOME/.claude"
settings="$HOME/.claude/settings.json"
[[ -f $settings ]] || printf '{}\n' >"$settings"
jq empty "$settings" || {
  printf 'error: %s is not valid JSON\n' "$settings" >&2
  exit 1
}

# Every link the install makes, as "<path in this kit> <link>" lines. `guardrails` is also linked as
# `agent-guardrails`, a name that does not clash with other tools called guardrails.
planned_links() {
  local skill name
  for skill in "$kit"/skills/*/; do
    name=$(basename "$skill")
    printf '%s %s\n' "skills/$name" "$skills_dir/$name"
  done
  for name in guardrails approve-head revoke-head; do
    printf '%s %s\n' "bin/$name" "$bin_dir/$name"
  done
  printf '%s %s\n' "bin/guardrails" "$bin_dir/agent-guardrails"
}

# Succeeds when <link> may be (re)created: absent, already a link to $kit/<relative>, or a link into another
# kit checkout (one that has hooks-global/bash-guard.sh).
link_allowed() {
  local relative=$1 link=$2 old_root
  [[ -e $link || -L $link ]] || return 0
  [[ -L $link ]] || return 1
  [[ $(readlink "$link") == "$kit/$relative" ]] && return 0
  old_root=$(readlink "$link")
  old_root=${old_root%/"$relative"}
  [[ -f "$old_root/hooks-global/bash-guard.sh" ]]
}

skills_dir="$HOME/.claude/skills"
# Checked before anything changes, so a foreign file in the way leaves no half install.
blocked=""
while read -r relative link; do
  link_allowed "$relative" "$link" || blocked="$blocked $link"
done < <(planned_links)
[[ -z $blocked ]] || {
  printf 'error: these already exist and do not point into a kit checkout; move them away first:%s\n' "$blocked" >&2
  exit 1
}

# Links <link> to $kit/<relative>, replacing a link into another kit checkout (link_allowed checked it).
link_into_kit() {
  local relative=$1 link=$2 target old_root
  target="$kit/$relative"
  if [[ -L $link && $(readlink "$link") == "$target" ]]; then
    printf 'up to date: %s\n' "$link"
    return 0
  fi
  if [[ -L $link ]]; then
    old_root=$(readlink "$link")
    old_root=${old_root%/"$relative"}
    if [[ -f "$old_root/hooks-global/bash-guard.sh" ]]; then
      rm "$link"
      ln -s "$target" "$link"
      printf 'moved: %s -> %s (was %s)\n' "$link" "$target" "$old_root"
      return 0
    fi
  fi
  if [[ -e $link || -L $link ]]; then
    printf 'error: %s already exists and does not point into a kit checkout\n' "$link" >&2
    exit 1
  fi
  ln -s "$target" "$link"
  printf 'linked: %s -> %s\n' "$link" "$target"
}

mkdir -p "$skills_dir"
for skill in "$kit"/skills/*/; do
  name=$(basename "$skill")
  link_into_kit "skills/$name" "$skills_dir/$name"
done

guard="$kit/hooks-global/bash-guard.sh"
reminder="$kit/hooks-global/prompt-reminder.sh"
identity="$kit/hooks-global/agent-identity.sh"
updated=$(jq --arg guard "$guard" --arg reminder "$reminder" --arg identity "$identity" '
  def other_kit_hook:
    any(.hooks[]?; (.command | test("/hooks-global/(bash-guard|prompt-reminder|agent-identity)\\.sh$"))
      and .command != $guard and .command != $reminder and .command != $identity);
  def ensure(event; matcher; command):
    .hooks[event] = ((.hooks[event] // []) | map(select(other_kit_hook | not))
      | if any(.[]; .matcher == matcher and any(.hooks[]?; .command == command)) then .
        else . + [{matcher: matcher, hooks: [{type: "command", command: command}]}] end);
  ensure("PreToolUse"; "Bash"; $guard) | ensure("UserPromptSubmit"; ""; $reminder)
  | ensure("SessionStart"; ""; $identity) | ensure("PreToolUse"; "Bash"; $identity)
' "$settings")

if [[ $updated == "$(jq . "$settings")" ]]; then
  printf 'up to date: hooks in %s\n' "$settings"
else
  backup="$settings.bak-$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  printf '%s\n' "$updated" >"$settings"
  printf 'registered hooks in %s (backup: %s)\n' "$settings" "$backup"
fi

for command in guardrails approve-head revoke-head; do
  link_into_kit "bin/$command" "$bin_dir/$command"
done
link_into_kit bin/guardrails "$bin_dir/agent-guardrails"

if [[ $(uname) == Darwin ]]; then
  printf 'Optional menu bar app for approvals and turning repos on or off: make -C %s app\n' "$kit"
fi
