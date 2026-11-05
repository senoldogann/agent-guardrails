
## Agent guardrails

Deterministic checks and the owner's approval decide whether work is done, not the agent.

- Command contract: `make check` (full gate, logged to `.agent/reports/<ticket>/checks.log`),
  `make check-spec` (spec gate), `make ci` (what CI runs), plus `typecheck lint fmt-check test-ids test test-prop`.
- Ticket flow, one PR per ticket on `feat/<ID>-<slug>`:
  1. `/ticket-spec <ID>` → draft PR with contracts, stubs, locked tests (`AC-<n>` in test names), spec files.
  2. The owner answers `specs/<ID>/OPEN_QUESTIONS.md` and reviews the spec; the agent locks it (`spec-lock`).
  3. `/ticket-implement <ID>` → implementation in `specs/<ID>/write-allow` paths only.
  4. The owner approves the exact HEAD with `approve-head <PR link>` in their own terminal (commit status
     `merge-approval`); nothing merges without it, and every new push needs a new approval.
- Locked files (`specs/<ID>/spec.lock`, test IDs in `tests.lock`) change only by re-locking in a reviewed PR.
- Human-owned, never edited by agents during a ticket: `.agent/`, `.claude/`, `.github/`, `specs/`, tests,
  configs, manifests, lockfiles, dotfiles, `AGENTS.md`, `CLAUDE.md`, `Makefile`.
- A check that looks wrong is reported (`.agent/bin/block "<question>"`), never changed, loosened or skipped.
- Every question to the owner names the recommended option first, with the reason and the evidence behind it.
- Knowledge the team needs (conventions, gotchas, commands, decisions that hold) goes into this file, skills
  or checks through a reviewed PR. Only personal preferences live in local memory (`CLAUDE.local.md`,
  `~/.claude`), which is git-ignored and never the only place a team rule exists.
- Repeated agent mistakes are fixed in context or checks via `/process-fix`, not by hand-editing code or docs:
  ask the agent why it happened first.
- Agent identity: the agent works with the owner's GitHub account. The global bash-guard hook blocks
  approvals, admin merges, settings changes and credential reads; the ruleset makes every merge wait for the
  owner's `merge-approval`. Accepted risk: bash-guard matches command text, so a deliberately disguised
  command could still act as the owner. The optional hardening is a fine-grained token for this repository
  only (Contents, Pull requests, Issues read/write; Actions, Commit statuses read; never Commit statuses
  write, Administration, Workflows, Deployments, Environments, Secrets, Variables or Webhooks) set as
  `GH_TOKEN` in `.claude/settings.local.json` with an HTTPS remote and `gh auth setup-git`; GitHub then
  refuses those actions itself.
- This file describes current state only; history lives in commit and PR messages.
