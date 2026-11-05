# agent-guardrails

Reusable kit that makes agent work verifiable: humans define types, property tests and
acceptance scenarios up front; deterministic checks (local hooks + CI) decide when work is done.

## Layout

- `skills/guardrails-init/` installs the kit into a project; its `template/` is copied verbatim.
- `skills/ticket-spec/` spec phase (types, property tests, Gherkin, open questions);
  `references/<lang>.md` per language.
- `skills/ticket-implement/` implement phase against a locked spec.
- `skills/process-fix/` turns a recurring agent mistake into a context or check change.
- `template/.agent/bin/` project-side scripts; `template/.agent/hooks/` per-project Claude Code hooks
  (write-guard, stop-check, and a bash-guard shim so teammates' agents are guarded too);
  `template/.github/workflows/agent-guard.yml` base-branch guard.
- `bin/guardrails`: the owner's command. Without arguments it lists what waits for the owner across enforced
  repos; `on` checks a bootstrap PR's kit files against this install, merges it and applies the ruleset;
  `off` deletes the ruleset and merges a PR that removes the kit; `approve`/`revoke` wrap `bin/approve-head`
  and `bin/revoke-head` (approval of a PR's exact HEAD as the commit status `merge-approval`). Enforced repos
  are listed in `~/.config/agent-guardrails/repos`. Offline-testable parts live in `bin/guardrails-lib.sh`.
  For the Guardrails app, `inbox --json` prints one item per line, and with `GUARDRAILS_EVENTS_FD=<3-9>` the
  commands also write their plan and each expected confirmation as JSON lines to that descriptor.
- `hooks-global/` user-level hooks installed into `~/.claude/settings.json`. They act only in kit
  repositories (`.agent/bin/ci-guard` exists or the origin is an enforced repo) and on commands that name an
  enforced repo: `bash-guard.sh` blocks owner-only GitHub actions and credential reads, `prompt-reminder.sh`
  adds a one-line reminder per prompt. Everywhere they block the owner's commands and the enforced-repo list.

## Commands

- Install: `./install.sh` from a clone nobody develops in (symlinks skills into `~/.claude/skills`, registers
  global hooks, links the owner commands onto PATH; idempotent, moves links over from another kit clone,
  backs up settings.json before changing it). The owner's commands refuse to run from a clone with local
  changes or not at its origin's main.
- Check: `make check` (= shellcheck + the offline tests in `tests/`).
- Language adapters: `make test-lang` (slow; real mini projects per language).

## Gotchas

- Scripts must stay Bash 3.2 compatible (macOS `/bin/bash`): no `mapfile`, no associative
  arrays, no expanding possibly empty arrays under `set -u`.
- `grep -q` in a pipeline under `pipefail` can report SIGPIPE as failure; use `grep ... >/dev/null`.
- Pattern files (`write-allow`) are bash globs where `*` also matches `/`.
- Hooks are a fast local layer only; Bash can bypass them. `ci-guard`, run from the base branch
  via `pull_request_target`, is the authority.
- A kit change that adds or renames an owner command, a skill or a global hook only reaches the owner after
  `./install.sh` runs again; such a PR says so in its description, and the agent runs it after the merge.
- bash-guard reads every line of a command, heredoc bodies included: write text that names the owner's
  commands with the Write tool, not a heredoc.
