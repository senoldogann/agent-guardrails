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
#    Where Cursor is set up (~/.cursor exists): beforeShellExecution and beforeReadFile ->
#    hooks-global/cursor-guard.sh in ~/.cursor/hooks.json. Where Codex is set up ($CODEX_HOME or ~/.codex exists,
#    inside $HOME): PreToolUse Bash -> bash-guard.sh and UserPromptSubmit -> prompt-reminder.sh in its hooks.json.
#    A backup of each changed file is written next to it first; other hooks are kept.
# 3. Links the owner-only commands guardrails (also as agent-guardrails), approve-head and revoke-head into
#    the first writable directory on PATH among ~/.local/bin, /opt/homebrew/bin and /usr/local/bin.
# Refuses, before changing anything, to replace a file that is not a link into a kit checkout.
set -euo pipefail
kit=$(cd "$(dirname "$0")" && pwd -P)

# Everything the install needs is checked before anything changes, so a failed run leaves no half install.
missing=""
# curl and openssl sign the agent App's requests (creating the App and the agent-identity hook). python3 runs
# the workflow check before an approval (.agent/workflow/check.py in the template, standard library only).
for tool in git gh jq curl openssl python3; do
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
# Cursor and Codex get the guard only where they are set up: their config directory exists once they have run.
# Their hook files are changed only when that directory, with links resolved, is inside $HOME.
home_real=$(cd "$HOME" && pwd -P)
# Prints the hook file in config directory <dir> of agent <name>, nothing when the directory does not exist or
# lies outside $HOME (then says so).
hooks_file_in() {
  local dir=$1 name=$2 real
  [[ -d $dir ]] || return 0
  real=$(cd "$dir" && pwd -P)
  case $real in
    "$home_real"/?*) printf '%s/hooks.json\n' "$real" ;;
    *) printf 'note: the %s config directory %s is not inside your home directory; register its hooks by hand (see README)\n' "$name" "$dir" >&2 ;;
  esac
}
cursor_hooks=$(hooks_file_in "$HOME/.cursor" Cursor)
codex_hooks=$(hooks_file_in "${CODEX_HOME:-$HOME/.codex}" Codex)
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

# Every hook file's new content is worked out before anything changes, so a file the install cannot read
# leaves no half install.
guard="$kit/hooks-global/bash-guard.sh"
reminder="$kit/hooks-global/prompt-reminder.sh"
identity="$kit/hooks-global/agent-identity.sh"
settings_updated=$(jq --arg guard "$guard" --arg reminder "$reminder" --arg identity "$identity" '
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

# Prints a hook file's JSON, or an empty object when the file does not exist yet.
hooks_file_content() {
  if [[ -f $1 ]]; then cat "$1"; else printf '{}\n'; fi
}

# Stops the install over a hook file whose hooks are not in the documented shape.
unusable_hooks_file() {
  printf 'error: %s is not a JSON object whose "hooks" map events to lists of hooks; fix it, then run install.sh again\n' "$1" >&2
  exit 1
}

# Cursor: cursor-guard.sh translates beforeShellExecution and beforeReadFile into bash-guard.sh. failClosed makes a
# crash or timeout block the action, as bash-guard does for Claude Code. An entry of another kit checkout is
# pointed at this one where it stands, so the order of the user's hooks does not change.
cursor_updated=""
if [[ -n $cursor_hooks ]]; then
  cursor_guard="$kit/hooks-global/cursor-guard.sh"
  # shellcheck disable=SC2016 # $guard is a jq variable
  cursor_updated=$(jq --arg guard "$cursor_guard" '
    def ensure(event):
      .hooks[event] = ((.hooks[event] // [])
        | map(if ((.command // "") | test("/hooks-global/cursor-guard\\.sh$")) then .command = $guard else . end)
        | reduce .[] as $hook ([]; if $hook.command == $guard and any(.[]; .command == $guard) then . else . + [$hook] end)
        | if any(.[]; .command == $guard) then . else . + [{command: $guard, failClosed: true}] end);
    .version = (.version // 1) | .hooks = (.hooks // {})
    | ensure("beforeShellExecution") | ensure("beforeReadFile")
  ' <<<"$(hooks_file_content "$cursor_hooks")") || unusable_hooks_file "$cursor_hooks"
fi

# Codex reads Claude Code's hook format and input (tool_name Bash, tool_input.command, cwd; exit 2 blocks), so
# bash-guard.sh and prompt-reminder.sh run unchanged. Codex skips a hook until the user trusts it in /hooks.
# Entries of another kit checkout are pointed at this one where they stand: Codex keys its trust records by
# a hook's position, so removing and appending would also untrust the user's later hooks.
codex_updated=""
if [[ -n $codex_hooks ]]; then
  # shellcheck disable=SC2016 # $kit, $guard and $reminder are jq variables
  codex_updated=$(jq --arg kit "$kit" --arg guard "$guard" --arg reminder "$reminder" '
    def kit_script: "/hooks-global/(?<name>bash-guard|prompt-reminder)\\.sh$";
    def moved: if ((.command // "") | test(kit_script)) then .command = ($kit + "/hooks-global/" + (.command | capture(kit_script).name) + ".sh") else . end;
    def ensure(event; matcher; command):
      .hooks[event] = ((.hooks[event] // [])
        | map(if .hooks then .hooks |= map(moved) else . end)
        | if any(.[]; (.matcher // "") == matcher and any(.hooks[]?; .command == command)) then .
          else . + [{matcher: matcher, hooks: [{type: "command", command: command}]}] end);
    .hooks = (.hooks // {}) | ensure("PreToolUse"; "Bash"; $guard) | ensure("UserPromptSubmit"; ""; $reminder)
  ' <<<"$(hooks_file_content "$codex_hooks")") || unusable_hooks_file "$codex_hooks"
  codex_before=$(jq . <<<"$(hooks_file_content "$codex_hooks")")
fi

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

# Writes the JSON <updated> to the hook file <file> when it differs, after backing up an existing file next to it.
write_hooks_file() {
  local file=$1 updated=$2 backup
  if [[ ! -f $file ]]; then
    printf '%s\n' "$updated" >"$file"
    printf 'registered hooks in %s (new file)\n' "$file"
  elif [[ $updated == "$(jq . "$file")" ]]; then
    printf 'up to date: hooks in %s\n' "$file"
  else
    backup="$file.bak-$(date +%Y%m%d%H%M%S)"
    cp "$file" "$backup"
    printf '%s\n' "$updated" >"$file"
    printf 'registered hooks in %s (backup: %s)\n' "$file" "$backup"
  fi
}
write_hooks_file "$settings" "$settings_updated"
[[ -z $cursor_hooks ]] || write_hooks_file "$cursor_hooks" "$cursor_updated"
if [[ -n $codex_hooks ]]; then
  write_hooks_file "$codex_hooks" "$codex_updated"
  [[ $codex_updated == "$codex_before" ]] ||
    printf 'Codex runs new or changed hooks only after you trust them: open /hooks in Codex and trust bash-guard.sh and prompt-reminder.sh.\n'
fi

for command in guardrails approve-head revoke-head; do
  link_into_kit "bin/$command" "$bin_dir/$command"
done
link_into_kit bin/guardrails "$bin_dir/agent-guardrails"

if [[ $(uname) == Darwin ]]; then
  printf 'Optional menu bar app for approvals and turning repos on or off: make -C %s app\n' "$kit"
fi
