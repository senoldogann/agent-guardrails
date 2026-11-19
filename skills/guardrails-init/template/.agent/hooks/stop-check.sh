#!/usr/bin/env bash
# Claude Code Stop hook. While a phase is active, it runs the deterministic checks when the agent
# tries to finish: `make check-spec` (spec phase) or `make check` (implement phase).
# Exit code 2 sends the failure tail back to the agent. After MAX_BLOCKS consecutive
# failures it lets the agent stop and warns the user instead of looping forever.
# `.agent/bin/block <question>` lets the agent stop to ask the human; the question is shown.
set -euo pipefail

readonly MAX_BLOCKS=3
input=$(cat)
root=${CLAUDE_PROJECT_DIR:?CLAUDE_PROJECT_DIR is not set}
active="$root/.agent/active"
[[ -f $active ]] || exit 0
read -r mode ticket <"$active"

if [[ -f "$root/.agent/blocked" ]]; then
  jq -n --arg msg "Agent is waiting for you on $ticket ($mode phase): $(<"$root/.agent/blocked")" '{systemMessage: $msg}'
  exit 0
fi

case $mode in
  spec) target=check-spec ;;
  implement) target=check ;;
  *)
    printf 'stop-check: unknown phase %s in .agent/active\n' "$mode" >&2
    exit 2
    ;;
esac

session=$(jq -r '.session_id' <<<"$input")
counter="$root/.agent/stop-blocks-$session"
log="$root/.agent/reports/$ticket/stop-$target.log"
mkdir -p "$(dirname "$log")"

if (cd "$root" && make --no-print-directory "$target") >"$log" 2>&1; then
  rm -f "$counter"
  exit 0
fi

blocks=0
[[ ! -f $counter ]] || blocks=$(<"$counter")
if ((blocks >= MAX_BLOCKS)); then
  rm -f "$counter"
  jq -n --arg msg "stop-check: 'make $target' still fails after $MAX_BLOCKS attempts for $ticket. The work is NOT done. Log: $log" \
    '{systemMessage: $msg}'
  exit 0
fi
printf '%d\n' $((blocks + 1)) >"$counter"

printf "'make %s' failed (%s phase, %s). You may not finish yet. Fix the implementation, never the checks.\nIf a check itself looks wrong or you need a decision, run .agent/bin/block '<question>' and stop.\n--- last 80 lines of %s ---\n%s\n" \
  "$target" "$mode" "$ticket" "$log" "$(tail -n 80 "$log")" >&2
exit 2
