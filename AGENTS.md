# agent-guardrails

Reusable kit that makes agent work verifiable: humans define types, property tests and
acceptance scenarios up front; deterministic checks (local hooks + CI) decide when work is done.

## Layout

- `skills/guardrails-init/` installs the kit into a project; its `template/` is copied verbatim.
- `skills/ticket-spec/` spec phase (types, property tests, Gherkin, open questions);
  `references/<lang>.md` per language.
- `skills/ticket-implement/` implement phase against a locked spec.
- `skills/process-fix/` turns a recurring agent mistake into a context or check change.
- `template/.agent/bin/` project-side scripts; `template/.agent/hooks/` per-project Claude Code hooks;
  `template/.github/workflows/agent-guard.yml` base-branch guard + per-HEAD `merge-approval` environment.
- `hooks-global/` user-level hooks installed into `~/.claude/settings.json`: `bash-guard.sh` blocks
  owner-only GitHub actions and credential reads; `prompt-reminder.sh` adds a one-line reminder per prompt.

## Commands

- Install: `./install.sh` (symlinks skills into `~/.claude/skills`, registers global hooks; idempotent,
  backs up settings.json before changing it).
- Check: `make check` (= shellcheck + `tests/hooks-global.sh` + `tests/smoke.sh`).
- Language adapters: `make test-lang` (slow; real mini projects per language).

## Gotchas

- Scripts must stay Bash 3.2 compatible (macOS `/bin/bash`): no `mapfile`, no associative
  arrays, no expanding possibly empty arrays under `set -u`.
- `grep -q` in a pipeline under `pipefail` can report SIGPIPE as failure; use `grep ... >/dev/null`.
- Pattern files (`write-allow`) are bash globs where `*` also matches `/`.
- Hooks are a fast local layer only; Bash can bypass them. `ci-guard`, run from the base branch
  via `pull_request_target`, is the authority.
