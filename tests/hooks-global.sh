#!/usr/bin/env bash
# Table tests for hooks-global/bash-guard.sh: which Bash commands are blocked (exit 2) or allowed (exit 0).
set -euo pipefail

hooks="$(cd "$(dirname "$0")/.." && pwd -P)/hooks-global"
guard="$hooks/bash-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
kit_repo="$work/kit-repo"
plain_repo="$work/plain-repo"
mkdir -p "$kit_repo/.agent/bin" "$plain_repo" "$work/not-a-repo"
git -C "$kit_repo" init -q
git -C "$plain_repo" init -q
printf '#!/usr/bin/env bash\n' >"$kit_repo/.agent/bin/ci-guard"
chmod +x "$kit_repo/.agent/bin/ci-guard"
mkdir -p "$kit_repo/src/deep"
passed=0
failed=0
cwd=$kit_repo

check() {
  local want=$1 cmd=$2 got
  set +e
  jq -n --arg c "$cmd" --arg d "$cwd" '{cwd: $d, tool_input: {command: $c}}' | "$guard" >/dev/null 2>&1
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
# Non-ASCII text next to escaped quotes once made a UTF-8 awk fail, which blocked the command.
LC_ALL=en_US.UTF-8 allow 'osascript -e "click menu item \"Close…\" of w \"#7 · x\""'
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
block 'GH_CONFIG_DIR=~/.config/gh gh pr list'
block 'unset GH_CONFIG_DIR; gh pr list'
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
allow 'gh issue close 1 --comment done'
allow 'gh issue reopen 1'
block '/Users/x/agent-guardrails/bin/approve-head 12'
block 'cd /tmp && bash ~/kit/bin/approve-head 12'
block 'revoke-head 12'
allow 'cat /Users/x/agent-guardrails/bin/approve-head'
allow 'rg -n approve-head skills'
block 'gh api repos/o/r/statuses/abc -f state=success -f context=merge-approval'
allow 'gh api repos/o/r/commits/abc/status'
block 'git push origin --delete feat/x'
block 'git config --global url.https://x.insteadOf https://github.com/'

echo "bash-guard outside kit repositories"
cwd=$plain_repo
allow 'gh pr review 12 --approve'
allow 'gh pr merge 12 --admin --squash'
allow 'gh repo create acme/tool --private'
allow 'gh auth token'
allow 'printenv'
allow 'cat ~/.config/gh/hosts.yml'
allow 'git push origin main'
block 'gh api repos/acme/shop/statuses/abc -f state=success -f context=merge-approval'
block '/Users/x/agent-guardrails/bin/approve-head https://github.com/acme/shop/pull/1'
cwd="$work/not-a-repo"
allow 'gh pr review 12 --approve'
block 'revoke-head 12'
cwd="$kit_repo/src/deep"
block 'gh pr review 12 --approve'

echo "owner commands, everywhere"
cwd=$plain_repo
block 'guardrails on https://github.com/acme/shop/pull/3'
block '/Users/x/kit/bin/guardrails off acme/shop'
block 'guardrails approve'
block 'guardrails agent create'
block 'guardrails update'
block 'agent-guardrails on acme/shop'
block 'agent-guardrails approve https://github.com/acme/shop/pull/3'
block '/opt/homebrew/bin/agent-guardrails update'
allow 'agent-guardrails status'
block 'guardrails agent create --org acme'
allow 'guardrails agent status'
block 'printf abc1234 | script -q /dev/null approve-head https://github.com/acme/shop/pull/1'
block 'echo 12 | xargs approve-head'
block 'find . -name x -exec revoke-head 1 ;'
block 'git -c alias.a=!approve-head a 1'
block 'bash -c "cat notes; approve-head 1"'
allow 'rg -n "setup-github|approve-head" skills'
allow 'git log --oneline | grep -E "guardrails on|approve-head"'
allow 'guardrails'
allow 'guardrails inbox'
allow 'guardrails status'
# Read-only like inbox and projects: the report changes nothing on GitHub.
allow 'guardrails report --json'
allow 'guardrails report acme/shop --days 7'
allow 'shellcheck -x bin/guardrails bin/guardrails-lib.sh'
allow 'chmod +x bin/guardrails'
allow 'git commit -m "docs: run guardrails on <PR link> to turn it on"'
allow 'gh pr create --title x --body "then run approve-head <link>"'
allow 'cd ~/myprojects/agent-guardrails && make check'
block 'git log -1 "
cat "; guardrails approve 1'
block 'git -c diff.external="script -q /dev/null guardrails approve" diff HEAD~1'
block 'LESSOPEN="|guardrails approve %s" less x'
# shellcheck disable=SC2016 # the hook must see the literal command substitution
block 'echo "$(guardrails approve 1)"'
# shellcheck disable=SC2016 # the hook must see the literal command substitution
block 'git commit -m "$(guardrails approve 1)"'
block 'rg --pre approve-head x .'
allow 'git commit -m "docs: explain approve-head" -m "and guardrails off"'
block 'git difftool -y --extcmd="guardrails approve" HEAD~1'
block 'git bisect run guardrails approve 1'
block 'git submodule foreach "guardrails off o/r"'
block 'guardrails ap\prove 1'
block 'printf "guardrails approve 1" | sh'
allow 'gh pr create --title x --body "Fixes it! Run guardrails on <link> next."'
allow 'cat >notes.md <<'"'"'EOF'"'"'
Run guardrails on <PR link>, then approve-head <link>.
EOF'
block 'python3 - <<EOF
import os; os.system("guardrails approve 1")
EOF'
block 'cat <<EOF | bash
guardrails approve 1
EOF'
block 'gh api graphql -f query="mutation { deleteRepositoryRuleset(input: {repositoryRulesetId: 1}) { clientMutationId } }"'
block 'gh repo edit acme/shop --remove-topic agent-guardrails'
block 'gh repo edit acme/shop --add-topic=ai,agent-guardrails'
block 'gh api -X PUT repos/acme/shop/topics -f "names[]=agent-guardrails"'
block 'gh api repos/acme/shop/topics --input - <<<"{\"names\":[\"agent-guardrails\"]}"'
block 'gh search repos topic:agent-guardrails'
allow 'gh repo edit acme/agent-guardrails --add-topic claude-code'
allow 'cd ~/src/agent-guardrails && rg -n topic hooks-global'
block 'cat ~/.local/share/agent-guardrails/bin/guardrails-lib.sh'
block 'rm -rf ~/.config/agent-g*'
block 'cd ~/.config && rm -r agent-guardrails'
block 'cat ~/.config/agent-guardrails/repos'
block 'cd ~/.config && cat agent-guardrails/repos'
allow 'cd ~/src/agent-guardrails-worktrees/app && rg -n "model.configuration" Sources'
block 'printf "acme/x\n" >> ~/.config/agent-guardrails/repos'
block 'printf "" > ~/.config/agent-guardrails/enforced-history'

echo "enforced repositories (owner's list)"
export HOME="$work/home"
mkdir -p "$HOME/.config/agent-guardrails"
printf 'acme/enforced\n' >"$HOME/.config/agent-guardrails/repos"
cloned_repo="$work/cloned-enforced"
mkdir -p "$cloned_repo"
git -C "$cloned_repo" init -q
git -C "$cloned_repo" remote add origin https://github.com/acme/enforced.git
cwd=$cloned_repo
block 'gh pr review 12 --approve'
block 'gh api -X DELETE repos/acme/enforced/rulesets/1'
cwd=$plain_repo
block 'gh api -X DELETE repos/acme/enforced/rulesets/1'
block 'gh pr merge 3 --admin -R acme/enforced'
block 'gh repo delete acme/enforced --yes'
block 'gh api -X DELETE repos/acme/other/rulesets/1'
allow 'gh api repos/acme/other/rulesets'
block 'gh api -X DELETE repositories/123456/rulesets/42'
block 'gh api -X PATCH repositories/123456 -f allow_merge_commit=true'
allow 'gh api -X PATCH repos/acme/other -f allow_merge_commit=true'
allow 'gh pr review 12 --approve'
git -C "$cloned_repo" remote set-url origin git@github.com:acme/enforced.git
cwd=$cloned_repo
block 'gh pr review 12 --approve'

echo "quiet when allowed, closed on errors"
for quiet_cwd in "$kit_repo" "$plain_repo" "$cloned_repo"; do
  noise=$(jq -n --arg d "$quiet_cwd" '{cwd: $d, tool_input: {command: "make check"}}' | "$guard" 2>&1 >/dev/null || true)
  if [[ -z $noise ]]; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf '  FAIL allowed command printed to stderr in %s: %s\n' "$quiet_cwd" "$noise"
  fi
done
set +e
printf 'not json' | "$guard" >/dev/null 2>&1
invalid_status=$?
set -e
if [[ $invalid_status -eq 2 ]]; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  printf '  FAIL invalid hook input must block (exit 2), got %s\n' "$invalid_status"
fi

echo "prompt-reminder"
reminder_out() { jq -n --arg d "$1" '{cwd: $d, prompt: "hi"}' | "$hooks/prompt-reminder.sh"; }
if [[ -n $(reminder_out "$kit_repo") ]]; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  echo "  FAIL reminder missing in kit repository"
fi
if [[ -z $(reminder_out "$plain_repo") ]]; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  echo "  FAIL reminder shown outside kit repository"
fi

# Cursor's hook input (https://cursor.com/docs/agent/hooks) goes through cursor-guard.sh, which answers with
# Cursor's JSON. Arguments: wanted permission, then the hook input as jq arguments and filter.
cursor_check() {
  local want=$1 got
  shift
  got=$(jq -n -c "$@" | "$hooks/cursor-guard.sh" 2>/dev/null | jq -r .permission) || got="invalid answer"
  if [[ $got == "$want" ]]; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf '  FAIL want %s got %s: %s\n' "$want" "$got" "$*"
  fi
}
# shellcheck disable=SC2016 # $c, $d and $r are jq variables
cursor_shell() {
  cursor_check "$1" --arg c "$2" --arg d "$cwd" --arg r "$kit_repo" \
    '{hook_event_name: "beforeShellExecution", conversation_id: "c1", generation_id: "g1", workspace_roots: [$r],
      command: $c, cwd: $d, sandbox: false}'
}
# shellcheck disable=SC2016 # $f and $r are jq variables
cursor_read() {
  cursor_check "$1" --arg f "$2" --arg r "$cwd" \
    '{hook_event_name: "beforeReadFile", conversation_id: "c1", generation_id: "g1", workspace_roots: [$r],
      file_path: $f, content: "x", attachments: []}'
}

echo "cursor-guard"
cwd=$kit_repo
cursor_shell allow 'git status'
cursor_shell allow 'gh pr create --title x --body-file /tmp/b.md'
cursor_shell deny 'guardrails approve https://github.com/acme/shop/pull/3'
cursor_shell deny 'gh pr merge 12 --auto --admin'
cursor_shell deny 'cat ~/.config/gh/hosts.yml'
cursor_read allow "$kit_repo/README.md"
cursor_read deny "$HOME/.config/gh/hosts.yml"
cursor_read deny "$kit_repo/.claude/settings.local.json"
cwd=$plain_repo
cursor_shell allow 'gh pr review 12 --approve'
cursor_shell deny 'revoke-head 12'
cursor_read allow "$HOME/.config/gh/hosts.yml"
# Without cwd the first workspace root decides, so the kit's rules still apply in a kit repository.
# shellcheck disable=SC2016 # $r is a jq variable
cursor_check deny --arg r "$kit_repo" '{hook_event_name: "beforeShellExecution", workspace_roots: [$r], command: "gh pr review 1 --approve"}'
# shellcheck disable=SC2016 # $r is a jq variable
cursor_check deny --arg r "$kit_repo" '{hook_event_name: "beforeShellExecution", workspace_roots: [$r], cwd: "", command: "gh pr review 1 --approve"}'
# A kit repository opened next to another folder guards reads, whichever root comes first.
# shellcheck disable=SC2016 # $p, $r and $f are jq variables
cursor_check deny --arg p "$plain_repo" --arg r "$kit_repo" --arg f "$HOME/.config/gh/hosts.yml" \
  '{hook_event_name: "beforeReadFile", workspace_roots: [$p, $r], file_path: $f, content: ""}'
# Reads meet only the rules on credential and owner files, not the command rules on paths like /environments/.
mkdir -p "$kit_repo/src/environments"
cursor_read allow "$kit_repo/src/environments/environment.ts"
cursor_read deny "$HOME/.config/agent-guardrails/repos"
cursor_check deny '{hook_event_name: "beforeShellExecution", workspace_roots: [], cwd: "/"}'
cursor_check deny '{hook_event_name: "afterFileEdit", file_path: "x"}'
cursor_answer=$(printf 'not json' | "$hooks/cursor-guard.sh" 2>/dev/null || true)
if [[ $(jq -r .permission <<<"$cursor_answer" 2>/dev/null) == deny ]]; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  printf '  FAIL invalid hook input must be denied, got: %s\n' "$cursor_answer"
fi
cwd=$kit_repo
cursor_answer=$(jq -n -c --arg d "$kit_repo" '{hook_event_name: "beforeShellExecution", cwd: $d, command: "gh pr review 1 --approve"}' |
  "$hooks/cursor-guard.sh")
if jq -e '.agent_message | startswith("BLOCKED by bash-guard")' <<<"$cursor_answer" >/dev/null; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  printf '  FAIL a denied command must tell the agent why, got: %s\n' "$cursor_answer"
fi
cursor_answer=$(jq -n -c '{hook_event_name: "beforeReadFile", workspace_roots: ["/"], file_path: "/etc/hosts", content: ""}' |
  "$hooks/cursor-guard.sh")
if [[ $cursor_answer == '{"permission":"allow"}' ]]; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  printf '  FAIL an allowed read answers only the permission, got: %s\n' "$cursor_answer"
fi

# Codex sends Claude Code's PreToolUse shape (openai/codex codex-rs/hooks/schema/generated/
# pre-tool-use.command.input.schema.json), so bash-guard.sh runs unchanged.
codex_check() {
  local want=$1 got
  set +e
  jq -n --arg c "$2" --arg d "$cwd" '{session_id: "s1", turn_id: "t1", transcript_path: null, cwd: $d,
    hook_event_name: "PreToolUse", model: "gpt-5", permission_mode: "default", tool_name: "Bash",
    tool_use_id: "call_1", tool_input: {command: $c}}' | "$guard" >/dev/null 2>&1
  got=$?
  set -e
  if [[ $got -eq $want ]]; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf '  FAIL codex want %d got %d: %s\n' "$want" "$got" "$2"
  fi
}
echo "bash-guard with Codex input"
cwd=$kit_repo
codex_check 0 'git status'
codex_check 2 'guardrails off acme/shop'
codex_check 2 'gh pr review 12 --approve'
codex_check 2 'cat ~/.config/gh/hosts.yml'
cwd=$plain_repo
codex_check 0 'gh pr review 12 --approve'
codex_reminder=$(jq -n --arg d "$kit_repo" '{session_id: "s1", turn_id: "t1", transcript_path: null, cwd: $d,
  hook_event_name: "UserPromptSubmit", model: "gpt-5", permission_mode: "default", prompt: "hi"}' | "$hooks/prompt-reminder.sh")
if [[ $codex_reminder == Reminder:* ]]; then passed=$((passed + 1)); else
  failed=$((failed + 1))
  echo "  FAIL reminder missing for Codex input"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
