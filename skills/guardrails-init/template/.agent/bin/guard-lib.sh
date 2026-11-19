# shellcheck shell=bash
# The checks ci-guard (one PR) and ci-guard-group (a merge queue's group commit) share. Source it after lib.sh;
# do not execute it. Both run from the DEFAULT branch checkout and only read the commits they judge through git,
# so the changes they judge cannot weaken them. A failed check prints a FAIL line and sets guard_status to 1.
# Pattern syntax in write-allow: bash glob, where "*" also matches "/".

# shellcheck disable=SC2034 # read by the scripts that source this file
guard_status=0
# Paths changed between the judged base and head, one per line (set by guard_changed_files).
changed=""
# "  <lock> no longer locks "<path>"" and "  <lock> now also locks "<path>"" lines, paths quoted by quoted_path (set
# by guard_lock_manifests).
lock_scope_changes=""

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
  local head=$1 path=$2 shown problems problem
  shift 2
  # Unchanged files never passed guard_changed_files' name check, so drop control characters before printing.
  shown=$(LC_ALL=C tr -d '\000-\037\177' <<<"$path")
  if ! problems=$(git show "$head:$path" | python3 -I -S -B "$workflow_checker" "$@"); then
    fail "workflow $shown could not be checked: $workflow_checker needs python3 3.8 or newer"
    return 0
  fi
  while IFS= read -r problem; do
    [[ -z $problem ]] || fail "workflow $shown $problem"
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
  # NUL-separated: without -z git quotes names with non-ASCII or special characters, which would then not
  # look like workflow paths and escape the check.
  while IFS= read -r -d '' path; do
    is_workflow_path "$path" || continue
    guard_workflow_check "$head" "$path" token-problems
  done < <(git ls-tree -r -z --name-only "$head" -- .github/workflows)
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
  [[ $(git cat-file -t "$head:specs/$ticket/spec.lock" 2>/dev/null) == blob ]] ||
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

# Prints the ticket spec locks (specs/<dir>/spec.lock) of a commit, one per line. Argument: commit.
ticket_locks() {
  local path
  while IFS= read -r -d '' path; do
    [[ $path == specs/*/spec.lock && $path != specs/*/*/spec.lock ]] && printf '%s\n' "$path"
  done < <(git ls-tree -r -z --name-only "$1" -- specs)
  return 0
}

# Every ticket's spec lock on head must be exactly what spec-lock writes for head's locked-files (lib.sh:
# locked_files_problems, manifest_problems): a manifest that leaves a locked test out keeps valid checksums for the
# rest, so guard_locks alone would pass it. A lock on the base may not disappear. A lock that covers other files
# than on the base is an amendment: it passes, and guard_review_summary lists every file it stopped or started
# locking, so the owner approves the change of scope knowingly. Fills `lock_scope_changes`.
# Arguments: base commit, head commit.
guard_lock_manifests() {
  local base=$1 head=$2 lock dir problems problem expected base_paths head_paths path
  lock_scope_changes=""
  while IFS= read -r lock; do
    [[ -n $lock ]] || continue
    dir=${lock%/spec.lock}
    if [[ ! ${dir#specs/} =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]]; then
      fail "spec lock $lock is not in a ticket directory (specs/<TICKET>, e.g. specs/ABC-123)"
      continue
    fi
    if [[ $(git cat-file -t "$head:$dir/locked-files" 2>/dev/null) != blob ]]; then
      fail "spec lock $lock has no $dir/locked-files to check it against"
      continue
    fi
    problems=$(git show "$head:$dir/locked-files" | locked_files_problems "$dir")
    if [[ -z $problems ]]; then
      expected=$(spec_lock_metadata "$dir"; git show "$head:$dir/locked-files" | entry_lines)
      problems=$(git show "$head:$lock" | manifest_problems "$lock" "$dir" "$expected")
    fi
    while IFS= read -r problem; do
      [[ -z $problem ]] || fail "$problem"
    done <<<"$problems"
  done < <(ticket_locks "$head")

  while IFS= read -r lock; do
    [[ -n $lock ]] || continue
    # A directory of the same name would hide the lock from every check that looks for spec.lock files.
    if [[ $(git cat-file -t "$head:$lock" 2>/dev/null) != blob ]]; then
      fail "spec lock $lock is on the base and missing at the head; a locked spec may change only by re-locking it"
      continue
    fi
    base_paths=$(git show "$base:$lock" | manifest_paths)
    head_paths=$(git show "$head:$lock" | manifest_paths)
    while IFS= read -r path; do
      if [[ -n $path ]] && ! grep -Fx -- "$path" <<<"$head_paths" >/dev/null; then
        lock_scope_changes+="  $lock no longer locks $(quoted_path "$path")"$'\n'
      fi
    done <<<"$base_paths"
    while IFS= read -r path; do
      if [[ -n $path ]] && ! grep -Fx -- "$path" <<<"$base_paths" >/dev/null; then
        lock_scope_changes+="  $lock now also locks $(quoted_path "$path")"$'\n'
      fi
    done <<<"$head_paths"
  done < <(ticket_locks "$base")
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
        fail "lock mismatch: $lock records $(printable "$path"), head has a different or missing file"
      fi
    done < <(git show "$head:$lock")
  done < <(git ls-tree -r --name-only "$head" -- specs | awk '/\/spec\.lock$/')
}

# What the owner reviews: accepted mutants and security findings, spec lock scope changes, changed workflows and
# human-owned paths.
# Arguments: base commit, head commit.
guard_review_summary() {
  local base=$1 head=$2 accepted_added ignored_added workflows owned="" path
  # Lines the PR adds to a ticket's mutants-accepted, each one accepting a surviving mutant. Like the security-ignore
  # lines below, control characters and backticks are dropped, so a reason cannot break out of the summary's fence.
  accepted_added=$(git diff "$base" "$head" -- 'specs/*/mutants-accepted' | awk '/^\+[^+]/ { print "  " substr($0, 2) }' |
    LC_ALL=C tr -d '\000-\010\013-\037\140\177')
  [[ -z $accepted_added ]] || printf 'MUTANTS ACCEPTED AS EQUIVALENT (owner decision; check each reason):\n%s\n' "$accepted_added"
  # Lines the PR adds to the ignore file of the security job: each one accepts a finding. Control characters and
  # backticks are dropped, so a line cannot break out of the summary's fence.
  ignored_added=$(git diff "$base" "$head" -- .github/security-ignore | awk '/^\+[^+]/ { print "  " substr($0, 2) }' |
    LC_ALL=C tr -d '\000-\010\013-\037\140\177')
  [[ -z $ignored_added ]] || printf 'SECURITY FINDINGS ACCEPTED (owner decision; check each reason):\n%s\n' "$ignored_added"
  # Locked files a re-lock stopped or started locking: an amendment that drops a locked test passes the guard, so
  # the owner must see each one.
  [[ -z $lock_scope_changes ]] ||
    printf 'SPEC LOCK SCOPE CHANGED against the base (owner decision; check each file):\n%s' "$(printable "$lock_scope_changes")"$'\n'
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
