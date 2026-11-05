#!/usr/bin/env bash
# Usage: ./install.sh
# 1. Symlinks this kit's skills into ~/.claude/skills (/guardrails-init, /ticket-spec,
#    /ticket-implement, /process-fix). Refuses to replace anything that is not this kit's link.
# 2. Registers the global hooks in ~/.claude/settings.json (idempotent, keeps existing hooks):
#    PreToolUse Bash -> hooks-global/bash-guard.sh, UserPromptSubmit -> hooks-global/prompt-reminder.sh.
#    A backup of settings.json is written next to it before the first change.
# 3. Links the owner-only commands approve-head and revoke-head into the first writable directory
#    on PATH among ~/.local/bin, /opt/homebrew/bin and /usr/local/bin.
set -euo pipefail
kit=$(cd "$(dirname "$0")" && pwd -P)

skills_dir="$HOME/.claude/skills"
mkdir -p "$skills_dir"
for skill in "$kit"/skills/*/; do
  name=$(basename "$skill")
  link="$skills_dir/$name"
  if [[ -L $link && $(readlink "$link") == "$kit/skills/$name" ]]; then
    printf 'up to date: %s\n' "$link"
  elif [[ -e $link || -L $link ]]; then
    printf 'error: %s already exists and does not point into this kit\n' "$link" >&2
    exit 1
  else
    ln -s "$kit/skills/$name" "$link"
    printf 'linked: %s -> %s\n' "$link" "$kit/skills/$name"
  fi
done

settings="$HOME/.claude/settings.json"
[[ -f $settings ]] || printf '{}\n' >"$settings"
jq empty "$settings" || {
  printf 'error: %s is not valid JSON\n' "$settings" >&2
  exit 1
}

guard="$kit/hooks-global/bash-guard.sh"
reminder="$kit/hooks-global/prompt-reminder.sh"
updated=$(jq --arg guard "$guard" --arg reminder "$reminder" '
  def ensure(event; matcher; command):
    .hooks[event] = ((.hooks[event] // [])
      | if any(.[]; any(.hooks[]?; .command == command)) then .
        else . + [{matcher: matcher, hooks: [{type: "command", command: command}]}] end);
  ensure("PreToolUse"; "Bash"; $guard) | ensure("UserPromptSubmit"; ""; $reminder)
' "$settings")

if [[ $updated == "$(jq . "$settings")" ]]; then
  printf 'up to date: hooks in %s\n' "$settings"
else
  backup="$settings.bak-$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  printf '%s\n' "$updated" >"$settings"
  printf 'registered hooks in %s (backup: %s)\n' "$settings" "$backup"
fi

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
for command in approve-head revoke-head; do
  link="$bin_dir/$command"
  if [[ -L $link && $(readlink "$link") == "$kit/bin/$command" ]]; then
    printf 'up to date: %s\n' "$link"
  elif [[ -e $link || -L $link ]]; then
    printf 'error: %s already exists and does not point into this kit\n' "$link" >&2
    exit 1
  else
    ln -s "$kit/bin/$command" "$link"
    printf 'linked: %s -> %s\n' "$link" "$kit/bin/$command"
  fi
done
