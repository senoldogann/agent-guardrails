#!/usr/bin/env bash
# Offline end-to-end tests for `guardrails off <owner/repo>`: a fake gh answers from fixtures and logs every write,
# git clones and pushes the project through a local bare repository (url.insteadOf), and tests/pty-run.py types the
# owner's answer in a pseudo-terminal. The removal plan is prepared before the confirmation, from a clone of a
# repository the agent writes to: preparing it must not read or change anything outside that clone, whatever symbolic
# links the repository holds, so a cancelled `off` changes nothing. A confirmed `off` pushes exactly the planned
# removal and merges that commit.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf '  FAIL %s\n' "$1"
  sed 's/^/       /' "$work/out"
}
expect_out() {
  if grep -F -- "$2" "$work/out" >/dev/null; then ok; else fail "$1 (output lacks: $2)"; fi
}
expect_eq() {
  if [[ $2 == "$3" ]]; then ok; else fail "$1: want [$3] got [$2]"; fi
}

echo "turn off"
# A kit install exactly at its origin's main, built from this checkout's files (tracked and new ones), so the
# command's own reviewed-install check passes.
git init -q -b main "$work/src"
git -C "$here" ls-files -z -c -o --exclude-standard | (cd "$here" && tar --null -T - -cf -) | tar -x -C "$work/src"
git -C "$work/src" add -A
git -C "$work/src" -c user.name=t -c user.email=t@example.invalid commit -q -m kit
git clone -q --bare "$work/src" "$work/origin.git"
git clone -q "$work/origin.git" "$work/install"
template="$work/install/skills/guardrails-init/template"

# Writes a project as /guardrails-init leaves it into a directory: the kit files, the TypeScript Makefile, AGENTS.md
# with the kit's section, a spec and code. Argument: directory.
kit_project() {
  mkdir -p "$1/.github/workflows" "$1/.claude" "$1/.cursor" "$1/specs/ABC-1" "$1/src"
  cp -R "$template/.agent" "$1/.agent"
  cp "$template/.claude/settings.json" "$1/.claude/settings.json"
  cp "$template/.cursor/hooks.json" "$1/.cursor/hooks.json"
  cp "$template/.github/workflows/agent-guard.yml" "$template/.github/workflows/security.yml" \
    "$template/.github/workflows/agent-notify.yml" "$template/ci/checks-node.yml" "$1/.github/workflows/"
  cp "$template/makefiles/Makefile.typescript" "$1/Makefile"
  printf 'name: other\n' >"$1/.github/workflows/release.yml"
  printf 'spec\n' >"$1/specs/ABC-1/acceptance-criteria.md"
  printf 'code\n' >"$1/src/index.ts"
  {
    printf '# shop\n\nSetup: pnpm install\n\n'
    cat "$template/AGENTS.section.md"
  } >"$1/AGENTS.md"
}
# Commits a project directory and serves it as https://github.com/acme/<name>.git. Arguments: directory, name.
publish() {
  git -C "$1" init -q -b main
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m project
  mkdir -p "$work/remote/acme"
  git clone -q --bare "$1" "$work/remote/acme/$2.git"
}

kit_project "$work/shop"
publish "$work/shop" shop

# acme/links holds symbolic links into a directory outside every checkout, where the old removal read and wrote:
# AGENTS.md, AGENTS.md.tmp, Makefile.tmp and the .claude directory, which holds the kit's own settings.json.
outside="$work/outside"
mkdir -p "$outside/claude"
{
  printf '# outside\n\n'
  cat "$template/AGENTS.section.md"
} >"$outside/agents.md"
cp "$template/.claude/settings.json" "$outside/claude/settings.json"
printf 'sentinel\n' >"$outside/sentinel"
kit_project "$work/links"
rm "$work/links/AGENTS.md"
rm -r "$work/links/.claude"
ln -s "$outside/agents.md" "$work/links/AGENTS.md"
ln -s "$outside/claude" "$work/links/.claude"
ln -s "$outside/sentinel" "$work/links/AGENTS.md.tmp"
ln -s "$outside/sentinel" "$work/links/Makefile.tmp"
printf 'deploy:\n\t./deploy.sh\n' >>"$work/links/Makefile"
publish "$work/links" links

fake="$work/fake"
mkdir -p "$fake/bin"
cat >"$fake/bin/gh" <<FAKE
#!/usr/bin/env bash
args="\$*"
fake="$fake"
FAKE
cat >>"$fake/bin/gh" <<'FAKE'
case $args in
  "repo view acme/shop --json defaultBranchRef --jq .defaultBranchRef.name" | \
    "repo view acme/links --json defaultBranchRef --jq .defaultBranchRef.name") echo main ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails")'*) echo 7 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-review")'*) echo 8 ;;
  "api --paginate repos/acme/shop/rulesets?includes_parents=false --jq "*'"agent-guardrails-tags")'*) echo 9 ;;
  "api repos/acme/shop/rulesets/"[789]) printf '{"id": %s}\n' "${args##*/}" ;;
  "pr create --base main --head chore/remove-agent-guardrails "*)
    printf '%s\n' "$args" >>"$fake/writes.log"
    echo https://github.com/acme/shop/pull/12
    ;;
  "api -X DELETE "* | "pr merge "* | "repo edit "*) printf '%s\n' "$args" >>"$fake/writes.log" ;;
  *)
    printf 'fake gh: unexpected call: %s\n' "$args" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$fake/bin/gh"
fake_home="$work/home"
mkdir -p "$fake_home/.config/agent-guardrails"

# Runs `guardrails off` on a repository, typing an answer at its prompt; prints its exit status. Output in $work/out,
# plan and confirmation events in $work/events, writes in $fake/writes.log. Arguments: owner/repo, answer.
turn_off() {
  local status=0
  rm -f "$fake/writes.log" "$work/events"
  touch "$fake/writes.log" "$work/events"
  # The removal commit needs a git identity, which a CI runner does not have.
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR HOME="$fake_home" PATH="$fake/bin:$PATH" GUARDRAILS_EVENTS_FD=3 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/remote/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ \
    GIT_AUTHOR_NAME=owner GIT_AUTHOR_EMAIL=owner@example.invalid \
    GIT_COMMITTER_NAME=owner GIT_COMMITTER_EMAIL=owner@example.invalid \
    python3 -I "$here/tests/pty-run.py" "$2" -- "$work/install/bin/guardrails" off "$1" \
    >"$work/out" 2>&1 3>"$work/events" || status=$?
  printf '%s\n' "$status"
}
outside_files() { (cd "$outside" && find . -type f -exec shasum {} + | sort); }
removal_branch() { git -C "$work/remote/acme/$1.git" rev-parse --verify --quiet refs/heads/chore/remove-agent-guardrails || true; }

before=$(outside_files)
expect_eq "a cancelled off stops at the confirmation" "$(turn_off acme/links no)" 1
expect_out "after showing the plan" "kept (a symbolic link or other non-file, not followed; remove the kit section by hand): AGENTS.md"
expect_out "and says nothing changed" "confirmation did not match; nothing changed"
expect_eq "nothing outside its checkout changed" "$(outside_files)" "$before"
expect_eq "nothing was written to GitHub" "$(cat "$fake/writes.log")" ""
expect_eq "nothing was pushed" "$(removal_branch links)" ""

expect_eq "a confirmed off turns the guardrails off" "$(turn_off acme/shop acme/shop)" 0
expect_eq "the plan lists the edited and removed files" \
  "$(jq -r -s '.[] | select(.event == "plan") | .removed[] | select(test("AGENTS.md|Makefile|release.yml|\\.agent/bin/ci-guard$"))' "$work/events")" \
  "D	.agent/bin/ci-guard
M	AGENTS.md
D	Makefile"
head=$(removal_branch shop)
expect_eq "the pushed removal holds the project without the kit" \
  "$(git -C "$work/remote/acme/shop.git" ls-tree -r --name-only "$head")" ".github/workflows/release.yml
AGENTS.md
specs/ABC-1/acceptance-criteria.md
src/index.ts"
expect_eq "its AGENTS.md keeps the project part" "$(git -C "$work/remote/acme/shop.git" show "$head:AGENTS.md")" "# shop

Setup: pnpm install"
expect_eq "the merge is pinned to that commit" "$(grep -c "^pr merge https://github.com/acme/shop/pull/12 --squash --delete-branch --match-head-commit $head\$" "$fake/writes.log")" 1
expect_eq "the three rulesets are deleted" "$(grep -c '^api -X DELETE repos/acme/shop/rulesets/[789]$' "$fake/writes.log")" 3

printf '%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
