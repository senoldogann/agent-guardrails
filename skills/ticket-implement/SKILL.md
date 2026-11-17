---
name: ticket-implement
description: Implement phase for a ticket whose spec is locked and reviewed - write only write-allowed implementation files until every deterministic check passes, then hand the PR to the owner for merge approval. Use when the user runs /ticket-implement <ID>.
argument-hint: <TICKET-ID>
disable-model-invocation: true
---

# Implement ticket $ARGUMENTS against its locked spec

## Rules

- Never change, loosen, skip or delete tests, contracts, specs, configs or checks; never touch test runners,
  global test state, process exit or dynamic imports from implementation code. The write-guard blocks file edits,
  lint rules block the constructs, and the owner reviews every diff before merge.
- If a test, type or check looks wrong, or a requirement is ambiguous: `.agent/bin/block "<question>"` and stop.
- No type escape hatches. Follow `AGENTS.md` and existing conventions; pure domain logic, effects at the edges.
- Never approve, admin-merge or change repository settings; those belong to the owner.

## Steps

1. Read `AGENTS.md`, `specs/<ID>/` (criteria, properties, decisions, write-allow) and the locked tests/contracts.
2. Check out the ticket's branch (`feat/<ID>-...`, which has the reviewed spec) and run
   `.agent/bin/start-implement <ID>`. If it fails (undecided question, broken lock), report and stop.
3. Implement in write-allowed files only. Run `make check` and iterate on the implementation until it passes.
   The Stop hook re-runs it and will not let you finish while it fails.
4. Commit (Conventional Commits), then `.agent/bin/finish`: it runs `make check` on the committed HEAD and logs
   it under the ticket, so `.agent/bin/report-checks <ID>` can prove the evidence matches what you push.
   Then push, mark the PR ready (`gh pr ready`), enable auto-merge
   (`gh pr merge --auto --squash`). It merges only after CI is green and the owner approves that exact HEAD.
   Do not push after asking for approval unless asked: a push invalidates it.
5. Post a PR comment for the owner, in plain language (`gh pr comment --body-file`). If the session start
   said gh runs as the agent App's bot (review mode): `Ready for your review: approve it on GitHub, or in
   your own terminal run: approve-head <PR URL>`. Otherwise: `Ready for your approval. In your own terminal
   (not the agent's) run: approve-head <PR URL>`. The owner's `guardrails` inbox lists the PR as well.

## When the mutation gate fails

CI mutates the changed source and requires every mutant to be killed by a locked test. A survivor means the
locked tests miss a behaviour: do not change the implementation to dodge it. Run `.agent/bin/block` with the
surviving mutants and ask the owner for a spec amendment, or, if a mutant is provably equivalent, for an entry in
`specs/<ID>/mutants-accepted` (`<fingerprint>  <file>  <reason>`; the owner writes or approves it).

## Report (PR comment and final message)

```
## Changes made
## Checks and results        ← link the PR's CI run; paste `.agent/bin/report-checks <ID>` verbatim (never write "passed" by hand)
## Open questions
## Risks the checks do not cover   ← security, data integrity, migrations/rollback, performance, concurrency, observability
## Maintenance notes          ← new dependencies and why, rewrites, architectural fit, follow-ups
```
