# shellcheck shell=bash
# Shared helpers for the mutants-* adapters and test-mutation. Source it after lib.sh; do not execute it.
#
# Normalized mutation results (.agent/reports/results/mutants.tsv), one line per mutant:
#   <fingerprint>\t<file>:<line>\t<status>\t<description>
# status: killed | timeout | survived | no-coverage | invalid | error
#   killed       a locked test failed (a kill by an unlocked test alone counts as survived)
#   timeout      the run exceeded its time limit (counts as killed)
#   survived     every locked test still passed
#   no-coverage  no locked test reaches the mutated code (counts as survived)
#   invalid      the mutant does not compile or load, or sits inside a kit invariant (listed, not counted)
#   error        the tool reported anything else (ignored, pending, crashed, unknown); fails the gate
# fingerprint: first 16 hex digits of the SHA-256 of the compact JSON array
#   [file, mutator, original text, replacement, trimmed text of the mutated line]
# so it survives unrelated edits that only shift line numbers.

MUTATION_DIR=.agent/reports/mutation
MUTATION_SCOPE=$MUTATION_DIR/scope.txt

# jq definitions shared by the adapters: key($file; $mutator; $original; $replacement; $line) builds
# the fingerprint input; describe builds the description column; slice_text cuts the original text.
# shellcheck disable=SC2016,SC2034 # jq source (expanded by jq, not the shell), used by the adapters
MUTANTS_JQ_LIB='
def flat: tostring | gsub("[\t\r\n]+"; " ") | gsub(" +"; " ") | sub("^ "; "") | sub(" $"; "");
def short: if length > 100 then .[0:97] + "..." else . end;
def key($file; $mutator; $original; $replacement; $line):
  [$file, $mutator, $original, $replacement, ($line | sub("^\\s+"; "") | sub("\\s+$"; ""))] | tojson;
def describe($mutator; $original; $replacement):
  $mutator + ": " + ($original | flat | short) + " -> " + ($replacement | flat | short);
# Text of a location (1-based lines and columns, end column exclusive) in a list of source lines.
def slice_text($lines; $loc):
  if $loc.start.line == $loc.end.line then
    $lines[$loc.start.line - 1][($loc.start.column - 1):($loc.end.column - 1)]
  else
    ([$lines[$loc.start.line - 1][($loc.start.column - 1):]]
      + $lines[$loc.start.line:($loc.end.line - 1)]
      + [$lines[$loc.end.line - 1][:($loc.end.column - 1)]]) | join("\n")
  end;
'

# Reads "<fingerprint input>\t<file:line>\t<status>\t<description>" lines and prints them with the
# input replaced by its fingerprint.
fingerprint_rows() {
  local key rest
  while IFS=$'\t' read -r key rest; do
    printf '%s\t%s\n' "$(printf '%s' "$key" | shasum -a 256 | cut -c1-16)" "$rest"
  done
}

# Prints every locked test ID (all specs/*/tests.lock) as a JSON array.
locked_test_ids_json() {
  local lock
  for lock in specs/*/tests.lock; do
    [[ -f $lock ]] && awk 'NF' "$lock"
  done | jq -R . | jq -cs .
}

# Prints the files of the mutation scope (.agent/reports/mutation/scope.txt) whose names match the
# extended regular expression <pattern>. The scope is computed by the kit, never by the project.
scope_files() {
  local pattern=$1
  [[ -f $MUTATION_SCOPE ]] || die "$MUTATION_SCOPE is missing; it lists the source files to mutate, one per line"
  awk 'NF' "$MUTATION_SCOPE" | grep -E -- "$pattern" || true
}
