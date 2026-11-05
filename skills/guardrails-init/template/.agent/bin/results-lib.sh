# shellcheck shell=bash
# Shared helpers for the results-* adapters. Source it after lib.sh; do not execute it.
#
# Normalized formats (the contract between the language Makefiles and verify-green/verify-red):
#   test IDs     <repo-relative test file>::<name>, nested names (describe blocks, classes, modules,
#                suites) joined with " > ". One per line, sorted, unique.
#   results TSV  <id>\t<status>\t<message>; status is passed|failed|skipped|error; message is one line
#                (the root cause where the runner wraps errors: a "Caused by: " line, or fast-check's
#                "Got <error>" line), empty when passed.

# jq definitions shared by the adapters.
# shellcheck disable=SC2016,SC2034 # jq source (expanded by jq, not the shell), used by the adapters
RESULTS_JQ_LIB='
def strip_ansi: gsub("\u001b\\[[0-9;]*[A-Za-z]"; "");
def one_line:
  (. // "") | tostring | strip_ansi | gsub("\r"; "") | split("\n")
  | map(gsub("\t"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0)) as $lines
  | ([$lines[] | select(startswith("Caused by: ") or startswith("Got ")) | sub("^Caused by: "; "") | sub("^Got "; "")] | last)
    // $lines[0] // "";
def relative($roots): reduce $roots[] as $root (.; ltrimstr($root));
def tsv_line($id; $status; $message): [$id, $status, ($message | one_line)] | join("\t");
'

# Prints the absolute project root spellings (logical and physical, each with a trailing slash)
# as a JSON array, so adapters can relativize absolute paths reported by runners.
project_roots_json() {
  jq -cn --arg logical "$PWD/" --arg physical "$(pwd -P)/" '[$logical, $physical] | unique'
}

# Reads test IDs on stdin and prints them sorted. Fails on an empty list or on duplicate IDs,
# because a duplicate ID cannot be traced to exactly one result.
print_unique_ids() {
  local ids dups
  ids=$(LC_ALL=C sort)
  [[ -n $ids ]] || die "no tests were collected"
  dups=$(uniq -d <<<"$ids")
  [[ -z $dups ]] || die "duplicate test IDs; give every test a unique name:"$'\n'"$dups"
  printf '%s\n' "$ids"
}

# Fails unless the runner report file exists and is non-empty.
require_report() {
  local report=$1
  [[ -s $report ]] || die "runner report $report is missing or empty; the test process did not finish its report"
}
