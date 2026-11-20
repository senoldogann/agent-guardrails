#!/bin/bash -p
# Global PreToolUse hook for Bash, registered by install.sh in ~/.claude/settings.json (Claude Code) and in
# Codex's hooks.json (Codex sends the same input). Cursor reaches it through cursor-guard.sh. It is the single
# source of truth for what the agent may run. Given a file tool's path (Claude Code's Read, Grep, Glob, Edit,
# Write, MultiEdit, NotebookEdit; Cursor's file reads) instead of a command, it checks only the rules on the
# owner's files and credential files.
# Scope: the full rule set applies in kit repositories (.agent/bin/ci-guard exists, or the origin is in the
# owner's list of enforced repositories) and to any command that names an enforced repository, from any
# directory. Everywhere else the agent works as if the kit did not exist, with one exception that protects
# the kit repositories themselves: nothing may run the owner's commands (approve-head, revoke-head,
# guardrails on/off/approve/revoke/update/agent create), post a `merge-approval` status, touch the list of enforced
# repositories or the kit install, or change the agents' hook registrations.
# In kit repositories the agent works with the owner's GitHub identity unless agent-identity.sh switched the
# session to the agent App's bot, and the owner's login stays reachable either way, so actions reserved for
# the human must be blocked before they run: approving or admin-merging PRs, approving deployments,
# changing repo settings/rulesets/workflows/secrets, reading credentials, and pushing to the default
# branch. `gh` is allow-listed per subcommand; everything else is a deny-list over the whole command
# string, including text inside quotes (so `bash -c "..."` wrappers are covered).
# Limits: obfuscated commands (string concatenation, scripts written to files) can evade text matching;
# the ruleset on GitHub, which needs the owner's typed approval per HEAD, is the authority.
# Exit code 2 blocks the call and shows stderr to the agent. Bash runs it with -p, so the environment cannot
# make it source a file first (BASH_ENV) or replace its functions.
set -euo pipefail
# Fail closed: a call is allowed only through allow (below); every other end blocks it with 2. That covers an
# internal error (missing jq, an unreadable file) and the fatal ones (a failed source, an unset variable) after
# which Bash 3.2, macOS's /bin/bash, runs the EXIT trap with status 0. A deny, also one in a subshell, ends with 2
# and has said why. Subshells keep their own exit codes. Not inherited from the environment: only allow sets it.
allowed=0
# shellcheck disable=SC2154 # status is assigned inside the trap
trap 'status=$?; if [[ ${allowed:-} != 1 ]]; then [[ $status -eq 2 ]] || printf "BLOCKED by bash-guard: internal error (exit %s); ask the user to check the hook\n" "$status" >&2; exit 2; fi' EXIT
allow() {
  allowed=1
  exit 0
}
# shellcheck source=kit-project.sh
source "$(dirname "$(realpath "$0")")/kit-project.sh"

input=$(cat)
# One jq call for every field (each call is a process the agent waits for); @sh quotes them for eval. A file tool
# (Read, Grep, Glob, Edit, Write, MultiEdit, NotebookEdit; other agents' read tools through their adapters) is
# checked by its path, against the rules on the owner's files: reads against the owner's settings and credential
# files, writes also against the kit install and the agents' hook registrations.
# A field that is not a string (an array would become several words for eval) fails jq, and so the call.
fields=$(jq -r 'def text: (. // "") | if type == "string" then . else error("a hook input field is not a string") end;
  @sh "tool=\(.tool_name | text) raw=\(.tool_input.command | text) cwd=\(.cwd | text) read_path=\(.tool_input.file_path // .tool_input.notebook_path // .tool_input.path | text)"' <<<"$input")
tool="" raw="" cwd="" read_path=""
eval "$fields"
# Grep without a path searches the session's directory.
[[ $tool != Grep || -n $read_path ]] || read_path=$cwd
[[ -n $raw || -n $read_path ]] || allow

deny() {
  printf 'BLOCKED by bash-guard: %s\nThis is reserved for the human (approvals, merges, credentials, repository settings). Do not work around it; ask the user to do it.\n' "$1" >&2
  exit 2
}

lower() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

# Normalize common spellings so quoting or path tricks do not hide a gh call: drop quotes and backslashes, and turn
# $(which gh)/$(command -v gh)/`which gh` into gh. A line that ends in a backslash may continue on the next one, or
# (after an escaped backslash, or in a heredoc) not: the command is matched both as written and with such lines
# joined, so neither a flag on a continuation line nor a command after a line that only looks continued slips by.
quote_chars=$'\\\\"\''
# shellcheck disable=SC2016 # $( and backticks are literal text to rewrite, not expansions
gh_lookup='s/\$\((which|command -v|type -p) gh\)/gh/g; s/`(which|command -v|type -p) gh`/gh/g'
# awk joins in one pass; Bash 3.2's ${raw//...} slows down with the square of a long input, past the hook's time limit.
joined=$(LC_ALL=C awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }' <<<"$raw")
if [[ -n $raw ]]; then
  cmd=$(tr -d "$quote_chars" <<<"$raw" | sed -E "$gh_lookup")
  [[ $joined == "$raw" ]] || cmd+=$'\n'$(tr -d "$quote_chars" <<<"$joined" | sed -E "$gh_lookup")
else
  cmd=$read_path
fi

# grep that ends the guard on an error (status 2, a broken pattern) instead of reading it as "no match".
check_grep() {
  local status=0
  grep "$@" || status=$?
  [[ $status -le 1 ]] || exit 3
  return "$status"
}

matches() {
  check_grep -Eiq -- "$1" <<<"$cmd"
}

# Like matches, with case: for options whose case changes their meaning (ps -E shows environments, ps -e does not).
matches_case() {
  check_grep -Eq -- "$1" <<<"$cmd"
}

# Prints an absolute path with "." and ".." resolved as text, as Claude Code resolves a tool's path: x/.. is the
# directory that holds x, whether x exists or not. Argument: absolute path.
lexical_path() {
  local rest=${1#/} part out=""
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=""; fi
    case $part in
      "" | .) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

# Prints a path with "." and ".." resolved as text and then every symbolic link resolved, also in a part that does
# not exist yet (a file a write would create), so no link can dress up a protected path. Relative paths are taken
# from the tool call's directory, and a leading ~ is the home directory (Grep hands its path over as written and
# expands ~ itself).
physical_path() {
  local path=$1 rest="" link dir hops=0
  # shellcheck disable=SC2088 # a literal ~, as Grep hands it over
  case $path in
    "~") path=$HOME ;;
    "~/"*) path="$HOME/${path#"~/"}" ;;
  esac
  [[ $path == /* ]] || path="$cwd/$path"
  path=$(lexical_path "$path")
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
      # A relative target counts from the link's own directory as the file system resolves it, links included: its
      # ".." is the parent of that real directory, not of the spelling the path came in.
      if [[ $link != /* ]]; then
        dir=$(cd -P "$(dirname "$path")" && pwd -P) || return 1
        link="$dir/$link"
      fi
      path=$(lexical_path "$link")
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

# Succeeds when a path is a place or lies below it: by the text of their physical paths, and by file identity
# wherever both exist, so the same place under another spelling (the /System/Volumes/Data firmlink, another case on
# macOS) counts. Arguments: path, place.
is_within() {
  local path=$1 place=$2
  case $path/ in
    "$place"/*) return 0 ;;
  esac
  [[ -e $place ]] || return 1
  while :; do
    if [[ -e $path && $path -ef $place ]]; then return 0; fi
    [[ $path != / && -n $path ]] || return 1
    path=${path%/*}
    [[ -n $path ]] || path=/
  done
}

# Succeeds when two paths name the same file: by identity where both exist, otherwise by the same directory and the
# same name without case (macOS reads a new Settings.json as settings.json). Arguments: two paths.
same_file() {
  local dir1=${1%/*} dir2=${2%/*}
  if [[ -e $1 && -e $2 ]]; then
    [[ $1 -ef $2 ]]
    return
  fi
  [[ -n $dir1 ]] || dir1=/
  [[ -n $dir2 ]] || dir2=/
  [[ $dir1 == "$dir2" || (-e $dir1 && -e $dir2 && $dir1 -ef $dir2) ]] || return 1
  [[ $(lower "${1##*/}") == "$(lower "${2##*/}")" ]]
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
# replacements applied as the tools apply them (the first occurrence, or every one with replace_all). Fails when an
# old_string is not in the file as written: the Edit tool also matches looser spellings (curly quotes for straight
# ones), which this replay could not follow. Argument: the file.
content_after_write() {
  # shellcheck disable=SC2016 # jq's $variables, not the shell's
  local program='
    def replaced($e): ($e.old_string // "") as $old | ($e.new_string // "") as $new
      | if $old == "" then $new
        elif (contains($old) | not) then error("old_string is not in the file as written")
        elif ($e.replace_all // false) then split($old) | join($new)
        else split($old) as $parts | $parts[0] + $new + ($parts[1:] | join($old))
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
# or nothing. Entries count only where the agents read them: in an array per event, and, for Claude Code and Codex,
# in an array of hooks per matcher. Arguments: the file's content before and after the write.
kit_hooks_problem() {
  jq -rn --arg before "$1" --arg after "$2" '
    def kit_hooks: [(.hooks | if type == "object" then . else {} end) | to_entries[] | .key as $event
      | (.value | if type == "array" then .[] else empty end)
      | if type == "object" and (.hooks | type) == "array" then (.matcher // "") as $matcher | .hooks[] | [$event, $matcher, .]
        elif type == "object" and has("command") then [$event, "", .]
        else empty end
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

# Prints why content is no strict JSON as JSON.parse reads it in Claude Code, Cursor and Codex (no NaN, no leading
# zero or plus sign, no byte order mark), or nothing: jq accepts those, and an agent that cannot parse its settings
# runs without their hooks. Argument: the content.
strict_json_problem() {
  python3 -I -c '
import json, sys
def refuse(name):
    raise ValueError(name + " is not JSON")
try:
    json.loads(sys.stdin.read(), parse_constant=refuse)
except ValueError as error:
    print(error)
' <<<"$1"
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
credential_files='\.config/gh|hosts\.yml|\.git-credentials|\.config/git/credentials|\.netrc|settings\.local\.json'

# Everywhere: the owner's commands, the approval status and the rulesets of kit repositories, and the
# owner's list of enforced repositories are the owner's alone.
# .config as a path component, not inside a word: `model.configuration` next to an agent-guardrails path is fine.
if matches '\.config([/[:space:]]|$)' && matches 'agent-g'; then deny "the owner's list of enforced repositories"; fi
if matches '\.local/share' && matches 'agent-g'; then deny "the owner's kit install"; fi
# File tools, everywhere, by the physical path (every link resolved) and by file identity: none reads or writes the
# owner's kit settings (~/.config/agent-guardrails: the enforced repositories and the agent App's private key), and
# a Grep, which reads every file below its directory, does not search ~/.config or a parent of it. Writes also stay
# out of the kit install this hook runs from; leave every kit hook entry in the user's hook registrations as it is
# (they may change anything else there); and set disableAllHooks in no Claude Code settings file, the user's or a
# project's. Reads of the kit install go by the path's text above, so a skill linked from ~/.claude/skills into it
# can still be read.
if [[ -z $raw ]]; then
  settings_root=$(physical_path "$(dirname "$(guardrails_registry)")")
  target=$(physical_path "$read_path")
  ! is_within "$target" "$settings_root" || deny "the owner's kit settings (enforced repositories, agent App key)"
  if [[ $tool == Grep ]] && is_within "${settings_root%/*}" "$target"; then
    deny "searching $target, which holds the owner's kit settings and credentials; search a narrower directory"
  fi
  case $tool in
    Edit | Write | MultiEdit | NotebookEdit)
      kit_root=$(cd "$(dirname "$(realpath "$0")")/.." && pwd -P)
      ! is_within "$target" "$kit_root" || deny "the owner's kit install ($kit_root)"
      user_file=0
      hook_files=$(user_hook_files)
      while IFS= read -r hook_file; do
        if same_file "$target" "$hook_file"; then user_file=1; fi
      done <<<"$hook_files"
      if [[ $user_file -eq 1 ]]; then
        before=""
        if [[ -f $target ]]; then before=$(cat "$target"); fi
        after=$(content_after_write "$target") ||
          deny "an edit of $target whose old_string is not in the file as written; the Edit tool would also match looser spellings, which this check cannot follow"
        problem=$(kit_hooks_problem "$before" "$after")
        [[ -z $problem ]] || deny "changing the kit's hooks in $target: $problem"
        problem=$(strict_json_problem "$after")
        [[ -z $problem ]] || deny "the agents could not read $target after this write ($problem), and would run without its hooks"
      fi
      case $(lower "$target") in
        */.claude/settings.json | */.claude/settings.local.json) claude_settings=1 ;;
        */settings.json | */settings.local.json) claude_settings=$user_file ;;
        *) claude_settings=0 ;;
      esac
      if [[ $claude_settings -eq 1 ]]; then
        after=$(content_after_write "$target") ||
          deny "an edit of $target whose old_string is not in the file as written; the Edit tool would also match looser spellings, which this check cannot follow"
        problem=$(hooks_off_problem "$after")
        [[ -z $problem ]] || deny "turning Claude Code's hooks off in $target: $problem"
      elif jq -e '[.tool_input.content, .tool_input.new_string, .tool_input.edits[]?.new_string] | map(strings) | any(test("disableAllHooks"))' \
        <<<"$input" >/dev/null; then
        # Any other file that would hold a JSON object setting disableAllHooks: a copy from the shell could turn it
        # into settings later. Text that only mentions the setting, as documentation does, is no JSON object.
        if after=$(content_after_write "$target"); then
          problem=$(jq -rn --arg after "$after" '(try ($after | fromjson) catch null) as $new
            | if ($new | type) == "object" and ($new.disableAllHooks // false) != false then "it sets disableAllHooks" else empty end')
          [[ -z $problem ]] || deny "writing settings that turn Claude Code's hooks off into $target"
        fi
      fi
      ;;
  esac
fi
# The command rules below would read a path as a command (src/environments/ as environment access), so a file path
# stops here: where the full rule set applies, the places that hold credentials are refused by their physical path
# and identity, not any file of the same name (an Ansible inventory's hosts.yml): gh's config directory, git's
# credential stores, ~/.netrc and Claude Code's local settings. gh's and git's directories are taken both where the
# environment puts them (GH_CONFIG_DIR, XDG_CONFIG_HOME) and in their default place under the home directory.
if [[ -z $raw ]]; then
  is_kit_project "$cwd" || mentions_registered_repo "$cmd" || allow
  credential_places=$(
    for place in "${GH_CONFIG_DIR:-$HOME/.config/gh}" "${XDG_CONFIG_HOME:-$HOME/.config}/gh" "$HOME/.config/gh" \
      "${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials" "$HOME/.config/git/credentials" "$HOME/.git-credentials" \
      "$HOME/.netrc"; do
      physical_path "$place" || exit 1
    done
  )
  while IFS= read -r place; do
    ! is_within "$target" "$place" || deny "reading stored GitHub credentials"
    if [[ $tool == Grep ]] && is_within "$place" "$target"; then
      deny "searching $target, which holds stored GitHub credentials; search a narrower directory"
    fi
  done <<<"$credential_places"
  case $(lower "$target") in
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
# Prints the lines of its input that match; ends the guard on a grep error instead of reading it as "no match".
# Arguments: grep's options and pattern.
grep_lines() {
  local status=0
  grep "$@" || status=$?
  [[ $status -le 1 ]] || exit 3
}

segments=$(split_commands <<<"$raw")
[[ $joined == "$raw" ]] || segments+=$'\n'$(split_commands <<<"$joined")
interpreter=0
if check_grep -Eq '^[[:space:]]*([^[:space:]]*/)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|node|deno|bun|perl|ruby|php|osascript|xargs|eval|source|\.|env|exec|script|expect|unbuffer|nohup|time|sudo)([[:space:]]|$)' <<<"$segments"; then
  interpreter=1
fi

# Succeeds for a segment that only reads or records text: one of the given readers, a git command that records or
# shows (commit, log, show, grep, status, add, tag, diff, blame), or a gh PR, issue or release text. Not when the text
# can still execute or write elsewhere: command substitution, rg --pre, git's --output, -O/--open-files-in-pager or
# --ext-diff, or a shell or interpreter anywhere in the command line (which could read the "text" from a pipe).
# Arguments: the segment, the readers (a pattern of command names).
reads_only() {
  local bare
  bare=$(sed -E 's/^[[:space:]]+//' <<<"$1")
  [[ $interpreter -eq 0 ]] || return 1
  ! check_grep -Eq -- '\$\(|(^|[[:space:]])(--pre(-glob)?|--output|--open-files-in-pager|--ext-diff)([[:space:]=]|$)|(^|[[:space:]])-O' <<<"$bare" ||
    return 1
  check_grep -Eq -- "^([^[:space:]]*/)?($2)([[:space:]]|\$)" <<<"$bare" ||
    check_grep -Eq '^git[[:space:]]+(commit|log|show|grep|status|add|tag|diff|blame)([[:space:]]|$)' <<<"$bare" ||
    check_grep -Eq '^gh[[:space:]]+(pr|issue|release)[[:space:]]+(create|comment|edit|view|list)([[:space:]]|$)' <<<"$bare"
}
text_readers='cat|tee|head|tail|grep|egrep|fgrep|rg|ls|wc|diff|shellcheck|stat|file|realpath|readlink|which'

# A command that only reads or records text may mention the owner's commands (a commit message, a PR body, a
# search, a file written from a heredoc); any other program that names them could run them (script, xargs,
# find -exec, bash -c, git difftool/bisect/submodule, git grep -O and similar). A command may follow a short option
# directly (git grep -O'cmd' runs cmd as its pager).
owner_start='(^|[^[:alnum:]_.-]|(^|[[:space:]])-[A-Za-z])'
owner_command="$owner_start(approve|revoke)-head([[:space:]]|\$)|$owner_start(agent-)?guardrails[[:space:]]+(on|off|approve|revoke|update|agent[[:space:]]+create)([[:space:]]|\$)"
matched=$(grep_lines -E -- "$owner_command" <<<"$segments")
while IFS= read -r segment; do
  [[ -n $segment ]] || continue
  reads_only "$segment" "$text_readers" && continue
  deny "owner-only guardrails command (approve-head, revoke-head, guardrails on/off/approve/revoke/update/agent create)"
done <<<"$matched"

# Where a command word starts. Narrow by default: the start of a line, a separator (; & | ` and the ) of a case
# arm), a subshell or command substitution, a here-string, a shell keyword after a separator (if, then, do, {, !),
# an assignment (X=1 cmd), or the text a wrapper runs (sh -c, bash -c, eval, exec, sudo, nohup, command, builtin,
# xargs, env with options or assignments), with an optional directory before the word (/usr/bin/env). So a commit
# message that mentions "export", "if set" or "tmux new-session", or a scope like fix(env), is no command. A command
# line that runs a shell or interpreter, which can read any text as a command (echo "..." | bash), or a wrapper with
# arguments of its own (nice, timeout, stdbuf, exec -a, a leading redirection, a case statement), is matched
# broadly: after any blank.
shell_runner='^[[:space:]]*([0-9]*[<>][^[:space:]]*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(([^[:space:]]*/)?(sudo|doas|env|nohup|nice|timeout|stdbuf|ionice|taskset|caffeinate|chronic|flock|setsid|time|command|builtin|exec)([[:space:]]+[^[:space:]]+)*[[:space:]]+)?([^[:space:]]*/)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|node|deno|bun|perl|ruby|php|osascript|xargs|eval|source|\.|script|expect|unbuffer)([[:space:]]|$)'
broad_trigger='^[[:space:]]*([0-9]*[<>]|case[[:space:]]|([^[:space:]]*/)?(nice|timeout|stdbuf|ionice|taskset|caffeinate|chronic|flock|setsid|doas|exec)([[:space:]]|$))'
if check_grep -Eq -- "$shell_runner" <<<"$segments" || check_grep -Eq -- "$broad_trigger" <<<"$segments"; then
  # shellcheck disable=SC2016 # backticks are literal regex characters
  command_at='(^|[;&|(`"'"'"'[:space:]])[[:space:]]*([^[:space:];&|`()]*/)?'
else
  # shellcheck disable=SC2016 # backticks and $ are literal regex characters
  command_at='(^|[;&|`)]|(^|[;&|[:space:]])\(|\$\(|<<<|(^|[;&|`(){])[[:space:]]*(if|then|else|elif|do|while|until|time|!|\{)[[:space:]]|(^|[[:space:]])[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]|(^|[[:space:]/])((ba|z|da|k|fi)?sh[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*c|eval|exec|sudo|nohup|command|builtin|xargs|env([[:space:]]+(-[a-zA-Z0-9]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*))*)[[:space:]])[[:space:]]*([^[:space:];&|`()]*/)?'
fi

# The user's hook registrations and Claude Code's switch for every hook change only through the file tools, which
# check the change; a shell command may read them. A command that is no reader may not name:
# - a registration of the user's (settings.json, settings.local.json, hooks.json) in their Claude Code, Cursor or
#   Codex directory, by ~, ~user, $HOME, the home path or .. from a project, or by CLAUDE_CONFIG_DIR or CODEX_HOME as
#   a variable or by its value; nor a name there that the shell expands (~/.claude/*, ~/.claude/$f, ~/.c*/x);
# - a registration's name in a command that also names such a directory (cp x/settings.json ~/.claude/), after a cd
#   or -C out of the project (cd, cd ~, cd /, cd .., cd $X), or when it runs in the home directory or such a directory;
# - a command that writes or removes files it does not name (rm, mv, ln, cp -R or of expanded names, tar, unzip,
#   rsync, xargs, find -delete or -exec) in a command that names such a directory, on the home directory itself
#   (cp -R x/. ~), or after a cd out of the project on an agents' directory or an expanded hidden name (rm -rf .c*);
# - such a directory, the home directory or a registration's path in a command that runs a shell or an interpreter;
# - an assignment, export or unset of CLAUDE_CONFIG_DIR or CODEX_HOME (an agent run without the hooks);
# - disableAllHooks.
# Paths are matched as the shell reads them: without quotes and backslashes, with ./, // and x/.. resolved. This is
# text: a path that a script, an archive or a variable set elsewhere builds at run time stays out of sight. A
# project's own registrations stay writable from the shell (the kit copies them, git restores them); the file tools
# refuse JSON that sets disableAllHooks in any file.
# shellcheck disable=SC2016 # sed's bracket expression, not a shell expansion
escape_regex() {
  if [[ $1 == *[][\\.*^\$\(\)\{\}?+\|]* ]]; then sed -E 's/[][\\.*^$(){}?+|]/\\&/g' <<<"$1"; else printf '%s\n' "$1"; fi
}
hook_segments=$(sed -E -e ':a' -e 's#/\./#/#g; s#//+#/#g; s#/([^/[:space:];&|.]|\.[^/[:space:];&|.])[^/[:space:];&|]*/\.\./#/#; ta' -e 's#/\.([[:space:];&|]|$)#\1#g' <<<"$segments")
home_spelling="(~[A-Za-z0-9_.-]*|\\\$\\{?HOME\\}?|$(escape_regex "$HOME"))"
config_spelling='\$\{?(CLAUDE_CONFIG_DIR|CODEX_HOME)\}?'
for place in "${CLAUDE_CONFIG_DIR:-}" "${CODEX_HOME:-}"; do
  [[ -z $place ]] || config_spelling+="|$(escape_regex "${place%/}")"
done
# A path component the shell expands (a glob, a brace, a variable, a command substitution) may name anything.
# shellcheck disable=SC2016 # $ and backticks are literal regex characters
wild='[^/[:space:];&|]*[][*?{$`][^/[:space:];&|]*'
# Where a name starts and ends: a blank, a separator, a closing parenthesis, or a quote (kept inside the other kind).
before=$'(^|[/[:space:]=\'"])'
separator=$'([[:space:];&|)`\'"]|$)'
agents_dir='\.(claude|cursor|codex)'
# An agents' directory: in the home directory (or an entry there that the shell expands), by a configuration
# variable, or through .. from wherever the command runs (cp x ../.claude/settings.json from ~/proj).
hook_dir="($home_spelling/($agents_dir|$wild)|$config_spelling|\\.\\./([^[:space:];&|]*/)?$agents_dir)"
hook_name='(settings(\.local)?\.json|hooks\.json)'
hook_file="$hook_dir/($hook_name([^[:alnum:]_.-]|\$)|$wild$separator)"
hook_dir_alone="$hook_dir/?$separator"
home_alone="$home_spelling/?$separator"
loose_name="$before$hook_name([^[:alnum:]_.-]|\$)"
loose_dir="$before($agents_dir|\\.$wild)/?$separator"
interpreter_dir="$before$agents_dir(/$hook_name([^[:alnum:]_.-]|\$)|/?$separator)"
tree_writer="(^|[[:space:]/])((rm|mv|rmdir|unlink|ln|rsync|tar|bsdtar|gtar|unzip|ditto|install|cpio|pax|xargs|parallel)[[:space:]]|cp[[:space:]]+(.*[[:space:]])?(-[a-zA-Z]*[rRa]|--recursive|--archive|([^[:space:]]*/)?$wild([[:space:]]|\$)))|[[:space:]]-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)([[:space:]]|\$)"
hook_vars='(^|[[:space:]])(CLAUDE_CONFIG_DIR|CODEX_HOME)=|(export|unset|-u)[[:space:]]+([^;&|]*[[:space:]])?(CLAUDE_CONFIG_DIR|CODEX_HOME)([^[:alnum:]_]|$)|disableAllHooks'
agents_dir_named=0
if check_grep -Eq -- "$hook_dir_alone" <<<"$hook_segments"; then agents_dir_named=1; fi
# A registration's bare name counts in a command that names an agents' directory, after a cd or -C out of the
# project, and when the command runs in the home directory or in one of the agents' directories.
loose_names=$agents_dir_named
if check_grep -Eq -- "(^|[;&|(\`[:space:]])(cd|pushd)([[:space:]]+([~/\$.]|-)[^;&|]*)?[[:space:]]*([;&|]|\$)|(^|[[:space:]])(-C|--work-tree|--git-dir|--directory)([[:space:]]+|=)?[~/\$.]" <<<"$hook_segments"; then
  loose_names=1
fi
if [[ -n $cwd && -d $cwd ]]; then
  for place in "$HOME" "$HOME/.claude" "$HOME/.cursor" "$HOME/.codex" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${CODEX_HOME:-$HOME/.codex}"; do
    if [[ -e $place && $cwd -ef $place ]] || { [[ $place != "$HOME" && -e $place ]] && is_within "$cwd" "$(realpath "$place")"; }; then
      loose_names=1
    fi
  done
fi
hook_candidates="$hook_file|$hook_dir_alone|$hook_vars|$home_alone"
[[ $loose_names -eq 0 ]] || hook_candidates+="|$loose_name|$loose_dir"
[[ $agents_dir_named -eq 0 ]] || hook_candidates+="|$tree_writer"
[[ $interpreter -eq 0 ]] || hook_candidates+="|$interpreter_dir"
matched=$(grep_lines -E -- "$hook_candidates" <<<"$hook_segments")
while IFS= read -r segment; do
  [[ -n $segment ]] || continue
  bare=$(sed -E 's/^[[:space:]]+//' <<<"$segment")
  refused=0
  if check_grep -Eq -- "$hook_file|$hook_vars" <<<"$bare"; then refused=1; fi
  if [[ $refused -eq 0 && $loose_names -eq 1 ]] && check_grep -Eq -- "$loose_name" <<<"$bare"; then refused=1; fi
  if [[ $refused -eq 0 ]] && check_grep -Eq -- "$tree_writer" <<<"$bare"; then
    if [[ $agents_dir_named -eq 1 ]] || check_grep -Eq -- "$home_alone" <<<"$bare" ||
      { [[ $loose_names -eq 1 ]] && check_grep -Eq -- "$loose_dir" <<<"$bare"; }; then
      refused=1
    fi
  fi
  if [[ $refused -eq 0 && $interpreter -eq 1 ]] &&
    check_grep -Eq -- "$hook_dir_alone|$home_alone|$interpreter_dir" <<<"$bare"; then
    refused=1
  fi
  [[ $refused -eq 1 ]] || continue
  # A reader that writes its output into one of these files, or into a name the shell expands, is no reader.
  if reads_only "$bare" 'cat|head|tail|grep|egrep|fgrep|rg|jq|wc|diff|ls|stat|file|realpath|readlink' &&
    ! check_grep -Eq -- ">[[:space:]]*[^[:space:]]*($hook_name|$wild)" <<<"$bare"; then
    continue
  fi
  deny "changing the agents' hook registrations, or switching hooks off, from the shell; change such a file with the Edit tool, which checks that the kit's hooks stay"
done <<<"$matched"

# Everything below applies inside kit repositories, to commands that name an enforced repository or address a
# repository by its numeric id (which hides its name), and to commands that work in a kit repository other than the
# session's directory (git -C <dir>, cd or pushd into it).
works_in_kit_repo() {
  local dir dirs
  # shellcheck disable=SC2016 # backticks are literal regex characters
  dirs=$(grep_lines -oE -- '((^|[;&|(`[:space:]])(cd|pushd)[[:space:]]+|(^|[[:space:]])-C[[:space:]]*)[^[:space:];&|`()]+' <<<"$cmd")
  while IFS= read -r dir; do
    dir=$(sed -E 's/^.*(cd|pushd|-C)[[:space:]]*//' <<<"$dir")
    [[ -n $dir ]] || continue
    # shellcheck disable=SC2088 # a literal ~, as the command spells it
    case $dir in
      "~") dir=$HOME ;;
      "~/"*) dir="$HOME/${dir#"~/"}" ;;
    esac
    [[ $dir == /* ]] || dir="$cwd/$dir"
    ! is_kit_project "$dir" || return 0
  done <<<"$dirs"
  return 1
}
is_kit_project "$cwd" || mentions_registered_repo "$cmd" || matches 'repositories/[0-9]+' || works_in_kit_repo || allow

# A git subcommand, after any of git's own options (git -C dir, git -c key=value, git --no-pager).
git_sub='git([[:space:]]+(-[Cc][[:space:]]*[^[:space:];&|]+|--[a-z-]+(=[^[:space:];&|]*)?|-[a-zA-Z]+))*[[:space:]]+'

# Credentials and token fallbacks.
matches 'security[[:space:]]+(find|dump|export)-' && deny "reading the macOS keychain"
matches "${git_sub}credential" && deny "git credential helper access"
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
# One grep for the case-insensitive ones: every grep is a process the agent waits for.
outside_session="${command_at}tmux[[:space:]]+(-[a-zA-Z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*(new(-session|-window)?|neww|split(-window|w)|send(-keys)?|respawn(-pane|-window)?|run(-shell)?|attach(-session)?)([[:space:]]|\$)"
outside_session+="|${command_at}screen[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*[dmX]"
outside_session+="|${command_at}crontab[[:space:]]+(-[eir]|[^-[:space:];&|])"
outside_session+="|${command_at}launchctl[[:space:]]+(submit|bootstrap|load|asuser|start|kickstart)"
outside_session+="|${command_at}osascript[^;&|]*do[[:space:]]+(shell[[:space:]]+)?script"
outside_session+="|${command_at}open[[:space:]][^;&|]*(-a[[:space:]]*(Terminal|iTerm[0-9]*)([.[:space:]]|\$)|\\.(command|tool|terminal)([[:space:]]|\$))"
if matches "$outside_session" ||
  matches_case "${command_at}ssh([[:space:]]+(-[46AaCfGgKkMNnqsTtVvXxYy]+|-[BbcDEeFIiJLlmOoPpQRSWw][[:space:]]*[^[:space:];&|]+))*[[:space:]]+([^[:space:];&|@]+@)?(localhost|LOCALHOST|127\\.0\\.0\\.1|::1|\\[::1\\])([[:space:];&|:]|\$)"; then
  deny "starting a shell outside this session (it would run with the owner's login, not the session's)"
fi
matches 'pending_deployments|deployment_protection|/environments/' && deny "deployment approval or environment access"
matches '/statuses/' && deny "commit statuses (merge approval is owner-only)"
# Printing the environment: printenv, set, export or declare -x without arguments, env without a command, ps with
# environments (e, -E), and interpreters reading their environment, each as a command.
# shellcheck disable=SC2016 # backticks are literal regex characters
environment_dump="${command_at}(printenv|export([[:space:]]+-p)?|set|(declare|typeset)[[:space:]]+-[a-zA-Z]*[xp][a-zA-Z]*)([[:space:]]*(\$|[;&|)\`]))"
environment_dump+="|${command_at}env([[:space:]]+(-[uCPS][[:space:]]*[^[:space:];&|]+|-[a-zA-Z0-9]+|--[a-z-]+(=[^[:space:];&|]*)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*))*[[:space:]]*(\$|[;&|)\`])"
environment_dump+="|${command_at}(python[0-9.]*|node|deno|bun|perl|ruby|php)[[:space:]].*((^|[^[:alnum:]_])environ([^[:alnum:]_]|\$)|process\\.env|%ENV|ENV\\[)"
if matches "$environment_dump" ||
  matches_case "${command_at}ps[[:space:]]+([AaCcdEfghjLlMmOopSTtUuvwXx]*e[AaCcdEfghjLlMmOopSTtUuvwXx]*([[:space:]]|\$)|([^;&|]*[[:space:]])?-[a-zA-Z]*E)"; then
  deny "dumping the environment (may expose tokens)"
fi
# Git settings that hand git another credential, URL, remote, push target, transport, hook or alias (an alias can run
# a shell and hide a gh call), by git config, git -c or the environment.
git_keys='credential|insteadof|hookspath|sshcommand|askpass|extraheader|include\.|includeif|fsmonitor|url\.|pushurl|remote\.|alias\.|push\.default|branch\.[^.[:space:]]+\.(merge|remote|pushremote)'
# git config writes a key when it gives the key a value, or uses a write option or subcommand (--add, --unset, set,
# unset, ...); --get, --list, -l, get or list before the key, or a key alone, only read it. Prints the keys written.
git_config_writes() {
  grep_lines -oiE -- "${git_sub}config([[:space:]]+[^;&|]*)?" <<<"$cmd" | LC_ALL=C awk '{
    for (i = 1; i <= NF && tolower($i) != "config"; i++) {}
    read = 0; write = 0; key = ""; values = 0
    for (j = i + 1; j <= NF; j++) {
      w = $j
      if (key != "") { values++; continue }
      if (w ~ /^--(get|get-all|get-regexp|get-urlmatch|list)$/ || w == "-l") { read = 1; continue }
      if (w ~ /^--(add|replace-all|unset|unset-all|rename-section|remove-section|edit)$/ || w == "-e") { write = 1; continue }
      if (w ~ /^(--file|-f|--blob|--type|--default|--comment|--value|--fixed-value)$/) { j++; continue }
      if (w ~ /^-/) continue
      if (w ~ /^(get|list|get-color|get-colorbool)$/) { read = 1; continue }
      if (w ~ /^(set|unset|rename-section|remove-section|edit)$/) { write = 1; continue }
      key = w
    }
    if (key != "" && !read && (write || values > 0)) print key
  }'
}
written_keys=$(git_config_writes)
if [[ -n $(grep_lines -Ei -- "$git_keys" <<<"$written_keys") ]]; then
  deny "changing git credential/URL/remote/push/hook/alias configuration"
fi
# git -c <key>=<value> and git --config-env=<key>=<variable> for one command: taken with their case (git -C names a
# directory, git switch -c a branch) and only as an assignment, which a config override always is; the key is
# matched without case, as git reads it.
if matches 'git[[:space:]]'; then
  overrides=$(grep -oE -- '(^|[[:space:]])(-c[[:space:]]*|--config-env[[:space:]=]+)[^[:space:];&|=]+=' <<<"$cmd" || true)
  ! grep -Eiq -- "$git_keys" <<<"$overrides" || deny "overriding git's credential, URL, remote, hook or alias settings for one command"
fi
# The agent's identity reaches git through GIT_CONFIG_* (agent_env_exports): setting, clearing (unset, env -u, read,
# a for loop) or reading these variables changes which credentials git uses or shows them. A command that only reads
# or records text (a commit message, a search, a heredoc written to a file) may mention them.
git_env='GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+|PARAMETERS|GLOBAL|SYSTEM|NOSYSTEM)|GIT_SSH(_COMMAND|_VARIANT)?|GIT_ASKPASS|SSH_ASKPASS|GIT_EXEC_PATH|GIT_TEMPLATE_DIR'
matched=$(grep_lines -E -- "(^|[^[:alnum:]_])($git_env)([^[:alnum:]_]|\$)" <<<"$segments")
while IFS= read -r segment; do
  [[ -n $segment ]] || continue
  reads_only "$segment" "$text_readers" && ! check_grep -Eq -- "\\\$\\{?($git_env)" <<<"$segment" && continue
  deny "changing git's configuration through the environment (GIT_CONFIG_*, GIT_SSH*, GIT_ASKPASS: set, cleared or read)"
done <<<"$matched"

# Git over SSH is refused so pushes go through the same HTTPS credentials as gh.
matches "${git_sub}(push|remote|clone|fetch|pull)[^;&|]*(git@github\\.com|ssh://)" && deny "git over SSH (use the HTTPS remote with the agent token)"

# Direct GitHub API access outside gh.
matches '(curl|wget|http|https|xh)[^;&|]*(api\.github\.com|github\.com/[^[:space:]]*/(settings|reviews|merge))' &&
  deny "calling the GitHub API directly"

# Pushing to the default branch or rewriting remote refs.
if matches "${git_sub}push"; then
  matches "${git_sub}push[^;&|]*([[:space:]:+/](main|master)([[:space:]]|\$|[;&|])|--mirror|--tags|--delete|[[:space:]]-d([[:space:]]|\$)|--all)" &&
    deny "pushing to the default branch, deleting remote refs or pushing tags/all refs"
fi

# A gh call whose flags this guard checks (merge, edit, auth, api) takes them only from its literal text: command
# substitution, backticks or a variable in it could add --admin, --base or a write method the check never sees. One
# pass over the whole command: a per-line loop made a long heredoc outlast the hook's time limit.
if tr ';&|' '\n' <<<"$cmd" | grep -Ei '(^|[^[:alnum:]_])gh[[:space:]]+(pr[[:space:]]+(merge|edit)|auth|api)([[:space:]]|$)' |
  grep -E '[$`]' >/dev/null; then
  deny "command substitution or a variable in a gh merge, edit, auth or api call; write its arguments literally"
fi

# gh: allow-list of subcommands; the rest needs the human. Each call is checked twice: up to the next separator, so
# every flag counts, also one after a parenthesis in a title; and up to the next command substitution or
# redirection, so a call nested in another's arguments ($(gh ...), `gh ...`, <(gh ...)) is a call of its own. gh is
# also found in another case where a command starts (GH runs gh on macOS's file system; prose such as "GH Actions" is
# no call), and flags are matched in every spelling: --base x, --base=x, -Bx.
# shellcheck disable=SC2016 # $ is a literal character of the bracket expression in the extraction below
while IFS= read -r call; do
  [[ -n $call ]] || continue
  read -r _gh group action rest <<<"$call" || true
  [[ $group != *[A-Z]* ]] || group=$(lower "$group")
  [[ ${action:-} != *[A-Z]* ]] || action=$(lower "$action")
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
  grep_lines -oE '(^|[/;&|(`"'"'"'[:space:]])gh[[:space:]]+[a-z-]+([[:space:]]+[^;&|`"'"'"']*)?' <<<"$cmd"
  grep_lines -oE '(^|[/;&|(`"'"'"'[:space:]])gh[[:space:]]+[a-z-]+([[:space:]]+[^;&|`"'"'"'$()<>]*)?' <<<"$cmd"
  grep_lines -oiE '(^|[/;&|(`])[[:space:]]*gh[[:space:]]+[a-z-]+([[:space:]]+[^;&|`"'"'"']*)?' <<<"$cmd"
} | sed -E 's/^[/;&|(`"'"'"'[:space:]]+//; s/^.*\/[gG][hH] /gh /')

allow
