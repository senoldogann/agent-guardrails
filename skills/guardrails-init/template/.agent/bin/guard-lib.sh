# shellcheck shell=bash
# The checks ci-guard (one PR) and ci-guard-group (a merge queue's group commit) share. Source it after lib.sh;
# do not execute it. Both run from the DEFAULT branch checkout and only read the commits they judge through git,
# so the changes they judge cannot weaken them. A failed check prints a FAIL line and sets guard_status to 1.
# Pattern syntax in write-allow: bash glob, where "*" also matches "/".

# shellcheck disable=SC2034 # read by the scripts that source this file
guard_status=0
# Paths changed between the judged base and head, one per line (set by guard_changed_files).
changed=""

fail() {
  printf 'FAIL: %s\n' "$1"
  guard_status=1
}

# History stays linear: squash merges only, so a merge commit in the range is a mistake or a trick.
# Arguments: base commit, head commit.
guard_no_merges() {
  local merges
  merges=$(git rev-list --merges "$1..$2")
  [[ -z $merges ]] || fail "merge commits in PR (rebase instead): $(tr '\n' ' ' <<<"$merges")"
}

# Checks every changed entry's name and mode and fills `changed`. Arguments: base commit, head commit.
guard_changed_files() {
  local meta path new_mode
  changed=""
  # Changed entries with modes: ":<old-mode> <new-mode> <old-sha> <new-sha> <status>\t<path>", NUL separated.
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    new_mode=$(cut -d' ' -f2 <<<"$meta")
    # Names are written by the agent and end up in this output, the step summary and the owner's review: a
    # newline, an escape sequence or a backtick (a Markdown fence) could forge lines there.
    if [[ $path == *[[:cntrl:]\`]* ]]; then
      fail "file name with a control character or backtick not allowed: $(LC_ALL=C tr -d '\000-\037\177' <<<"$path")"
      continue
    fi
    case $new_mode in
      000000 | 100644 | 100755) ;;
      120000) fail "symlink not allowed: $path" ;;
      160000) fail "submodule not allowed: $path" ;;
      *) fail "unsupported file mode $new_mode: $path" ;;
    esac
    case "/$path/" in
      */node_modules/* | */__pycache__/* | */site-packages/* | */vendor/* | */.build/* | */target/*)
        fail "dependency/build directory content not allowed: $path"
        ;;
    esac
    changed+="$path"$'\n'
  done < <(git diff --raw -z --no-renames "$1" "$2")
}

# A PR's own workflows run on the PR (pull_request, push) and their jobs report check runs under the same
# GitHub Actions app as the real checks, so a job named like a required check, or a token allowed to write
# checks or statuses, could stand in for the owner's approval. Changed workflow files therefore may not
# request any write permission, name the required checks outside their own file (guard, security,
# checks-<lang>, merge-approval) or compute a job name, and the guard workflow may not change its triggers.
# Unchanged workflows may not write checks or statuses either, because pull_request runs execute the PR's code
# with their token. ../workflow/check.py reads each file with a real YAML parser, as data, and fails closed on
# YAML it does not accept; the owner's approval runs the same file from the kit install.
workflow_checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/../workflow" && pwd -P)/check.py"

# Succeeds for a path GitHub may load as a workflow. The extension is compared case-insensitively, so no file
# GitHub might read is skipped. Argument: path.
is_workflow_path() {
  case $(tr '[:upper:]' '[:lower:]' <<<"$1") in
    .github/workflows/*.yml | .github/workflows/*.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

# Fails each problem check.py reports for one workflow of head, or the workflow when check.py cannot run.
# Arguments: head commit, path, check.py arguments.
guard_workflow_check() {
  local head=$1 path=$2 problems problem
  shift 2
  if ! problems=$(git show "$head:$path" | python3 -I -S -B "$workflow_checker" "$@"); then
    fail "workflow $path could not be checked: $workflow_checker needs python3 3.8 or newer"
    return 0
  fi
  while IFS= read -r problem; do
    [[ -z $problem ]] || fail "workflow $path $problem"
  done <<<"$problems"
}

# Judges the changed workflow files and every workflow of head. Argument: head commit.
guard_workflows() {
  local head=$1 path
  while IFS= read -r path; do
    is_workflow_path "$path" || continue
    git cat-file -e "$head:$path" 2>/dev/null || continue
    guard_workflow_check "$head" "$path" changed-problems "$path"
  done <<<"$changed"
  while IFS= read -r path; do
    is_workflow_path "$path" || continue
    guard_workflow_check "$head" "$path" token-problems
  done < <(git ls-tree -r --name-only "$head" -- .github/workflows)
}

# Prints the tickets whose specs/<TICKET>/ the changes touch, one per line.
guard_touched_tickets() {
  awk -F/ '$1 == "specs" && NF >= 3 { print $2 }' <<<"$changed" | sort -u
}

# A touched ticket must have a valid id and a locked spec, and its write-allow may not reach human-owned paths.
# Arguments: ticket, head commit.
guard_ticket_spec() {
  local ticket=$1 head=$2 allow_file tracked pattern path
  [[ $ticket =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || fail "invalid ticket id '$ticket' (expected e.g. ABC-123)"
  git cat-file -e "$head:specs/$ticket/spec.lock" 2>/dev/null ||
    fail "spec for $ticket is not locked yet (draft); answer its questions and run spec-lock before merging"
  allow_file="specs/$ticket/write-allow"
  if git cat-file -e "$head:$allow_file" 2>/dev/null; then
    tracked=$(git ls-tree -r --name-only "$head")
    while IFS= read -r pattern; do
      [[ -n $pattern && $pattern != \#* ]] || continue
      while IFS= read -r path; do
        if is_human_owned "$path"; then
          # shellcheck disable=SC2053 # glob match against a write-allow pattern is intended
          [[ $path != $pattern ]] || fail "write-allow pattern '$pattern' reaches human-owned path '$path'"
        fi
      done <<<"$tracked"
    done < <(git show "$head:$allow_file")
  fi
}

# Every lock on head must match head's files. Argument: head commit.
guard_locks() {
  local head=$1 lock line expected path actual
  while IFS= read -r lock; do
    [[ -n $lock ]] || continue
    while IFS= read -r line; do
      expected=${line%% *}
      path=${line#*  }
      if ! actual=$(git show "$head:$path" 2>/dev/null | shasum -a 256 | cut -d' ' -f1) || [[ $actual != "$expected" ]]; then
        fail "lock mismatch: $lock records $path, head has a different or missing file"
      fi
    done < <(git show "$head:$lock")
  done < <(git ls-tree -r --name-only "$head" -- specs | awk '/\/spec\.lock$/')
}

# What the owner reviews: accepted mutants and security findings, changed workflows and human-owned paths.
# Arguments: base commit, head commit.
guard_review_summary() {
  local base=$1 head=$2 accepted_added ignored_added workflows owned="" path
  accepted_added=$(git diff "$base" "$head" -- 'specs/*/mutants-accepted' | awk '/^\+[^+]/ { print "  " substr($0, 2) }')
  [[ -z $accepted_added ]] || printf 'MUTANTS ACCEPTED AS EQUIVALENT (owner decision; check each reason):\n%s\n' "$accepted_added"
  # Lines the PR adds to the ignore file of the security job: each one accepts a finding. Control characters and
  # backticks are dropped, so a line cannot break out of the summary's fence.
  ignored_added=$(git diff "$base" "$head" -- .github/security-ignore | awk '/^\+[^+]/ { print "  " substr($0, 2) }' |
    LC_ALL=C tr -d '\000-\010\013-\037\140\177')
  [[ -z $ignored_added ]] || printf 'SECURITY FINDINGS ACCEPTED (owner decision; check each reason):\n%s\n' "$ignored_added"
  workflows=$(grep -E '^\.github/(workflows|actions)/' <<<"$changed" || true)
  [[ -z $workflows ]] || printf 'WORKFLOW FILES CHANGED (could add fake required checks; review line by line):\n%s\n' "$workflows"
  while IFS= read -r path; do
    if [[ -n $path ]] && is_human_owned "$path"; then
      owned+="  $path"$'\n'
    fi
  done <<<"$changed"
  if [[ -n $owned ]]; then
    printf 'human-owned paths changed (review these closely):\n%s' "$owned"
  else
    printf 'no human-owned paths changed\n'
  fi
}
