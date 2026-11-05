# shellcheck shell=bash
# Shared by bin/guardrails and its tests. Source it after lib.sh; do not execute it.
# Functions that only read or change a local checkout are kept free of GitHub calls so tests can run offline.

# shellcheck disable=SC2154 # kit is set by the sourcing script
template="$kit/skills/guardrails-init/template"

# Prints every way the kit-owned files of a checkout differ from the installed kit's template, one per line.
# Nothing printed means the checkout carries exactly this kit: .agent/, .claude/settings.json, the guard
# workflow and each checks-<lang> workflow. The Makefile and AGENTS.md hold project judgment and are not compared.
kit_drift() {
  local dir=$1 workflow name
  [[ -d "$dir/.agent" ]] || {
    printf 'missing: .agent/\n'
    return 0
  }
  diff -rq "$template/.agent" "$dir/.agent" | sed -E \
    -e "s#^Files $template/(.*) and .* differ\$#differs from the kit: \\1#" \
    -e "s#^Only in $template/(.*): (.*)\$#missing: \\1/\\2#" \
    -e "s#^Only in $dir/(.*): (.*)\$#not in the kit: \\1/\\2#" || true
  cmp -s "$template/.claude/settings.json" "$dir/.claude/settings.json" ||
    printf 'differs or missing: .claude/settings.json\n'
  cmp -s "$template/.github/workflows/agent-guard.yml" "$dir/.github/workflows/agent-guard.yml" ||
    printf 'differs or missing: .github/workflows/agent-guard.yml\n'
  local found=0
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    found=1
    name=${workflow##*/}
    cmp -s "$template/ci/$name" "$workflow" || printf 'differs from the kit: .github/workflows/%s\n' "$name"
  done
  [[ $found -eq 1 ]] || printf 'missing: .github/workflows/checks-<lang>.yml\n'
}

# Prints the checks-<lang> job names a checkout's workflows define (the ruleset requires each one).
check_jobs() {
  local dir=$1 workflow
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    sed -nE 's/^  (checks-[a-z]+):$/\1/p' "$workflow"
  done | sort -u
}

# Removes the kit from a checkout, leaving it as before the kit was installed. Prints one line per file
# it kept on purpose or could only partly undo, so the owner can review them in the removal PR.
# Kept: specs/ (the team's record of decided requirements), dev dependencies, .gitignore entries.
remove_kit_files() {
  local dir=$1 workflow name makefile lang
  rm -rf "$dir/.agent"
  rm -f "$dir/.github/workflows/agent-guard.yml"
  for workflow in "$dir"/.github/workflows/checks-*.yml; do
    [[ -e $workflow ]] || continue
    name=${workflow##*/}
    if cmp -s "$template/ci/$name" "$workflow"; then
      rm -f "$workflow"
    else
      printf 'kept (differs from the kit, review it): .github/workflows/%s\n' "$name"
    fi
  done
  if [[ -f "$dir/.claude/settings.json" ]]; then
    if cmp -s "$template/.claude/settings.json" "$dir/.claude/settings.json"; then
      rm -f "$dir/.claude/settings.json"
      rmdir "$dir/.claude" 2>/dev/null || true
    else
      printf 'kept (differs from the kit, remove the kit hooks by hand): .claude/settings.json\n'
    fi
  fi
  makefile="$dir/Makefile"
  if [[ -f $makefile ]] && grep -F 'include .agent/common.mk' "$makefile" >/dev/null; then
    for lang in typescript javascript python rust swift; do
      if cmp -s "$template/makefiles/Makefile.$lang" "$makefile"; then
        rm -f "$makefile"
        break
      fi
    done
    if [[ -f $makefile ]]; then
      grep -vF 'include .agent/common.mk' "$makefile" >"$makefile.tmp"
      mv "$makefile.tmp" "$makefile"
      printf 'edited (kit include removed; targets that called .agent/ scripts need a look): Makefile\n'
    fi
  fi
  [[ -f "$dir/AGENTS.md" ]] && remove_agents_section "$dir/AGENTS.md"
  [[ -d "$dir/specs" ]] && printf 'kept (decided requirements stay as documentation): specs/\n'
  return 0
}

# Removes the kit's section from AGENTS.md: between the agent-guardrails start/end markers, or, for
# installations made before the markers existed, from "## Agent guardrails" to the next "## " heading.
remove_agents_section() {
  local file=$1
  if grep -F '<!-- agent-guardrails:start -->' "$file" >/dev/null; then
    awk '/<!-- agent-guardrails:start -->/ {skip = 1} !skip {print} /<!-- agent-guardrails:end -->/ {skip = 0}' "$file" >"$file.tmp"
  else
    awk '/^## Agent guardrails[[:space:]]*$/ {skip = 1; next} skip && /^## / {skip = 0} !skip {print}' "$file" >"$file.tmp"
  fi
  # Squeeze the blank lines the removed section leaves behind and drop trailing ones.
  cat -s "$file.tmp" | awk '{lines[NR] = $0} NF {last = NR} END {for (i = 1; i <= last; i++) print lines[i]}' >"$file"
  rm -f "$file.tmp"
}

# Reads `gh pr list --json number,title,url,isDraft,headRefOid,labels,statusCheckRollup` on stdin and
# prints one tab-separated line per PR that needs the owner: "<kind>\t<url>\t<title>\t<note>".
# Kinds: answer (the agent asked a question: label needs-decision), approve (guard passed, HEAD not
# approved yet). Drafts without a question are the agent's work in progress and are skipped, as are
# PRs whose HEAD is already approved.
classify_prs() {
  jq -r '
    def latest(f): [.statusCheckRollup[]? | select(f)] | sort_by(.startedAt // .createdAt // "") | last;
    .[]
    | (latest(.__typename == "CheckRun" and .name == "guard")) as $guard
    | (latest(.__typename == "StatusContext" and .context == "merge-approval")) as $approval
    | ([.statusCheckRollup[]? | select(.__typename == "CheckRun" and (.name | startswith("checks-")))]) as $checks
    | (if ($checks | length) == 0 then "checks not started"
       elif any($checks[]; .status != "COMPLETED") then "checks running"
       elif all($checks[]; .conclusion == "SUCCESS") then "checks green"
       else "checks failing" end) as $checks_note
    | if any(.labels[]?; .name == "needs-decision") then ["answer", .url, .title, "the agent is waiting for your decision"]
      elif .isDraft then empty
      elif ($approval.state // "") == "SUCCESS" then empty
      elif $guard == null or $guard.status != "COMPLETED" then ["wait", .url, .title, "guard is running"]
      elif $guard.conclusion != "SUCCESS" then ["blocked", .url, .title, "guard failed: the agent has to fix the PR"]
      else ["approve", .url, .title, $checks_note] end
    | @tsv'
}
