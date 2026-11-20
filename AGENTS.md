# agent-guardrails

Reusable kit that makes agent work verifiable: humans define types, property tests and
acceptance scenarios up front; deterministic checks decide when work is done. GitHub enforces it (the guard,
the required checks, the owner's per-HEAD approval); local hooks only catch mistakes early.

## Layout

- `skills/guardrails-init/` installs the kit into a project; its `template/` is copied verbatim.
- `skills/ticket-spec/` spec phase (types, property tests, Gherkin, open questions);
  `references/<lang>.md` per language.
- `skills/ticket-implement/` implement phase against a locked spec.
- `skills/process-fix/` turns a recurring agent mistake into a context or check change.
- `template/.agent/bin/` project-side scripts; `template/.agent/hooks/` per-project Claude Code hooks
  (write-guard; stop-check, which sends the agent back while the phase gate fails and lets it stop with a
  warning after three failures in a row; a bash-guard shim so teammates' agents are guarded too) and the Cursor shim
  `cursor-guard.sh`, run from `template/.cursor/hooks.json`;
  `template/.github/workflows/agent-guard.yml` base-branch guard; `template/.github/workflows/agent-notify.yml`
  team notifications to Slack or Microsoft Teams (inert without the owner's webhook secrets), whose payloads
  `template/.agent/bin/notify-team` builds from the pure functions in `notify-lib.sh` (tested offline in
  `tests/notify.sh`). Both workflows are kit files: `kit_drift` compares them byte for byte.
- The `security` check: `template/.github/workflows/security.yml` runs `template/.agent/bin/security-tools`
  (pinned gitleaks, osv-scanner, Semgrep CE and semgrep-rules commit, verified by checksum; Semgrep's hashed
  pins in `template/.agent/security/semgrep-pins.txt`) and `security-scan`; the report parsing and the
  `.github/security-ignore` format are pure functions in `security-lib.sh`, tested by `tests/security.sh`.
  It is a required check (`pinned_checks`), part of `kit_drift`, and `ci-guard` reserves its job name. The
  kit's own `ci.yml` runs the same scripts on the kit's PRs. To bump a tool, change its version and SHA-256 in
  `security-tools` (from the release's checksums file) or regenerate the pins as their header says.
- Workflow validation: `template/.agent/workflow/check.py` reads a workflow on stdin with PyYAML's scanner and
  parser (events only, every scalar a string) and prints problems: `token-problems` (checks or statuses
  writable, for every workflow) and `changed-problems <path>` (any write, reserved job ids and names, the guard
  trigger). `ci-guard`/`ci-guard-group` (`guard_workflows` in `guard-lib.sh`) and the owner's
  `workflow_token_problems` (`approve-head`, `guardrails on`) run this one file with `python3 -I -S -B`;
  exit 0 with no output accepts. `guardrails_pyyaml/` is PyYAML's release files unchanged (except the kit's own
  `__init__.py`), pinned in `scripts/vendored-pyyaml/requirements.txt` and compared with the sdist by
  `scripts/check-vendored-pyyaml.sh` in CI; its header says how to bump it. Tests: the workflow cases in
  `tests/smoke.sh` (through ci-guard) and `tests/guardrails-cli.sh` (owner side).
- `bin/guardrails` (also linked as `agent-guardrails`): the owner's command. Enforced repos are listed in
  `~/.config/agent-guardrails/repos`; `enforced-history` next to it holds what this Mac enforced and did not turn
  off, so a repo that drops out of the list raises an alarm whoever owns it (the topic search covers only the
  owner's own account: in an organization a teammate's Mac tags repos too). Offline-testable parts (rulesets, PR and project states, CODEOWNERS
  checks, `update`) live in `bin/guardrails-lib.sh` as functions over their inputs.
  - Without arguments it lists what waits for the owner across enforced repos.
  - `on` checks a bootstrap PR's kit files against this install, merges it and applies the rulesets; it picks
    review mode when the agent App is installed on the repo (a code owner's GitHub review pinned to the
    commit, CODEOWNERS required, in its own ruleset that admins may bypass through a PR) and status mode
    otherwise (the commit status `merge-approval`). A repository whose live rulesets are in review mode
    (`review_mode_rulesets`) is not switched to status mode without `--status-mode` (`on_mode`, which the plan event
    and the confirmation name). A mode switch puts the new approval rule in place before it removes the old one
    (`enforce`: the review ruleset before the branch ruleset drops merge-approval, merge-approval before the review
    ruleset goes), so a failure or an interruption halfway never leaves an approval-less repository; `stop_note`, printed
    by the EXIT trap, names what is on and the command that finishes. `tests/turn-on.sh` drives `on <owner/repo>` with
    a fake gh that keeps its ruleset writes (and refuses a chosen one) and a local clone.
    Nobody bypasses the branch ruleset with the checks; only
    admins create, move or delete tags. `off` deletes the rulesets and merges a PR that removes the kit. It prepares
    that PR before the confirmation, in a temporary clone that runs no git hooks (`clone_at`), by staging the removal
    in the clone's index only (`remove_kit_files`: blobs read by object id, edits written as new blobs, links removed
    or kept as links, never followed), so a cancelled `off` changes nothing outside that clone; after the confirmation
    it commits the planned tree with `commit-tree` and pushes that commit. `tests/turn-off.sh` drives `off` with a fake
    gh, local bare repositories and git settings that install hooks.
  - `on --merge-queue` (organization repositories in review mode only; `merge_queue_refusal` says why not) adds
    a `merge_queue` rule to the branch ruleset (`queued_branch_ruleset`) and lists the repo in
    `~/.config/agent-guardrails/merge-queue`; a plain `on` keeps the queue when that list or the live ruleset has
    it, `--no-merge-queue` drops it, and `ruleset_problems` alarms when a listed repo loses it. On merge groups
    `agent-guard.yml` runs the default branch's `.agent/bin/ci-guard-group` (checks shared with `ci-guard` live
    in `guard-lib.sh`), the checks workflows run `make check`, and `security` scans `base_sha..head_sha`.
    `pr_states` marks PRs in the queue `queued` (GraphQL `mergeQueue`, `queued_prs`); `approve-head` adds the
    owner's own PR with `enqueuePullRequest` instead of an admin merge, and merges never pass `--delete-branch`
    (gh refuses it with a queue; the repository deletes merged branches).
  - `approve`/`revoke` wrap `bin/approve-head` and `bin/revoke-head` (approval of a PR's exact HEAD). `approve-head`
    and `on <PR>` read the PR once and show GitHub's comparison of exactly that base and head (`pr_snapshot_files`,
    which refuses a list that may be incomplete: GitHub compares at most 300 files); `approve-head` reads the PR
    again before writing, and every write names the approved head. It reads both versions of every changed ticket
    spec lock by SHA (`changed_spec_locks`, `repo_file_at`, `lock_scope_change`), shows the files a re-lock drops or
    adds, and asks the `unlock` confirmation for a dropped one. In review mode it reads who pushed the head from
    GitHub's push log of the branch (`GET repos/{r}/activity`, `last_pusher`; never the committer, which may be the
    owner's git identity on the agent's commits): GitHub takes no review from the last pusher, so an agent PR whose
    newest push the owner's account made takes the pinned own-merge path (`ownPush`, `pushedBy`, `pushedAt`,
    `author` in the plan). `tests/approval.sh` drives
    `approve-head` with a fake gh in a pseudo-terminal (`tests/pty-run.py`).
  - `update` fast-forwards this install to its origin's main, reinstalls it and rebuilds the app.
  - `agent create` registers the agent's own GitHub App through the manifest flow
    (`scripts/app-manifest-flow.py`, standard library only) and keeps its ID and private key in
    `~/.config/agent-guardrails/agent/`; `agent status` shows where it is installed. `bin/agent-app-lib.sh`
    signs App JWTs with openssl and mints installation tokens limited to one repository and the agent's
    permissions (contents and pull requests write, no workflows).
  - `report [owner/repo] [--days N] [--json]` is read-only: per enforced repo over the last N days (default 30)
    the merged PRs by author (agent App or people), median and 90th percentile from ready for review to approval
    and to merge, re-approvals, failed guard and checks runs, merges without an approval on the final commit,
    and every ruleset version (ruleset history API) with its actor and what changed. PR data comes from one
    paginated GraphQL search; the numbers are pure functions in `bin/guardrails-lib.sh` (`pr_report`,
    `ruleset_audit`), tested in `tests/report.sh`.
  - For the app, `inbox --json`, `projects --json`, `prs <owner/repo> --json`, `report --json` and
    `agent status --json` are read-only and print one item per line; with `GUARDRAILS_EVENTS_FD=<3-9>` the state-changing commands
    also write their plan and each expected confirmation as JSON lines to that descriptor.
- `app/` the owner's macOS menu bar app (SwiftPM, macOS 26, Liquid Glass): what waits for the owner, a Projects
  window with every repo's state and open PRs, set-up of new projects (clone check, then Terminal with
  `claude "/guardrails-init"`), and `guardrails approve|on|off|update|agent create` run inside a pseudo-terminal
  (`script -q /dev/null`). It shows the CLI's plan event, checks every confirmation against that plan and asks
  for Touch ID before typing it. The CLI stays the authority; the app is a convenience, not a boundary against
  an agent running as the same user. `GuardrailsCore` holds the testable parts; `app/build.sh` writes the kit
  path into Info.plist, signs and installs `~/Applications/Guardrails.app`.
- `hooks-global/` user-level hooks installed into `~/.claude/settings.json`. They act only in kit
  repositories (`.agent/bin/ci-guard` exists or the origin is an enforced repo) and on commands that name an
  enforced repo: `bash-guard.sh` blocks owner-only GitHub actions and credential reads, `prompt-reminder.sh`
  adds a one-line reminder per prompt. Everywhere they block the owner's commands and the enforced-repo list.
  `agent-identity.sh` (SessionStart, and PreToolUse Bash to renew) points a kit repository's session at a
  one-hour token of the agent App through `CLAUDE_ENV_FILE` (`GH_CONFIG_DIR`, git helper and SSH-to-HTTPS
  rewrite), so gh and git push run as the App's bot; it fails closed when the App is installed but no token
  can be minted. `kit-project.sh` (sourced by the hooks and `bin/guardrails`) decides what counts as a kit
  repository.
  Other agents reuse bash-guard, the single source of truth for what is blocked: `cursor-guard.sh` translates
  Cursor's `beforeShellExecution` and `beforeReadFile` (registered in `~/.cursor/hooks.json`), and Codex runs
  `bash-guard.sh` and `prompt-reminder.sh` unchanged from `~/.codex/hooks.json` (same input as Claude Code).
  Neither gets the agent identity; README "Supported agents" says what each agent enforces.
- `README.md` is for people installing and using the kit; this file is for working on it.

## Commands

- Install: `./install.sh` from a clone nobody develops in (symlinks skills into `~/.claude/skills`, registers
  global hooks, also in `~/.cursor/hooks.json` and `~/.codex/hooks.json` when those directories exist, links the
  owner commands onto PATH; idempotent, moves links over from another kit clone, backs up every hook file
  before changing it). `tests/install.sh` runs it in a throwaway HOME. The state-changing owner commands (`on`, `off`, `approve`,
  `approve-head`) refuse to run from a clone with local changes or not at its origin's main.
- Check: `make check` (= shellcheck + the offline tests in `tests/`). The security scanners themselves run only
  in CI (Linux x86_64); validate workflow edits with `actionlint`.
- Language adapters: `make test-lang` (slow; real mini projects per language). `tests/lang/run.sh <lang>` fails when
  a tool of that language is missing; without arguments it skips such languages. CI runs one job per language in
  `.github/workflows/language-adapters.yml` on PRs and pushes to main that touch `skills/guardrails-init/`,
  `tests/lang/` or the workflow, and before every release (`release.yml` calls it).
- Release: raise `VERSION` (semver) and move the `Unreleased` entries of `CHANGELOG.md` under that version in
  the same PR; after the merge `.github/workflows/release.yml` tags `v<VERSION>` and publishes the section as the
  release notes. Changes worth a note go under `Unreleased` in their own PR.
- App release (owner, macOS): `make app-release` (Developer ID signing, notarization with the notarytool
  profile `guardrails-notary`, upload to the GitHub release of `VERSION`).
- App: `make app-test` (core tests), `make app` (build and install from the kit install; needs Xcode 26+).
  Rebuild the app after a kit change that touches `app/`.

## Gotchas

- Scripts must stay Bash 3.2 compatible (macOS `/bin/bash`): no `mapfile`, no associative
  arrays, no expanding possibly empty arrays under `set -u`.
- `grep -q` in a pipeline under `pipefail` can report SIGPIPE as failure; use `grep ... >/dev/null`.
- Pattern files (`write-allow`) are bash globs where `*` also matches `/`.
- Workflow checks go into `check.py` over the parsed workflow, never as regexes over its lines. It must stay
  Python 3.8 compatible (the owner's Mac has 3.9), standard library plus `guardrails_pyyaml` only, and never
  write bytecode: a `__pycache__` in the template shows up as kit drift in every project. The pytest plugin
  (`test-support/pytest_integrity.py`) runs on the project's Python and must parse as 3.9; `tests/smoke.sh` parses
  both files with their oldest grammar, since CI's Python is newer. A Python project's mutation gate (`make ci`,
  `make mutation`) still needs 3.11: `mutants-mutmut-run` checks the mutmut configuration with `tomllib` on the
  project's interpreter. Running the plugin locally writes a `__pycache__` next to it: delete it before committing.
- Hooks are a fast local layer only; Bash can bypass them. `ci-guard`, run from the base branch
  via `pull_request_target`, is the authority. The same holds for the Cursor and Codex hooks.
- A new kit file in projects (like `.cursor/hooks.json`) goes into `kit_drift`, `remove_kit_files`, the kit-file
  list of `guardrails on` and, if it is a guardrail, `changes_enforcement` (the `!!` marker) and write-guard.
- Every kit merge reaches the owner through `guardrails update` (the app's Update button): it fast-forwards
  the install clone to the confirmed commit, runs `./install.sh` and rebuilds the app. Until then the owner's
  state-changing commands refuse to run. bash-guard blocks the agent from the update and the install clone.
- bash-guard reads every line of a command, heredoc bodies included: write text that names the owner's
  commands with the Write tool, not a heredoc.
- A project's PRs are judged by the `ci-guard` of its default branch, so a kit change that a project's old guard
  would reject (like a new `agent-guard.yml` trigger) reaches projects in two PRs: first the guard that accepts
  it, then the change. Say so in README.
- On merge_group GitHub runs the group's own `agent-guard.yml` steps against the default branch's
  `ci-guard-group`, so its call stays `ci-guard-group "$GITHUB_EVENT_PATH"` and the script reads everything else
  from the event payload; changing that call would fail every group, its own update too.
- The merge queue cannot be tested offline or on a personal repository: GitHub offers it only to organization
  repositories.
- A spec lock must be exactly what `spec-lock` writes: the five metadata files and every `locked-files` entry, once
  each, by plain repository-relative paths. `lib.sh` holds the checks (`locked_files_problems`, `manifest_problems`)
  that `spec-lock`, `lock-verify` and both guards (`guard_lock_manifests`) share. A lock may not disappear; a re-lock
  that covers other files than the base passes and is listed under "SPEC LOCK SCOPE CHANGED" for the owner.
  `tests/spec-lock.sh` runs these cases through `ci-guard` and `ci-guard-group`. A project whose existing locks break
  these rules (a duplicate or `./` entry in `locked-files`) sees its kit update PR fail `lock-verify-all` in its own
  checks; it re-locks those tickets, one PR each, before taking the update.
