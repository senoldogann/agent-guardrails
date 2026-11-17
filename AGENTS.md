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
  `off` deletes the rulesets and merges a PR that removes the kit; `approve`/`revoke` wrap `bin/approve-head`
  and `bin/revoke-head` (approval of a PR's exact HEAD). `on` picks the mode: review mode when the agent App is
  installed on the repo (a code owner's GitHub review pinned to the commit, CODEOWNERS required, admins may
  bypass only through a PR), status mode otherwise (the commit status `merge-approval`); both add a tag
  ruleset (admins only). Rulesets are built by pure functions in `bin/guardrails-lib.sh`. Enforced repos
  are listed in `~/.config/agent-guardrails/repos`. Offline-testable parts live in `bin/guardrails-lib.sh`.
  `agent create` registers the agent's own GitHub App through the manifest flow (`scripts/app-manifest-flow.py`,
  standard library only) and keeps its ID and private key in `~/.config/agent-guardrails/agent/`;
  `agent status` shows where it is installed. `bin/agent-app-lib.sh` signs App JWTs with openssl and mints
  installation tokens limited to one repository and the agent's permissions (contents and pull requests write,
  no workflows).
  For the Guardrails app, `inbox --json`, `projects --json` (the owner's repos with their state, one GraphQL
  query) and `prs <owner/repo> --json` are read-only and print one item per line, and with `GUARDRAILS_EVENTS_FD=<3-9>` the
  commands also write their plan and each expected confirmation as JSON lines to that descriptor.
- `app/` the owner's macOS menu bar app (SwiftPM, macOS 26, Liquid Glass): lists what waits for the owner, a
  Projects window with every repo's state and open PRs, set-up of new projects (clone check, then Terminal with
  `claude "/guardrails-init"`), and runs `guardrails approve|on|off` inside a pseudo-terminal (`script -q /dev/null`). It shows the CLI's plan
  event, checks every confirmation against that plan and asks for Touch ID before typing it. The CLI stays
  the authority. The app is a convenience, not a boundary against an agent running as the same user.
  `GuardrailsCore` holds the testable parts; `app/build.sh` writes the kit path into Info.plist and installs
  `~/Applications/Guardrails.app`.
- `hooks-global/` user-level hooks installed into `~/.claude/settings.json`. They act only in kit
  repositories (`.agent/bin/ci-guard` exists or the origin is an enforced repo) and on commands that name an
  enforced repo: `bash-guard.sh` blocks owner-only GitHub actions and credential reads, `prompt-reminder.sh`
  adds a one-line reminder per prompt. Everywhere they block the owner's commands and the enforced-repo list.
  `agent-identity.sh` (SessionStart, and PreToolUse Bash to renew) points a kit repository's session at a
  one-hour token of the agent App through `CLAUDE_ENV_FILE` (`GH_CONFIG_DIR`, git helper and SSH-to-HTTPS
  rewrite), so gh and git push run as the App's bot; it fails closed when the App is installed but no token
  can be minted. `kit-project.sh` (sourced by the hooks and `bin/guardrails`) decides what counts as a kit
  repository.
- `README.md` is for people installing and using the kit; this file is for working on it.

## Commands

- Install: `./install.sh` from a clone nobody develops in (symlinks skills into `~/.claude/skills`, registers
  global hooks, links the owner commands onto PATH; idempotent, moves links over from another kit clone,
  backs up settings.json before changing it). The state-changing owner commands (`on`, `off`, `approve`,
  `approve-head`) refuse to run from a clone with local changes or not at its origin's main.
- Check: `make check` (= shellcheck + the offline tests in `tests/`).
- Language adapters: `make test-lang` (slow; real mini projects per language).
- Release: raise `VERSION` (semver) and move the `Unreleased` entries of `CHANGELOG.md` under that version in
  the same PR; after the merge `.github/workflows/release.yml` tags `v<VERSION>` and publishes the section as the
  release notes. Changes worth a note go under `Unreleased` in their own PR.
- App: `make app-test` (core tests), `make app` (build and install from the kit install; needs Xcode 26+).
  Rebuild the app after a kit change that touches `app/`.

## Gotchas

- Scripts must stay Bash 3.2 compatible (macOS `/bin/bash`): no `mapfile`, no associative
  arrays, no expanding possibly empty arrays under `set -u`.
- `grep -q` in a pipeline under `pipefail` can report SIGPIPE as failure; use `grep ... >/dev/null`.
- Pattern files (`write-allow`) are bash globs where `*` also matches `/`.
- Hooks are a fast local layer only; Bash can bypass them. `ci-guard`, run from the base branch
  via `pull_request_target`, is the authority.
- A kit change that adds or renames an owner command, a skill or a global hook only reaches the owner after
  `./install.sh` runs again; such a PR says so in its description. The owner updates the install clone
  (`git pull --ff-only`, `./install.sh`, `make app`); bash-guard blocks the agent from touching it.
- bash-guard reads every line of a command, heredoc bodies included: write text that names the owner's
  commands with the Write tool, not a heredoc.
