#!/usr/bin/env bash
# Table tests for hooks-global/bash-guard.sh: which Bash commands are blocked (exit 2) or allowed (exit 0).
set -euo pipefail

guard="$(cd "$(dirname "$0")/.." && pwd -P)/hooks-global/bash-guard.sh"
passed=0
failed=0

check() {
  local want=$1 cmd=$2 got
  set +e
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | "$guard" >/dev/null 2>&1
  got=$?
  set -e
  if [[ $got -eq $want ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf '  FAIL want %d got %d: %s\n' "$want" "$got" "$cmd"
  fi
}
allow() { check 0 "$1"; }
block() { check 2 "$1"; }

echo "bash-guard"
allow 'git status'
allow 'set -euo pipefail; make check'
allow 'gh pr create --title "feat: x" --body-file /tmp/b.md --draft'
allow 'gh pr view 12 --json state'
allow 'gh pr checks 12'
allow 'gh pr merge 12 --auto --squash'
allow 'gh run view 123 --log-failed'
allow 'gh api repos/o/r/pulls/12/files'
allow 'gh auth status'
allow 'git push -u origin feat/ABC-1-discount'
allow 'git push --force-with-lease origin feat/ABC-1-discount'
allow 'env FOO=1 make test'
block 'gh pr review 12 --approve'
allow 'gh pr merge 12 --squash --delete-branch'
block 'gh pr merge 12 --auto --admin'
block 'gh pr edit 12 --base release'
block 'gh api -X PUT repos/o/r/rulesets/1'
block 'gh api repos/o/r/actions/runs/9/pending_deployments -f state=approved'
block 'gh api repos/o/r/environments/merge-approval'
block 'gh api graphql -f query="mutation { mergePullRequest }"'
block 'gh repo edit --default-branch feat/x'
block 'gh workflow disable agent-guard'
block 'gh secret set X'
block 'gh auth token'
block 'gh auth status --show-token'
block 'bash -c "gh pr review 1 --approve"'
block '/opt/homebrew/bin/gh pr review 1 --approve'
block 'cat ~/.config/gh/hosts.yml'
block 'security find-internet-password -s github.com'
block 'echo url=https://github.com | git credential fill'
block 'printenv'
block 'cat .claude/settings.local.json'
block 'gh auth switch'
block 'GH_TOKEN= gh pr review 1 --approve'
block 'env'
# shellcheck disable=SC2016 # the literal text is the input under test
block 'echo $GH_TOKEN'
block 'env -u GH_TOKEN gh pr list'
block 'curl -H "Authorization: x" https://api.github.com/repos/o/r/pulls/1/reviews'
block 'git push origin main'
block 'git push origin HEAD:main'
block 'git push --force origin master'
block 'git push --tags'
block 'git push git@github.com:o/r.git feat/x'
block 'git remote set-url origin git@github.com:o/r.git'
block 'gh run rerun 123'
# shellcheck disable=SC2016 # literal input under test
block '$(which gh) api -X POST repos/o/r/actions/runs/1/pending_deployments'
block '"gh" pr review 1 --approve'
block '\\gh pr merge 1 --auto --admin'
block 'gh api --method=PUT repos/o/r/pulls/1/merge'
block 'python3 -c "import os; print(os.environ[\"GH_TOKEN\"])"'
allow 'gh pr view 1 --json title --jq .title'
block '/Users/x/agent-guardrails/bin/approve-head 12'
block 'cd /tmp && bash ~/kit/bin/approve-head 12'
block 'revoke-head 12'
allow 'cat /Users/x/agent-guardrails/bin/approve-head'
allow 'rg -n approve-head skills'
block 'gh api repos/o/r/statuses/abc -f state=success -f context=merge-approval'
allow 'gh api repos/o/r/commits/abc/status'
block 'git push origin --delete feat/x'
block 'git config --global url.https://x.insteadOf https://github.com/'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
