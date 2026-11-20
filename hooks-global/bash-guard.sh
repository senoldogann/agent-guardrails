#!/usr/bin/env bash
# Global PreToolUse hook for Bash, registered by install.sh in ~/.claude/settings.json (Claude Code) and in
# Codex's hooks.json (Codex sends the same input). Cursor reaches it through cursor-guard.sh. It is the single
# source of truth for what the agent may run. Given a file tool's path (Claude Code's Read, Grep, Glob, Edit,
# Write, MultiEdit, NotebookEdit; Cursor's file reads) instead of a command, it checks only the rules on the
# owner's files and credential files.
# Scope: the full rule set applies in kit repositories (.agent/bin/ci-guard exists, or the origin is in the
# owner's list of enforced repositories) and to any command that names an enforced repository, from any
# directory. Everywhere else the agent works as if the kit did not exist, with one exception that protects
# the kit repositories themselves: nothing may run the owner's commands (approve-head, revoke-head,
# guardrails on/off/approve/revoke/update/agent create), post a `merge-approval` status or touch the list of enforced repositories.
# In kit repositories the agent works with the owner's GitHub identity unless agent-identity.sh switched the
# session to the agent App's bot, and the owner's login stays reachable either way, so actions reserved for
# the human must be blocked before they run: approving or admin-merging PRs, approving deployments,
# changing repo settings/rulesets/workflows/secrets, reading credentials, and pushing to the default
# branch. `gh` is allow-listed per subcommand; everything else is a deny-list over the whole command
# string, including text inside quotes (so `bash -c "..."` wrappers are covered).
# Limits: obfuscated commands (string concatenation, scripts written to files) can evade text matching;
# the ruleset on GitHub, which needs the owner's typed approval per HEAD, is the authority.
# Exit code 2 blocks the call and shows stderr to the agent.
set -euo pipefail
# Fail closed: a call is allowed only through allow (below); every other end blocks it with 2. That covers an
# internal error (missing jq, an unreadable file) and the fatal ones (a failed source, an unset variable) after
# which Bash 3.2, macOS's /bin/bash, runs the EXIT trap with status 0. A deny, also one in a subshell, ends with 2
# and has said why. Subshells keep their own exit codes.
# shellcheck disable=SC2154 # status is assigned inside the trap
trap 'status=$?; if [[ ${allowed:-} != 1 ]]; then [[ $status -eq 2 ]] || printf "BLOCKED by bash-guard: internal error (exit %s); ask the user to check the hook\n" "$status" >&2; exit 2; fi' EXIT
allow() {
  allowed=1
  exit 0
}
# shellcheck source=kit-project.sh
source "$(dirname "$(realpath "$0")")/kit-project.sh"

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
raw=$(jq -r '.tool_input.command // empty' <<<"$input")
# A line that ends in a backslash continues on the next one: joined, so a flag on a continuation line is checked
# with its command.
continuation=$'\\\n'
raw=${raw//"$continuation"/ }
# A file tool (Read, Grep, Glob, Edit, Write, MultiEdit, NotebookEdit; other agents' read tools through their
# adapters) is checked by its path, against the rules on the owner's files: reads against the owner's settings and
# credential files, writes also against the kit install and the kit's hook registrations.
read_path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' <<<"$input")
# Grep without a path searches the session's directory.
[[ $tool != Grep || -n $read_path ]] || read_path=$(jq -r '.cwd // empty' <<<"$input")
[[ -n $raw || -n $read_path ]] || allow
# Normalize common spellings so quoting or path tricks do not hide a gh call:
# drop quotes and backslashes, and turn $(which gh)/$(command -v gh)/`which gh` into gh.
quote_chars=$'\\\\"\''
# shellcheck disable=SC2016 # $( and backticks are literal text to rewrite, not expansions
gh_lookup='s/\$\((which|command -v|type -p) gh\)/gh/g; s/`(which|command -v|type -p) gh`/gh/g'
if [[ -n $raw ]]; then
  cmd=$(tr -d "$quote_chars" <<<"$raw" | sed -E "$gh_lookup")
else
  cmd=$read_path
fi

deny() {
  printf 'BLOCKED by bash-guard: %s\nThis is reserved for the human (approvals, merges, credentials, repository settings). Do not work around it; ask the user to do it.\n' "$1" >&2
  exit 2
}

matches() {
  grep -Eiq -- "$1" <<<"$cmd"
}

# Like matches, with case: for options whose case changes their meaning (ps -E shows environments, ps -e does not).
matches_case() {
  grep -Eq -- "$1" <<<"$cmd"
}

# Prints a path with every symbolic link resolved, also in a part that does not exist yet (a file a write would
# create), so no link can dress up a protected path. Relative paths are taken from the tool call's directory, and a
# leading ~ is the home directory (Grep hands its path over as written and expands ~ itself).
physical_path() {
  local path=$1 rest="" link hops=0
  # shellcheck disable=SC2088 # a literal ~, as Grep hands it over
  case $path in
    "~") path=$HOME ;;
    "~/"*) path="$HOME/${path#"~/"}" ;;
  esac
  [[ $path == /* ]] || path="$(jq -r '.cwd // empty' <<<"$input")/$path"
  while :; do
    if [[ -e $path ]]; then
      path=$(realpath "$path") || return 1
      printf '%s%s\n' "$path" "$rest"
      return 0
    fi
    if [[ -L $path ]]; then
      hops=$((hops + 1))
      [[ $hops -le 40 ]] || deny "a symbolic link loop at $path"
      link=$(readlink "$path") || return 1
      [[ $link == /* ]] || link="$(dirname "$path")/$link"
      path=$link
      continue
    fi
    if [[ $path == / || -z $path ]]; then
      printf '%s\n' "${rest:-/}"
      return 0
    fi
    rest="/${path##*/}$rest"
    path=${path%/*}
  done
}

# Prints the physical paths of the user's hook registrations: Claude Code's settings (also under CLAUDE_CONFIG_DIR),
# Cursor's and Codex's (also under CODEX_HOME) hooks.json.
user_hook_files() {
  local file
  for file in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.local.json" \
    "$HOME/.cursor/hooks.json" "$HOME/.codex/hooks.json" "${CODEX_HOME:-$HOME/.codex}/hooks.json"; do
    physical_path "$file" || return 1
  done
}

# Prints what a file-tool write leaves in a file: Write's content, or the file with Edit's or MultiEdit's
# replacements applied as the tools apply them (the first occurrence, or every one with replace_all). Argument: the
# file.
content_after_write() {
  # shellcheck disable=SC2016 # jq's $variables, not the shell's
  local program='
    def replaced($e): ($e.old_string // "") as $old | ($e.new_string // "") as $new
      | if $old == "" then $new
        elif ($e.replace_all // false) then split($old) | join($new)
        else split($old) as $parts
          | if ($parts | length) < 2 then . else $parts[0] + $new + ($parts[1:] | join($old)) end
        end;
    .tool_input as $in
    | if $in.content != null then $in.content
      else reduce ([$in | select(.old_string != null)] + ($in.edits // []))[] as $e ($current; replaced($e))
      end'
  if [[ -f $1 ]]; then
    jq -r --rawfile current "$1" "$program" <<<"$input"
  else
    jq -r --arg current "" "$program" <<<"$input"
  fi
}

# Prints why a write that leaves `after` in a hook registration file that held `before` would drop, move or change
# one of the kit's hook entries (event, matcher and the entry itself, for every entry that runs hooks-global/*.sh),
# or nothing. Arguments: the file's content before and after the write.
kit_hooks_problem() {
  jq -rn --arg before "$1" --arg after "$2" '
    def kit_hooks: [(.hooks // {}) | to_entries[] | .key as $event | (.value // [])[]
      | if type == "object" and (.hooks | type) == "array" then (.matcher // "") as $matcher | .hooks[] | [$event, $matcher, .]
        else [$event, "", .] end
      | select((.[2] | type) == "object" and ((.[2].command // "") | tostring | test("hooks-global/[a-z-]+\\.sh")))];
    (try ($before | fromjson | kit_hooks) catch []) as $kept
    | if ($kept | length) == 0 then empty
      else (try ($after | fromjson | kit_hooks) catch null) as $now
        | if $now == null then "the file would no longer be readable"
          else ($kept - $now) as $gone
            | if ($gone | length) == 0 then empty
              else "it drops, moves or changes \([$gone[] | .[2].command] | unique | join(", "))" end
          end
      end'
}

# Prints why content written to a Claude Code settings file would turn every hook off (disableAllHooks), or nothing.
# Argument: the content after the write.
hooks_off_problem() {
  jq -rn --arg after "$1" '
    (try ($after | fromjson) catch null) as $new
    | if ($new | type) == "object" then (if ($new.disableAllHooks // false) != false then "it sets disableAllHooks" else empty end)
      elif ($after | test("disableAllHooks")) then "it sets disableAllHooks"
      else empty end'
}

# Files that hold GitHub credentials or the tokens of Claude Code's local settings, as shell commands name them.
credential_files='\.config/gh|hosts\.yml|\.git-credentials|git/credentials|\.netrc|settings\.local\.json'

# Where a command word starts: the start of a line, a separator, or the text a wrapper runs (sh -c, bash -c, eval,
# exec, sudo, nohup, time, command, builtin, xargs, env with options or assignments), with an optional directory
# before the word (/usr/bin/env). Rules that name a command anchor it here, so a commit message that mentions
# "export" or "tmux new-session" is no command.
# shellcheck disable=SC2016 # backticks are literal regex characters
command_at='(^|[;&|(`]|(^|[[:space:]/])((ba|z|da|k|fi)?sh[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*c|eval|exec|sudo|nohup|time|command|builtin|xargs|env([[:space:]]+(-[a-zA-Z0-9]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*))*))[[:space:]]*([^[:space:];&|`()]*/)?'

# Everywhere: the owner's commands, the approval status and the rulesets of kit repositories, and the
# owner's list of enforced repositories are the owner's alone.
# .config as a path component, not inside a word: `model.configuration` next to an agent-guardrails path is fine.
if matches '\.config([/[:space:]]|$)' && matches 'agent-g'; then deny "the owner's list of enforced repositories"; fi
if matches '\.local/share' && matches 'agent-g'; then deny "the owner's kit install"; fi
# File tools, everywhere, by the physical path (every link resolved): none reads or writes the owner's kit settings
# (~/.config/agent-guardrails: the enforced repositories and the agent App's private key), and a Grep, which reads
# every file below its directory, does not search ~/.config or a parent of it. Writes also stay out of the kit
# install this hook runs from; leave every kit hook entry in the user's hook registrations as it is (they may change
# anything else there); and set disableAllHooks in no Claude Code settings file, the user's or a project's. Reads
# of the kit install go by the path's text above, so a skill linked from ~/.claude/skills into it can still be read.
if [[ -z $raw ]]; then
  settings_root=$(physical_path "$(dirname "$(guardrails_registry)")")
  target=$(physical_path "$read_path")
  # The searched directory with one trailing slash ("/" for the root): a pattern built from a quoted empty string
  # does not match on Bash 5.2.
  searched=${target%/}/
  case $target/ in
    "$settings_root"/*) deny "the owner's kit settings (enforced repositories, agent App key)" ;;
  esac
  if [[ $tool == Grep ]]; then
    case $(dirname "$settings_root")/ in
      "$searched"*) deny "searching $target, which holds the owner's kit settings and credentials; search a narrower directory" ;;
    esac
  fi
  case $tool in
    Edit | Write | MultiEdit | NotebookEdit)
      kit_root=$(cd "$(dirname "$(realpath "$0")")/.." && pwd -P)
      case $target/ in
        "$kit_root"/*) deny "the owner's kit install ($kit_root)" ;;
      esac
      hook_files=$(user_hook_files)
      user_file=0
      if grep -Fx -- "$target" <<<"$hook_files" >/dev/null; then
        user_file=1
        before=""
        if [[ -f $target ]]; then before=$(cat "$target"); fi
        after=$(content_after_write "$target")
        problem=$(kit_hooks_problem "$before" "$after")
        [[ -z $problem ]] || deny "changing the kit's hooks in $target: $problem"
      fi
      case $target in
        */.claude/settings.json | */.claude/settings.local.json) claude_settings=1 ;;
        */settings.json | */settings.local.json) claude_settings=$user_file ;;
        *) claude_settings=0 ;;
      esac
      if [[ $claude_settings -eq 1 ]]; then
        after=$(content_after_write "$target")
        problem=$(hooks_off_problem "$after")
        [[ -z $problem ]] || deny "turning Claude Code's hooks off in $target: $problem"
      fi
      ;;
  esac
fi
# The command rules below would read a path as a command (src/environments/ as environment access), so a file path
# stops here: where the full rule set applies, the places that hold credentials are refused by their physical path,
# not any file of the same name (an Ansible inventory's hosts.yml): gh's config directory, git's credential stores,
# ~/.netrc and Claude Code's local settings. gh's and git's directories are taken both where the environment puts
# them (GH_CONFIG_DIR, XDG_CONFIG_HOME) and in their default place under the home directory.
if [[ -z $raw ]]; then
  is_kit_project "$(jq -r '.cwd // empty' <<<"$input")" || mentions_registered_repo "$cmd" || allow
  credential_places=$(
    for place in "${GH_CONFIG_DIR:-$HOME/.config/gh}" "${XDG_CONFIG_HOME:-$HOME/.config}/gh" "$HOME/.config/gh" \
      "${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials" "$HOME/.config/git/credentials" "$HOME/.git-credentials" \
      "$HOME/.netrc"; do
      physical_path "$place" || exit 1
    done
  )
  while IFS= read -r place; do
    case $target/ in
      "$place"/*) deny "reading stored GitHub credentials" ;;
    esac
    if [[ $tool == Grep ]]; then
      case $place/ in
        "$searched"*) deny "searching $target, which holds stored GitHub credentials; search a narrower directory" ;;
      esac
    fi
  done <<<"$credential_places"
  case $target in
    */.claude/settings.local.json) deny "reading stored GitHub credentials" ;;
  esac
  allow
fi
matches 'merge-approval' && deny "merge approval (owner-only commit status)"
# The topic is matched as a value (`--add-topic agent-guardrails`, `names[]=…`, `topic:…`), not as a path or
# repository name (`~/src/agent-guardrails`, `owner/agent-guardrails`), so topics of the kit's own repository
# and commands run from its clone stay possible.
marker_topic='(^|[^/[:alnum:]_.-])agent-guardrails($|[^/[:alnum:]_.-])'
if matches 'topic' && matches "$marker_topic"; then deny "the agent-guardrails topic marks enforced repositories (owner-only)"; fi
if matches '(^|[^[:alnum:]_])gh[[:space:]]+api[[:space:]]+graphql' && matches 'ruleset|commitstatus|statuses'; then
  deny "rulesets or statuses through GraphQL (owner-only)"
fi
# gh api's write flags in every spelling: -X POST, -XPOST, --method=post, -f a=b, -fa=b, --field, --input.
api_write='(-X|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)|(^|[[:space:]])(-[fF]|--(raw-)?field|--input)'
if matches '(^|[^[:alnum:]_])gh[[:space:]]+api' && matches '/rulesets|/statuses/' && matches "$api_write"; then
  deny "writing rulesets or commit statuses (owner-only)"
fi

# split_commands prints one simple command per line. It reads the whole command (so a quoted newline
# cannot hide the next command), splits at ; & | ( ) backticks and newlines outside quotes, keeps quoted
# text inside its command (so `rg "a|b"` stays one rg call and `bash -c "..."` one bash call), keeps a
# heredoc body with the command that reads it, and drops quote characters and backslashes (as the shell
# does, so `ap\prove` is matched as approve). It works on bytes (LC_ALL=C): every separator is ASCII, and a
# UTF-8 awk stops with "multibyte conversion failure" on some non-ASCII text, which blocked harmless commands.
split_commands() {
  LC_ALL=C awk '{ s = s $0 "\n" }
    END {
      out = ""; q = ""; pending = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") { continue }
        if (q != "") { if (c == q) { q = "" } else if (c == "\n") { out = out " " } else { out = out c }; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") {
          j = i + 2
          if (substr(s, j, 1) == "-") { j++ }
          while (substr(s, j, 1) == " ") { j++ }
          word = ""
          while (j <= n && substr(s, j, 1) !~ /[[:space:];&|()<>]/) { word = word substr(s, j, 1); j++ }
          gsub(/["\047\\]/, "", word)
          if (word != "") { pending = word }
          out = out "<<" word " "
          i = j - 1
          continue
        }
        if (c == "\n" && pending != "") {
          # Append the heredoc body to the current command, up to the terminator line.
          rest = substr(s, i + 1)
          while (rest != "") {
            k = index(rest, "\n")
            line = (k > 0) ? substr(rest, 1, k - 1) : rest
            rest = (k > 0) ? substr(rest, k + 1) : ""
            i += (k > 0) ? k : length(line)
            stripped = line
            sub(/^\t+/, "", stripped)
            if (stripped == pending) { break }
            gsub(/\\/, "", line)
            out = out " " line
          }
          pending = ""
          out = out "\n"
          continue
        }
        if (c ~ /[;&|()`\n]/) { c = "\n" }
        out = out c
      }
      printf "%s\n", out
    }'
}
# A command that only reads or records text may mention the owner's commands (a commit message, a PR
# body, a search, a file written from a heredoc); any other program that names them could run them
# (script, xargs, find -exec, bash -c, git difftool/bisect/submodule and similar). Readers lose that
# status when the text can still execute: command substitution, rg --pre, or anything in the same
# command line that runs a shell or interpreter (which could read the "text" from a pipe).
owner_command='(^|[^[:alnum:]_.-])(approve|revoke)-head([[:space:]]|$)|(^|[^[:alnum:]_.-])(agent-)?guardrails[[:space:]]+(on|off|approve|revoke|update|agent[[:space:]]+create)([[:space:]]|$)'
segments=$(split_commands <<<"$raw")
interpreter=0
if grep -Eq '^[[:space:]]*([^[:space:]]*/)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|node|deno|bun|perl|ruby|php|osascript|xargs|eval|source|\.|env|exec|script|expect|unbuffer|nohup|time|sudo)([[:space:]]|$)' <<<"$segments"; then
  interpreter=1
fi
while IFS= read -r segment; do
  grep -Eq "$owner_command" <<<"$segment" || continue
  bare=$(sed -E 's/^[[:space:]]+//' <<<"$segment")
  reader=0
  if [[ $interpreter -eq 0 ]] && ! grep -Eq '\$\(|(^|[[:space:]])--pre(-glob)?([[:space:]=]|$)' <<<"$bare"; then
    if grep -Eq '^([^[:space:]]*/)?(cat|tee|head|tail|grep|egrep|fgrep|rg|ls|wc|diff|shellcheck|stat|file|realpath|readlink|which)([[:space:]]|$)' <<<"$bare" ||
      grep -Eq '^git[[:space:]]+(commit|log|show|grep|status|add|tag)([[:space:]]|$)' <<<"$bare" ||
      grep -Eq '^gh[[:space:]]+(pr|issue|release)[[:space:]]+(create|comment|edit|view|list)([[:space:]]|$)' <<<"$bare"; then
      reader=1
    fi
  fi
  [[ $reader -eq 1 ]] && continue
  deny "owner-only guardrails command (approve-head, revoke-head, guardrails on/off/approve/revoke/update/agent create)"
done <<<"$segments"

# The user's hook registrations (Claude Code's settings in ~/.claude or CLAUDE_CONFIG_DIR, Cursor's and Codex's
# hooks.json) and Claude Code's switch for every hook (disableAllHooks, in any settings file) change only through the
# file tools, which check the change; a shell command may read them. They are named by their path in the home
# directory (~, $HOME, the home path), by CLAUDE_CONFIG_DIR or CODEX_HOME, or by file name after a cd there. A
# project's own registrations (.claude/settings.json without the home directory) stay writable: the kit copies them.
# shellcheck disable=SC2016 # sed's bracket expression, not a shell expansion
home_spelling="(~|\\\$\\{?HOME\\}?|$(sed -E 's/[][\\.*^$(){}?+|]/\\&/g' <<<"$HOME"))"
hook_paths="$home_spelling/\\.claude/settings(\\.local)?\\.json|$home_spelling/\\.(cursor|codex)/hooks\\.json|CLAUDE_CONFIG_DIR|CODEX_HOME|disableAllHooks"
if grep -Eq -- "(^|[;&|(\`[:space:]])(cd|pushd)[[:space:]]+$home_spelling(/\\.(claude|cursor|codex))?/?([[:space:];&|]|\$)" <<<"$cmd"; then
  hook_paths+='|(^|[/[:space:]])(settings(\.local)?|hooks)\.json'
fi
while IFS= read -r segment; do
  grep -Eq -- "$hook_paths" <<<"$segment" || continue
  bare=$(sed -E 's/^[[:space:]]+//' <<<"$segment")
  if [[ $interpreter -eq 0 ]] && ! grep -Eq -- '\$\(|(^|[[:space:]])--pre(-glob)?([[:space:]=]|$)' <<<"$bare" &&
    ! grep -Eq -- ">[[:space:]]*[^[:space:]]*($hook_paths)" <<<"$bare" &&
    { grep -Eq '^([^[:space:]]*/)?(cat|head|tail|grep|egrep|fgrep|rg|jq|wc|diff|ls|stat|file|realpath|readlink)([[:space:]]|$)' <<<"$bare" ||
      grep -Eq '^git[[:space:]]+(commit|log|show|grep|status|add|diff|blame)([[:space:]]|$)' <<<"$bare" ||
      grep -Eq '^gh[[:space:]]+(pr|issue|release)[[:space:]]+(create|comment|edit|view|list)([[:space:]]|$)' <<<"$bare"; }; then
    continue
  fi
  deny "changing the agents' hook registrations, or switching hooks off, from the shell; change such a file with the Edit tool, which checks that the kit's hooks stay"
done <<<"$segments"

# Everything below applies inside kit repositories, to commands that name an enforced repository, and to
# commands that address a repository by its numeric id (which hides its name).
is_kit_project "$(jq -r '.cwd // empty' <<<"$input")" || mentions_registered_repo "$cmd" ||
  matches 'repositories/[0-9]+' || allow

# Credentials and token fallbacks.
matches 'security[[:space:]]+(find|dump|export)-' && deny "reading the macOS keychain"
matches 'git[[:space:]]+credential' && deny "git credential helper access"
matches "$credential_files" && deny "reading stored GitHub credentials"
matches '(GH|GITHUB)_(ENTERPRISE_)?TOKEN|GH_CONFIG_DIR' && deny "referencing the GitHub token or gh config (read, override or unset)"
# Without the session's environment, gh and git fall back to the owner's own login (keychain, ~/.config/gh): env -i,
# env -, exec -c, and starting a shell outside this session (tmux, screen, a new terminal, osascript's do shell
# script, launchd or cron jobs, ssh to this machine).
matches "${command_at}env([[:space:]]+(-[uCPS][[:space:]]*[^[:space:];&|]+|-[a-zA-Z0-9]+|--[a-z-]+(=[^[:space:];&|]*)?))*[[:space:]]+(-[a-zA-Z0-9]*i[a-zA-Z0-9]*|--ignore-environment|-)([[:space:]]|\$)" &&
  deny "clearing the environment (gh and git would fall back to the owner's login)"
matches "${command_at}exec[[:space:]]+-[a-zA-Z]*c" && deny "clearing the environment (gh and git would fall back to the owner's login)"
# Matched as commands with their arguments, so a commit message about a screen reader or tmux stays possible. ssh
# counts by its destination, after its options, not by a localhost in the remote command or a port forward.
if matches "${command_at}tmux[[:space:]]+(-[a-zA-Z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*(new(-session|-window)?|neww|split(-window|w)|send(-keys)?|respawn(-pane|-window)?|run(-shell)?|attach(-session)?)([[:space:]]|\$)" ||
  matches "${command_at}screen[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*[dmX]" ||
  matches "${command_at}crontab[[:space:]]+(-[eir]|[^-[:space:];&|])" ||
  matches "${command_at}launchctl[[:space:]]+(submit|bootstrap|load|asuser|start|kickstart)" ||
  matches "${command_at}osascript[^;&|]*do[[:space:]]+(shell[[:space:]]+)?script" ||
  matches "${command_at}open[[:space:]][^;&|]*(-a[[:space:]]*(Terminal|iTerm[0-9]*)([.[:space:]]|\$)|\\.(command|tool|terminal)([[:space:]]|\$))" ||
  matches_case "${command_at}ssh([[:space:]]+(-[46AaCfGgKkMNnqsTtVvXxYy]+|-[BbcDEeFIiJLlmOoPpQRSWw][[:space:]]*[^[:space:];&|]+))*[[:space:]]+([^[:space:];&|@]+@)?(localhost|LOCALHOST|127\\.0\\.0\\.1|::1|\\[::1\\])([[:space:];&|:]|\$)"; then
  deny "starting a shell outside this session (it would run with the owner's login, not the session's)"
fi
matches 'pending_deployments|deployment_protection|/environments/' && deny "deployment approval or environment access"
matches '/statuses/' && deny "commit statuses (merge approval is owner-only)"
# Printing the environment: printenv, set, export or declare -x without arguments, env without a command, ps with
# environments (e, -E), and interpreters reading their environment, each as a command.
# shellcheck disable=SC2016 # backticks are literal regex characters
if matches "${command_at}(printenv|export([[:space:]]+-p)?|set|(declare|typeset)[[:space:]]+-[a-zA-Z]*[xp][a-zA-Z]*)([[:space:]]*(\$|[;&|)\`]))" ||
  matches "${command_at}env([[:space:]]+(-[uCPS][[:space:]]*[^[:space:];&|]+|-[a-zA-Z0-9]+|--[a-z-]+(=[^[:space:];&|]*)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*))*[[:space:]]*(\$|[;&|)\`])" ||
  matches_case "${command_at}ps[[:space:]]+([AaCcdEfghjLlMmOopSTtUuvwXx]*e[AaCcdEfghjLlMmOopSTtUuvwXx]*([[:space:]]|\$)|([^;&|]*[[:space:]])?-[a-zA-Z]*E)" ||
  matches "${command_at}(python[0-9.]*|node|deno|bun|perl|ruby|php)[[:space:]].*((^|[^[:alnum:]_])environ([^[:alnum:]_]|\$)|process\\.env|%ENV|ENV\\[)"; then
  deny "dumping the environment (may expose tokens)"
fi
# Git settings that hand git another credential, URL, transport or hook, by git config, git -c or the environment.
git_keys='credential|insteadof|hookspath|sshcommand|askpass|extraheader|include\.|includeif|fsmonitor|url\.'
matches "git[[:space:]]+config[^;&|]*($git_keys)" && deny "changing git credential/URL/hook configuration"
# git -c <key>=<value> and git --config-env=<key>=<variable> for one command: taken with their case (git -C names a
# directory, git switch -c a branch) and only as an assignment, which a config override always is; the key is
# matched without case, as git reads it.
if matches 'git[[:space:]]'; then
  overrides=$(grep -oE -- '(^|[[:space:]])(-c[[:space:]]*|--config-env[[:space:]=]+)[^[:space:];&|=]+=' <<<"$cmd" || true)
  ! grep -Eiq -- "$git_keys" <<<"$overrides" || deny "overriding git's credential, URL or hook settings for one command"
fi
# The agent's identity reaches git through GIT_CONFIG_* (agent_env_exports): setting, clearing (unset, env -u) or
# reading these variables changes which credentials git uses.
matches_case '(^|[^[:alnum:]_])(GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+|PARAMETERS|GLOBAL|SYSTEM|NOSYSTEM)|GIT_SSH(_COMMAND|_VARIANT)?|GIT_ASKPASS|SSH_ASKPASS|GIT_EXEC_PATH|GIT_TEMPLATE_DIR)([^[:alnum:]_]|$)' &&
  deny "changing git's configuration through the environment (GIT_CONFIG_*, GIT_SSH*, GIT_ASKPASS: set, cleared or read)"

# Git over SSH is refused so pushes go through the same HTTPS credentials as gh.
matches 'git[[:space:]]+(push|remote|clone|fetch|pull)[^;&|]*(git@github\.com|ssh://)' && deny "git over SSH (use the HTTPS remote with the agent token)"

# Direct GitHub API access outside gh.
matches '(curl|wget|http|https|xh)[^;&|]*(api\.github\.com|github\.com/[^[:space:]]*/(settings|reviews|merge))' &&
  deny "calling the GitHub API directly"

# Pushing to the default branch or rewriting remote refs.
if matches 'git[[:space:]]+push'; then
  matches 'git[[:space:]]+push[^;&|]*([[:space:]:+/](main|master)([[:space:]]|$|[;&|])|--mirror|--tags|--delete|[[:space:]]-d([[:space:]]|$)|--all)' &&
    deny "pushing to the default branch, deleting remote refs or pushing tags/all refs"
fi

# A gh call whose flags this guard checks (merge, edit, auth, api) takes them only from its literal text: command
# substitution, backticks or a variable in it could add --admin, --base or a write method the check never sees.
while IFS= read -r simple; do
  if grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+(pr[[:space:]]+(merge|edit)|auth|api)([[:space:]]|$)' <<<"$simple" &&
    grep -Eq '[$`]' <<<"$simple"; then
    deny "command substitution or a variable in a gh merge, edit, auth or api call; write its arguments literally"
  fi
done < <(tr ';&|' '\n' <<<"$cmd")

# gh: allow-list of subcommands; the rest needs the human. Each call is checked twice: up to the next separator, so
# every flag counts, also one after a parenthesis in a title; and up to the next command substitution or
# redirection, so a call nested in another's arguments ($(gh ...), `gh ...`, <(gh ...)) is a call of its own. Flags
# are matched in every spelling: --base x, --base=x, -Bx.
# shellcheck disable=SC2016 # $ is a literal character of the bracket expression in the extraction below
while IFS= read -r call; do
  [[ -n $call ]] || continue
  read -r _gh group action rest <<<"$call" || true
  case "$group $action" in
    "pr create" | "pr view" | "pr list" | "pr checks" | "pr diff" | "pr status" | "pr comment" | "pr ready" | "pr close" | "pr checkout") ;;
    "pr edit")
      ! grep -Eq -- '(^|[[:space:]])(--base([[:space:]=]|$)|-B)' <<<"$rest" || deny "retargeting a PR's base branch"
      ;;
    "pr merge")
      # Kit repositories require the owner's approval server-side (ruleset), so a plain merge is refused there;
      # only an admin merge could bypass it.
      ! grep -Eq -- '(^|[[:space:]])--admin([[:space:]=]|$)' <<<"$rest" || deny "admin merge bypasses protection"
      ;;
    "issue view" | "issue list" | "issue comment" | "issue create" | "issue edit" | "issue status" | "issue close" | "issue reopen") ;;
    "run view" | "run list" | "run watch" | "run download") ;;
    "repo view" | "repo clone" | "release view" | "release list" | "workflow view" | "workflow list") ;;
    "label list" | "search "* | "status "* | "browse "*) ;;
    "auth status")
      ! grep -Eq -- '(^|[[:space:]])(-[a-zA-Z]*t[a-zA-Z]*|--show-token)([[:space:]=]|$)' <<<"$rest" ||
        deny "printing the GitHub token"
      ;;
    "api "*)
      api_args="$action $rest"
      [[ $action != graphql ]] || deny "gh api graphql (may mutate: reviews, merges, protections)"
      if grep -Eiq -- "$api_write" <<<"$api_args"; then
        deny "gh api write call"
      fi
      if grep -Eiq -- 'pending_deployments|/reviews|rulesets|/protection|/environments|/hooks|/keys|/collaborators|/secrets|/variables|/actions/permissions' <<<"$api_args"; then
        deny "gh api on protected repository resources"
      fi
      ;;
    *) deny "gh $group $action is not on the allow-list" ;;
  esac
done < <({
  grep -oE '(^|[/;&|(`"'"'"'[:space:]])gh[[:space:]]+[a-z-]+([[:space:]]+[^;&|`"'"'"']*)?' <<<"$cmd" || true
  grep -oE '(^|[/;&|(`"'"'"'[:space:]])gh[[:space:]]+[a-z-]+([[:space:]]+[^;&|`"'"'"'$()<>]*)?' <<<"$cmd" || true
} | sed -E 's/^[/;&|(`"'"'"'[:space:]]+//; s/^.*\/gh /gh /')

allow
