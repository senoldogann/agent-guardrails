# shellcheck shell=bash
# Pure functions of the security check (.agent/bin/security-scan). They read scanner reports and the ignore file
# and print findings, so the kit tests them offline. Source it after lib.sh; do not execute it.
#
# A finding is one tab-separated line: <scanner> <ids> <path> <where>
#   scanner  gitleaks, osv or semgrep
#   ids      the rule or advisory IDs, space-separated, the one to show first (osv lists every alias)
#   path     the file, relative to the repository root
#   where    what to show after the ID: the line, the commit or the package
# Text taken from a report (file names, IDs, package names) is made plain first: control characters and
# backticks become "?", so a crafted file name cannot start a new line, a workflow command or a Markdown fence in
# the job summary.

# One line of .github/security-ignore that accepts a finding: "<scanner> <id> <path> # <reason>". The reason is
# required, so the owner reads why when approving. IDs and paths cannot hold spaces or "#".
security_ignore_entry='^(gitleaks|osv|semgrep)[[:space:]]+[^[:space:]#]+[[:space:]]+[^[:space:]#]+[[:space:]]+#[[:space:]]*[^[:space:]]'

# Prints "line <n>: <text>" for every line of the ignore file that is neither blank, a comment nor an entry.
security_ignore_problems() {
  LC_ALL=C awk -v entry="$security_ignore_entry" '
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    $0 !~ entry { line = $0; gsub(/[[:cntrl:]`]/, "?", line); printf "line %d: %s\n", NR, line }' "$1"
}

# Prints "<scanner>\t<id>\t<path>" for every entry of the ignore file.
security_ignore_keys() {
  LC_ALL=C awk -v entry="$security_ignore_entry" '
    { sub(/\r$/, "") }
    $0 ~ entry { printf "%s\t%s\t%s\n", $1, $2, $3 }' "$1"
}

# Reads a gitleaks JSON report on stdin and prints one finding per leak (the secret itself is never read).
gitleaks_findings() {
  jq -r 'def plain: tostring | gsub("[[:cntrl:]`]"; "?");
    .[]? | (.File // "" | plain) as $file
    | ["gitleaks", (.RuleID // "" | plain), $file,
       "\($file):\(.StartLine // 0 | plain) in commit \(.Commit // "" | .[0:7] | plain)"] | join("\t")'
}

# Reads an osv-scanner JSON report on stdin and prints one finding per vulnerability group of a package (OSV
# groups the aliases of one vulnerability). Argument: the absolute path the scan ran on, stripped from the
# lockfile paths.
osv_findings() {
  jq -r --arg root "${1%/}/" 'def plain: tostring | gsub("[[:cntrl:]`]"; "?");
    .results[]? | (.source.path // "" | ltrimstr($root) | plain) as $path
    | .packages[]? | (.package // {}) as $p
    | (.groups // [.vulnerabilities[]? | {ids: [.id], aliases: (.aliases // [])}])[]
    | ((.ids // []) + ((.aliases // []) - (.ids // [])) | map(plain)) as $ids
    | ["osv", ($ids | join(" ")), $path,
       "\($path): \($p.name // "" | plain) \($p.version // "" | plain) (\($p.ecosystem // "" | plain))"
       + (if ($ids | length) > 1 then ", also \($ids[1:] | join(" "))" else "" end)] | join("\t")'
}

# Reads a Semgrep JSON report on stdin and prints its findings, leaving out the rules' own low end: severity INFO
# or LOW, and rules whose authors rate their confidence LOW. A rule without these fields counts.
semgrep_findings() {
  jq -r 'def plain: tostring | gsub("[[:cntrl:]`]"; "?");
    .results[]?
    | select((.extra.severity // "" | ascii_upcase | IN("INFO", "LOW")) | not)
    | select((.extra.metadata.confidence // "" | ascii_upcase) != "LOW")
    | (.path // "" | plain) as $path
    | ["semgrep", (.check_id // "" | plain), $path, "\($path):\(.start.line // 0 | plain)"] | join("\t")'
}

# Reads a Semgrep JSON report on stdin and prints "<type>: <file>" for each error that means a file was not fully
# scanned (a timeout, a file it could not parse, a rule that failed). A finding hidden that way must not pass as
# no finding. Left out: info-level notes (rules that need the Pro engine) and partial parses, where Semgrep
# still scanned the rest of the file.
semgrep_errors() {
  jq -r 'def plain: tostring | gsub("[[:cntrl:]`]"; "?");
    .errors[]? | (.type | if type == "array" then .[0] else . end | plain) as $type
    | select(.level != "info" and $type != "PartialParsing")
    | "\($type): \(.path // .spans[0].file // "no file" | plain)"'
}

# Prints the ignore keys that apply to this PR. osv lines hold while they stay in the file: a package version
# keeps its vulnerabilities. gitleaks and Semgrep report only what is new in the PR, so their lines accept
# findings only in the PR that adds them; a later finding at the same path needs a new decision.
# Arguments: the ignore file, a file with the lines this PR adds to it.
effective_ignore_keys() {
  security_ignore_keys "$1" | awk -F '\t' '$1 == "osv"'
  security_ignore_keys "$2" | awk -F '\t' '$1 != "osv"'
}

# Reads findings on stdin and prints each with a leading "accepted\t" or "open\t": accepted when an ignore key
# (argument, "<scanner>\t<id>\t<path>" lines) names its scanner, its path and one of its IDs exactly.
tag_findings() {
  KEYS=$1 LC_ALL=C awk -F '\t' '
    BEGIN {
      n = split(ENVIRON["KEYS"], lines, "\n")
      for (i = 1; i <= n; i++) if (lines[i] != "") accepted[lines[i]] = 1
    }
    NF < 4 { next }
    {
      tag = "open"
      count = split($2, ids, " ")
      for (i = 1; i <= count; i++) if (($1 "\t" ids[i] "\t" $3) in accepted) tag = "accepted"
      print tag "\t" $0
    }'
}

# Reads findings on stdin and prints those no ignore key accepts. Argument: the ignore keys.
open_findings() {
  tag_findings "$1" | awk '/^open\t/ { sub(/^open\t/, ""); print }'
}

# Reads findings on stdin and prints those an ignore key accepts. Argument: the ignore keys.
accepted_findings() {
  tag_findings "$1" | awk '/^accepted\t/ { sub(/^accepted\t/, ""); print }'
}

# Reads findings on stdin and prints them for people, one per line: "  <scanner> <first id>  <where>".
finding_lines() {
  LC_ALL=C awk -F '\t' 'NF >= 4 { split($2, ids, " "); printf "  %s %s  %s\n", $1, ids[1], $4 }'
}

# Prints the rule files of a semgrep-rules checkout (argument), relative to it: YAML files under a security/
# directory that start with "rules:". Left out: audit/ rules (they flag code for a human to look at, not a
# defect to fix) and the repository's test targets (*.test.yaml, *.fixed.*).
semgrep_rule_files() {
  local dir=$1 file
  (cd "$dir" && find . -type f \( -name '*.yaml' -o -name '*.yml' \) -path '*/security/*' ! -path '*/audit/*' \
    ! -name '*.test.yaml' ! -name '*.test.yml' ! -name '*.fixed.*') | sed 's#^\./##' | LC_ALL=C sort |
    while IFS= read -r file; do
      if awk 'NF && $0 !~ /^[[:space:]]*#/ { found = /^rules:/; exit } END { exit !found }' "$dir/$file"; then
        printf '%s\n' "$file"
      fi
    done
}

# Reads text on stdin and prints it as plain lines (control characters and backticks become "?"): for scanner
# logs, which can quote file names.
plain_lines() {
  LC_ALL=C sed 's/[[:cntrl:]`]/?/g'
}
