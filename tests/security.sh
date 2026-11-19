#!/usr/bin/env bash
# Offline tests for the security check's pure functions (template/.agent/bin/security-lib.sh): reading scanner
# reports, the ignore file and the rule selection. The scanners themselves run in the security job on GitHub.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$kit/skills/guardrails-init/template/.agent/bin/security-lib.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf '  FAIL %s\n' "$1"
}
expect_eq() {
  if [[ $2 == "$3" ]]; then ok; else fail "$1: want [$3] got [$2]"; fi
}
tab=$'\t'

echo "gitleaks_findings"
# Reports are written with --redact; the secret is never part of a finding either way.
gitleaks_report='[
 {"RuleID":"github-pat","File":"src/config.py","StartLine":3,"Commit":"5a785669987b25bd51fab87469fefbec2757e008",
  "Secret":"REDACTED","Match":"REDACTED"},
 {"RuleID":"generic-api-key","File":"docs/a\nFAIL: fake`x.md","StartLine":1,"Commit":"abc"}]'
expect_eq "one finding per leak, file names made plain" "$(gitleaks_findings <<<"$gitleaks_report")" \
  "gitleaks${tab}github-pat${tab}src/config.py${tab}src/config.py:3 in commit 5a78566
gitleaks${tab}generic-api-key${tab}docs/a?FAIL: fake?x.md${tab}docs/a?FAIL: fake?x.md:1 in commit abc"
expect_eq "an empty report has no findings" "$(gitleaks_findings <<<'[]')" ""

echo "osv_findings"
osv_report='{"results":[{"source":{"path":"/repo/sub/uv.lock","type":"lockfile"},"packages":[
 {"package":{"name":"jinja2","version":"2.4.1","ecosystem":"PyPI"},
  "vulnerabilities":[{"id":"PYSEC-2014-8"},{"id":"GHSA-8r7q-cvjq-x353"}],
  "groups":[{"ids":["PYSEC-2014-8","GHSA-8r7q-cvjq-x353"],"aliases":["CVE-2014-1402","GHSA-8r7q-cvjq-x353","PYSEC-2014-8"]}]},
 {"package":{"name":"left","version":"1.0.0","ecosystem":"npm"},
  "vulnerabilities":[{"id":"GHSA-aaaa-bbbb-cccc","aliases":["CVE-2026-1"]}]}]}]}'
expect_eq "one finding per vulnerability group, every alias an ID, paths relative to the root" \
  "$(osv_findings /repo <<<"$osv_report")" \
  "osv${tab}PYSEC-2014-8 GHSA-8r7q-cvjq-x353 CVE-2014-1402${tab}sub/uv.lock${tab}sub/uv.lock: jinja2 2.4.1 (PyPI), also GHSA-8r7q-cvjq-x353 CVE-2014-1402
osv${tab}GHSA-aaaa-bbbb-cccc CVE-2026-1${tab}sub/uv.lock${tab}sub/uv.lock: left 1.0.0 (npm), also CVE-2026-1"
expect_eq "no lockfiles, no findings" "$(osv_findings /repo <<<'{"results":[]}')" ""

echo "semgrep_findings"
semgrep_report='{"results":[
 {"check_id":"insecure-hash-algorithm-md5","path":"src/b.py","start":{"line":7},"extra":{"severity":"WARNING","metadata":{"confidence":"MEDIUM"}}},
 {"check_id":"tainted-sql","path":"src/db.py","start":{"line":2},"extra":{"severity":"ERROR","metadata":{}}},
 {"check_id":"noisy","path":"src/c.py","start":{"line":1},"extra":{"severity":"WARNING","metadata":{"confidence":"LOW"}}},
 {"check_id":"note","path":"src/d.py","start":{"line":1},"extra":{"severity":"INFO","metadata":{"confidence":"HIGH"}}}],
 "errors":[]}'
expect_eq "findings at WARNING or above with a confidence above LOW; no confidence counts" \
  "$(semgrep_findings <<<"$semgrep_report")" \
  "semgrep${tab}insecure-hash-algorithm-md5${tab}src/b.py${tab}src/b.py:7
semgrep${tab}tainted-sql${tab}src/db.py${tab}src/db.py:2"

echo "ignore file"
printf '%s\n' '# Findings the owner accepted.' '' \
  'osv CVE-2014-1402 sub/uv.lock # only used by a build script, never served' \
  'semgrep  insecure-hash-algorithm-md5	src/b.py   #  checksum of a cache key, not security' \
  'semgrep tainted-sql src/db.py' 'gitleaks github-pat # no path' 'trivy CVE-1 a # unknown scanner' \
  $'semgrep x src/e.py # windows line ending\r' 'semgrep a`b src/f.py # ok' >"$work/ignore"
expect_eq "lines without a reason, a path or a known scanner are problems" "$(security_ignore_problems "$work/ignore")" \
  "line 5: semgrep tainted-sql src/db.py
line 6: gitleaks github-pat # no path
line 7: trivy CVE-1 a # unknown scanner"
keys=$(security_ignore_keys "$work/ignore")
expect_eq "entries become keys" "$keys" "osv${tab}CVE-2014-1402${tab}sub/uv.lock
semgrep${tab}insecure-hash-algorithm-md5${tab}src/b.py
semgrep${tab}x${tab}src/e.py
semgrep${tab}a\`b${tab}src/f.py"

echo "open and accepted findings"
findings="$(osv_findings /repo <<<"$osv_report")
$(semgrep_findings <<<"$semgrep_report")
$(gitleaks_findings <<<"$gitleaks_report")
"
expect_eq "a key accepts its scanner, one of the IDs (an alias too) and the exact path" \
  "$(accepted_findings "$keys" <<<"$findings" | cut -f1,3)" "osv${tab}sub/uv.lock
semgrep${tab}src/b.py"
expect_eq "the rest stays open" "$(open_findings "$keys" <<<"$findings" | cut -f1,3)" "osv${tab}sub/uv.lock
semgrep${tab}src/db.py
gitleaks${tab}src/config.py
gitleaks${tab}docs/a?FAIL: fake?x.md"
expect_eq "no keys accept nothing" "$(accepted_findings "" <<<"$findings")" ""
other_path=$(printf 'semgrep\tinsecure-hash-algorithm-md5\tsrc/b.py.bak\tsrc/b.py.bak:1\n')
expect_eq "the path must match exactly" "$(open_findings "$keys" <<<"$other_path" | cut -f3)" "src/b.py.bak"
expect_eq "findings for people" "$(finding_lines <<<"$(open_findings "$keys" <<<"$findings")")" \
  "  osv GHSA-aaaa-bbbb-cccc  sub/uv.lock: left 1.0.0 (npm), also CVE-2026-1
  semgrep tainted-sql  src/db.py:2
  gitleaks github-pat  src/config.py:3 in commit 5a78566
  gitleaks generic-api-key  docs/a?FAIL: fake?x.md:1 in commit abc"

echo "semgrep_errors"
semgrep_errors_report='{"results":[],"errors":[
 {"type":"Missing plugin","level":"info","path":"/tmp/rules.json"},
 {"type":["PartialParsing",[{"path":"src/a.sh"}]],"level":"warn","spans":[{"file":"src/a.sh"}]},
 {"type":"Timeout","level":"warn","path":"src/big\u001b.py"},
 {"type":"Syntax error","level":"error","spans":[{"file":"src/broken.py"}]}]}'
expect_eq "timeouts and unparsable files are errors; Pro-only rules and partial parses are not" \
  "$(semgrep_errors <<<"$semgrep_errors_report")" "Timeout: src/big?.py
Syntax error: src/broken.py"

echo "effective_ignore_keys"
printf '%s\n' 'osv GHSA-1 uv.lock # pinned by the vendor' 'semgrep md5 src/a.py # old decision' \
  'gitleaks generic-api-key tests/fixture.json # old decision' >"$work/ignore-all"
printf '%s\n' 'semgrep md5 src/b.py # decided in this PR' 'osv GHSA-2 uv.lock # decided in this PR' >"$work/ignore-added"
cat "$work/ignore-added" >>"$work/ignore-all"
expect_eq "osv lines hold while in the file; gitleaks and semgrep lines only in the PR that adds them" \
  "$(effective_ignore_keys "$work/ignore-all" "$work/ignore-added")" "osv${tab}GHSA-1${tab}uv.lock
osv${tab}GHSA-2${tab}uv.lock
semgrep${tab}md5${tab}src/b.py"

echo "plain_lines"
expect_eq "control characters and backticks become ?" "$(printf 'a\tb`c\033[31m\n::stop-commands::x\n' | plain_lines)" \
  "a?b?c?[31m
::stop-commands::x"

echo "semgrep_rule_files"
rules="$work/rules"
mkdir -p "$rules/python/lang/security/audit" "$rules/python/lang/correctness" "$rules/yaml/k8s/security" "$rules/.github"
printf 'rules:\n  - id: a\n' >"$rules/python/lang/security/a.yaml"
printf '# header\n\nrules:\n  - id: b\n' >"$rules/python/lang/security/b.yml"
printf 'rules:\n  - id: c\n' >"$rules/python/lang/security/audit/c.yaml"
printf 'rules:\n  - id: d\n' >"$rules/python/lang/correctness/d.yaml"
printf 'apiVersion: v1\n' >"$rules/yaml/k8s/security/pod.test.yaml"
printf 'apiVersion: v1\n' >"$rules/yaml/k8s/security/pod.fixed.test.yml"
printf 'apiVersion: v1\n' >"$rules/yaml/k8s/security/target.yaml"
printf 'rules:\n' >"$rules/yaml/k8s/security/pod.yaml"
printf 'x = 1\n' >"$rules/python/lang/security/a.py"
expect_eq "security rules outside audit/, without test targets" "$(semgrep_rule_files "$rules")" \
  "python/lang/security/a.yaml
python/lang/security/b.yml
yaml/k8s/security/pod.yaml"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
