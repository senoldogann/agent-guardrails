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

echo "bash-guard: nested calls, environment and flag spellings"
cwd=$kit_repo
# A gh call inside another's arguments is a call of its own.
# shellcheck disable=SC2016 # literal input under test
block 'gh pr view 1 $(gh pr review 1 --approve)'
# shellcheck disable=SC2016 # literal input under test
block 'gh pr comment 1 --body "$(gh pr merge 1 --admin --squash)"'
block 'gh issue list < <(gh pr review 1 --approve)'
# shellcheck disable=SC2016 # literal input under test
block 'gh pr view 1 `gh pr review 1 --approve`'
allow 'gh pr create --title "fix: rates (x)" --body-file /tmp/b.md'
# shellcheck disable=SC2016 # literal input under test
allow 'gh pr comment 1 --body "$(cat /tmp/note.md)"'
# Protected calls take their flags only literally.
# shellcheck disable=SC2016 # literal input under test
block 'gh pr merge 1 --squash $(printf -- --admin)'
# shellcheck disable=SC2016 # literal input under test
block 'gh pr edit 1 $FLAGS'
# shellcheck disable=SC2016 # literal input under test
block 'gh api repos/o/r/pulls $EXTRA'
allow 'cd /tmp && gh pr merge 12 --auto --squash'
# shellcheck disable=SC2016 # literal input under test
allow 'gh pr view $N --json state'
# shellcheck disable=SC2016 # literal input under test
allow 'gh pr checks "$(git branch --show-current)"'
# Every spelling of a checked flag.
block 'gh pr edit 1 --base=release'
block 'gh pr edit 1 -Brelease'
block 'gh pr merge 1 --admin=true --squash'
block 'gh api repos/o/r/issues/1/comments -fbody=x'
block 'gh api repos/o/r/issues/1/comments --raw-field=body=x'
block 'gh api -XPOST repos/o/r/issues/1/comments'
block 'gh auth status --show-token'
block 'gh auth status -ht'
allow 'gh pr edit 1 --title "x" --body-file /tmp/b.md'
allow 'gh api repos/o/r/pulls/12/files --jq ".[].filename"'
# A parenthesis in a title or a jq filter does not end the call: the flags after it count.
block 'gh pr merge 12 --squash --subject "feat: discount (#12)" --admin'
block 'gh pr edit 12 --title "fix: rates (EUR)" --base release'
block 'gh api repos/o/r/pulls/1/merge --jq "(.merged)" -X PUT'
# A line that ends in a backslash continues on the next.
block $'gh pr merge 12 --squash \\\n  --admin'
block $'git push origin \\\n  main'
# Dropping the session's environment hands gh and git the owner's login.
block 'env -i HOME=/Users/x PATH=/usr/bin:/opt/homebrew/bin gh pr merge 1 --auto --squash'
block 'env -i PATH=/opt/homebrew/bin git push origin feat/ABC-1-x'
block 'env - gh pr list'
block 'env -u FOO -i gh pr list'
block 'env --ignore-environment gh pr list'
block 'exec -c gh pr list'
block 'tmux new-session -d "make test"'
block 'screen -dm make test'
block 'crontab /tmp/jobs'
block 'launchctl submit -l x -- /bin/sh -c make'
block 'open -a Terminal /tmp/run.command'
block 'open /tmp/run.command'
block 'osascript -e "do shell script \"make test\""'
block 'ssh localhost gh pr list'
block 'ssh -p 22 me@localhost gh pr list'
block '/usr/bin/env -i PATH=/usr/bin:/bin gh pr list'
block 'sudo env -i gh pr list'
allow 'env FOO=1 grep -i pattern src/a.ts'
allow 'git commit -m "fix: screen reader labels in tmux docs"'
allow 'git commit -m "docs: explain how to set up tmux new-session for the dev server"'
allow 'screen -ls'
allow 'ssh deploy@prod.example.com "curl -s localhost:8080/health"'
allow 'ssh -L localhost:5432:db.internal:5432 bastion.example.com'
allow 'open https://github.com/o/r/pull/1'
allow 'osascript -e "display notification \"done\""'
# Git settings by git -c or the environment.
block 'git -c url.git@github.com:.insteadOf=https://github.com/ push origin feat/x'
block 'git -c core.hooksPath=/dev/null commit -m x'
block 'git -c credential.helper=store push origin feat/x'
block 'git -c core.sshCommand="ssh -i /tmp/k" push origin feat/x'
block 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= git push origin feat/x'
block 'GIT_SSH_COMMAND="ssh -i /tmp/k" git push origin feat/x'
block 'git config core.sshCommand "ssh -i /tmp/k"'
allow 'git -c user.name=t -c user.email=t@example.invalid commit -m x'
allow 'git log -c --stat -1'
block 'git --config-env=credential.helper=H push origin feat/x'
# The agent's identity lives in GIT_CONFIG_*: clearing it hands git the owner's keychain.
block 'unset GIT_CONFIG_COUNT; git push origin feat/x'
block 'env -u GIT_CONFIG_COUNT git push origin feat/x'
# git -C names a directory and git switch -c a branch; neither overrides a setting.
allow 'git switch -c fix/credential-rotation'
allow 'git -C services/credentials status'
allow 'git grep -c credential -- src'
allow 'git diff -C src/credentials.ts'
# Printing the environment.
block 'export'
block 'cd /tmp && export'
block 'bash -c "export"'
block '/usr/bin/env'
block 'declare -x'
block 'typeset -p'
block 'env -0'
block 'env -u FOO'
block 'env FOO=1'
block 'python3 -c "import os; print(os.environ)"'
block 'node -e "console.log(process.env)"'
block 'ps eww 123'
block 'ps -E -p 123'
allow 'export FOO=bar; make test'
allow 'declare -p FOO'
allow 'ps aux'
allow 'ps -ef'
allow 'ps -o user,pid -p 1'
allow 'git commit -m "docs: the ps entries table"'
allow 'git commit -m "feat: add CSV export"'
allow 'gh pr create --title "feat: PDF export" --body "Adds the PDF export"'
allow 'python3 scripts/check_environment.py'
allow 'python3 -m pytest tests/test_environments.py'
allow 'git commit -m "fix: the python helper no longer reads os.environ"'
# The user's hook registrations change only through the file tools, which check the change; the shell may read them.
for hook_cwd in "$kit_repo" "$plain_repo"; do
  cwd=$hook_cwd
  block "sed -i '' '/bash-guard/d' ~/.claude/settings.json"
  # shellcheck disable=SC2016 # literal input under test
  block 'jq "del(.hooks)" "$HOME/.claude/settings.json" >/tmp/s && mv /tmp/s "$HOME/.claude/settings.json"'
  block 'cd ~/.claude && sed -i "" /bash-guard/d settings.json'
  block "echo '{\"disableAllHooks\": true}' > .claude/settings.local.json"
  block 'claude config set -g disableAllHooks true'
  allow 'cat ~/.claude/settings.json'
  allow 'jq .hooks ~/.claude/settings.json'
  allow 'cp ~/.claude/skills/guardrails-init/template/.claude/settings.json .claude/settings.json'
  allow 'git commit -m "docs: explain disableAllHooks"'
done
cwd=$kit_repo

echo "bash-guard: file tools"
# Runs the guard on a file tool's input; checks its exit status. Arguments: want, tool, tool_input JSON.
tool_check() {
  local want=$1 got
  set +e
  jq -n --arg t "$2" --argjson i "$3" --arg d "$cwd" '{cwd: $d, tool_name: $t, tool_input: $i}' | "$guard" >/dev/null 2>&1
  got=$?
  set -e
  if [[ $got -eq $want ]]; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf '  FAIL %s want %d got %d: %s\n' "$2" "$want" "$got" "$3"
  fi
}
write_input() { jq -n -c --arg f "$1" --arg c "$2" '{file_path: $f, content: $c}'; }
edit_input() { jq -n -c --arg f "$1" --arg o "$2" --arg n "$3" '{file_path: $f, old_string: $o, new_string: $n}'; }
kit_root=$(cd "$hooks/.." && pwd -P)
cwd=$kit_repo
# The kit install this guard runs from, also through a link and for a file that does not exist yet.
tool_check 2 Write "$(write_input "$kit_root/hooks-global/bash-guard.sh" "exit 0")"
tool_check 2 Edit "$(edit_input "$kit_root/hooks-global/bash-guard.sh" "deny" "true")"
tool_check 2 Write "$(write_input "$kit_root/hooks-global/new-hook.sh" "x")"
ln -s "$kit_root/hooks-global" "$work/hooks-link"
tool_check 2 Write "$(write_input "$work/hooks-link/bash-guard.sh" "exit 0")"
ln -s "$kit_root/hooks-global/created.sh" "$work/dangling-link"
tool_check 2 Write "$(write_input "$work/dangling-link" "exit 0")"
tool_check 0 Write "$(write_input "$kit_repo/src/a.ts" "export const a = 1;")"
# The owner's kit settings, also through a link.
mkdir -p "$HOME/.config/agent-guardrails"
tool_check 2 Write "$(write_input "$HOME/.config/agent-guardrails/repos" "")"
ln -s "$HOME/.config/agent-guardrails" "$work/settings-link"
tool_check 2 Write "$(write_input "$work/settings-link/repos" "")"
# The kit's hook entries in the user's hook registrations stay exactly as they are; anything else there may change.
mkdir -p "$HOME/.claude" "$HOME/.codex"
hooked='{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/k/hooks-global/bash-guard.sh"}]}]}}'
printf '%s\n' "$hooked" >"$HOME/.claude/settings.json"
printf '%s\n' "$hooked" >"$HOME/.codex/hooks.json"
tool_check 0 Write "$(write_input "$HOME/.claude/settings.json" "$(jq -c '.theme = "dark"' <<<"$hooked")")"
tool_check 0 Edit "$(edit_input "$HOME/.claude/settings.json" '{"hooks"' '{"theme": "dark", "hooks"')"
tool_check 2 Write "$(write_input "$HOME/.claude/settings.json" '{"theme": "dark", "x": "/k/hooks-global/bash-guard.sh"}')"
tool_check 2 Write "$(write_input "$HOME/.claude/settings.json" '{"theme": "dark"}')"
tool_check 2 Write "$(write_input "$HOME/.claude/settings.json" '{"hooks": ')"
tool_check 2 Write "$(write_input "$HOME/.codex/hooks.json" '{}')"
tool_check 2 Edit "$(edit_input "$HOME/.claude/settings.json" '"command": "/k/hooks-global/bash-guard.sh"' '"command": "true"')"
tool_check 2 Edit "$(edit_input "$HOME/.claude/settings.json" 'bash-guard.sh"' 'bash-guard.sh || true"')"
tool_check 2 Edit "$(edit_input "$HOME/.claude/settings.json" '"matcher": "Bash"' '"matcher": "Edit"')"
tool_check 2 Edit "$(edit_input "$HOME/.claude/settings.json" '"PreToolUse"' '"PostToolUse"')"
tool_check 2 Edit "$(jq -n -c --arg f "$HOME/.claude/settings.json" \
  '{file_path: $f, old_string: "hooks-global/", new_string: "hooks-global.off/", replace_all: true}')"
tool_check 2 Edit "$(edit_input "$HOME/.claude/settings.json" '{"hooks"' '{"disableAllHooks": true, "hooks"')"
tool_check 2 MultiEdit "$(jq -n -c --arg f "$HOME/.claude/settings.json" \
  '{file_path: $f, edits: [{old_string: "/k/hooks-global/bash-guard.sh", new_string: "/bin/true"}]}')"
tool_check 0 Write "$(write_input "$HOME/.cursor/hooks.json" '{"version": 1}')"
# A registration linked in from a dotfiles repository, and Codex's under CODEX_HOME.
mkdir -p "$work/dotfiles" "$work/codex-home"
mv "$HOME/.claude/settings.json" "$work/dotfiles/settings.json"
ln -s "$work/dotfiles/settings.json" "$HOME/.claude/settings.json"
tool_check 2 Write "$(write_input "$work/dotfiles/settings.json" '{}')"
rm "$HOME/.claude/settings.json"
mv "$work/dotfiles/settings.json" "$HOME/.claude/settings.json"
printf '%s\n' "$hooked" >"$work/codex-home/hooks.json"
export CODEX_HOME="$work/codex-home"
tool_check 2 Write "$(write_input "$work/codex-home/hooks.json" '{}')"
unset CODEX_HOME
tool_check 0 Write "$(write_input "$work/codex-home/hooks.json" '{}')"
# disableAllHooks in any Claude Code settings file turns the kit's hooks off too; a project's own registrations
# may otherwise change (the kit copies them).
tool_check 2 Write "$(write_input "$kit_repo/.claude/settings.local.json" '{"disableAllHooks": true}')"
tool_check 2 Write "$(write_input "$plain_repo/.claude/settings.json" '{"disableAllHooks": "true"}')"
tool_check 0 Write "$(write_input "$kit_repo/.claude/settings.json" '{"hooks": {}}')"
tool_check 0 Write "$(write_input "$plain_repo/.claude/settings.json" '{"disableAllHooks": false}')"
# Reads: the owner's settings everywhere, credential files in kit repositories; Grep and Glob by their path.
tool_check 2 Read "$(jq -n -c --arg f "$HOME/.config/agent-guardrails/agent/private-key.pem" '{file_path: $f}')"
tool_check 2 Grep "$(jq -n -c --arg p "$HOME/.config/agent-guardrails" '{pattern: "BEGIN", path: $p}')"
tool_check 2 Read "$(jq -n -c --arg f "$HOME/.config/gh/hosts.yml" '{file_path: $f}')"
tool_check 0 Read "$(jq -n -c --arg f "$kit_root/hooks-global/bash-guard.sh" '{file_path: $f}')"
tool_check 0 Glob '{"pattern": "**/*.ts"}'
# The owner's settings through a link, and a search over the directory that holds them or a parent of it.
tool_check 2 Read "$(jq -n -c --arg f "$work/settings-link/agent/private-key.pem" '{file_path: $f}')"
tool_check 2 Grep "$(jq -n -c --arg p "$HOME/.config" '{pattern: "BEGIN", path: $p}')"
tool_check 2 Grep "$(jq -n -c --arg p "$HOME/" '{pattern: "BEGIN", path: $p}')"
tool_check 2 Grep '{"pattern": "BEGIN", "path": "/"}'
ln -s "$HOME" "$work/home-link"
tool_check 2 Grep "$(jq -n -c --arg p "$work/home-link" '{pattern: "BEGIN", path: $p}')"
tool_check 0 Grep "$(jq -n -c --arg p "$kit_repo" '{pattern: "BEGIN", path: $p}')"
tool_check 0 Grep '{"pattern": "BEGIN"}'
tool_check 0 Glob "$(jq -n -c --arg p "$HOME" '{pattern: "*.md", path: $p}')"
# Grep hands its path over as written and expands ~ itself.
tool_check 2 Grep '{"pattern": "BEGIN", "path": "~"}'
tool_check 2 Grep '{"pattern": "BEGIN", "path": "~/"}'
tool_check 2 Grep '{"pattern": "oauth_token", "path": "~/.config"}'
# Credentials by their real place, not by a file of the same name.
mkdir -p "$kit_repo/inventory"
tool_check 0 Read "$(jq -n -c --arg f "$kit_repo/inventory/hosts.yml" '{file_path: $f}')"
tool_check 0 Edit "$(edit_input "$kit_repo/inventory/hosts.yml" 'a' 'b')"
tool_check 2 Read "$(jq -n -c --arg f "$HOME/.netrc" '{file_path: $f}')"
tool_check 2 Read "$(jq -n -c --arg f "$HOME/.config/git/credentials" '{file_path: $f}')"
tool_check 2 Read "$(jq -n -c --arg f "$kit_repo/.claude/settings.local.json" '{file_path: $f}')"
cwd=$HOME
tool_check 2 Grep '{"pattern": "BEGIN"}'
cwd=$plain_repo
tool_check 0 Read "$(jq -n -c --arg f "$HOME/.config/gh/hosts.yml" '{file_path: $f}')"
tool_check 2 Read "$(jq -n -c --arg f "$HOME/.config/agent-guardrails/agent/private-key.pem" '{file_path: $f}')"
tool_check 2 Grep "$(jq -n -c --arg p "$HOME" '{pattern: "BEGIN", path: $p}')"
tool_check 2 Write "$(write_input "$kit_root/hooks-global/bash-guard.sh" "exit 0")"

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
