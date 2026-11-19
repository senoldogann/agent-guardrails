# shellcheck shell=bash
# Read lock metadata from Git objects, not the worktree being judged.

lock_manifest_paths() {
  local ref=$1 lock=$2 body line path seen=""
  local pattern='^[0-9a-f]{64}  (.+)$'
  body=$(git cat-file blob "$ref:$lock") || return 1
  [[ -n $body ]] || return 1
  while IFS= read -r line; do
    [[ $line =~ $pattern ]] || return 1
    path=${BASH_REMATCH[1]}
    case "/$path/" in
      *//* | */./* | */../* | *[[:cntrl:]\`\\]*) return 1 ;;
    esac
    if grep -Fx -- "$path" <<<"$seen" >/dev/null; then return 1; fi
    seen+="$path"$'\n'
  done <<<"$body"
  printf '%s' "$seen"
}

# The caller also runs guard_locks to verify the checksums; this checks the contract's structure.
guard_lock_manifests() {
  local base=$1 head=$2 old_tree new_tree lock dir manifest old_manifest declared path test_ids
  old_tree=$(git ls-tree -r --name-only "$base" -- specs) || die "cannot enumerate base spec locks"
  new_tree=$(git ls-tree -r --name-only "$head" -- specs) || die "cannot enumerate head spec locks"
  while IFS= read -r lock; do
    [[ $lock =~ ^specs/[A-Za-z][A-Za-z0-9]*-[0-9]+/spec\.lock$ ]] || continue
    dir=${lock%/*}
    if ! manifest=$(lock_manifest_paths "$head" "$lock"); then
      fail "missing or invalid spec lock: $lock"
      continue
    fi
    if ! declared=$(git cat-file blob "$head:$dir/locked-files" | list_entries) || [[ -z $declared ]]; then
      fail "missing or empty locked-files: $dir/locked-files"
      continue
    fi
    if ! test_ids=$(git cat-file blob "$head:$dir/tests.lock") || [[ -z $test_ids ]]; then
      fail "missing or empty tests.lock: $dir/tests.lock"
    fi
    while IFS= read -r path; do
      if ! grep -Fx -- "$path" <<<"$manifest" >/dev/null; then
        fail "incomplete spec lock: $lock is missing $path"
      fi
    done < <(printf '%s\n' "$dir/locked-files" "$dir/write-allow" "$dir/acceptance-criteria.md" "$dir/OPEN_QUESTIONS.md" "$dir/tests.lock" "$declared")
    if grep -Fx -- "$lock" <<<"$old_tree" >/dev/null; then
      if ! old_manifest=$(lock_manifest_paths "$base" "$lock"); then
        fail "invalid base spec lock: $lock"
        continue
      fi
      while IFS= read -r path; do
        if ! grep -Fx -- "$path" <<<"$manifest" >/dev/null; then
          fail "spec lock scope reduced: $lock no longer covers $path"
        fi
      done <<<"$old_manifest"
    fi
  done < <(printf '%s\n%s\n' "$old_tree" "$new_tree" | LC_ALL=C sort -u)
  return 0
}
