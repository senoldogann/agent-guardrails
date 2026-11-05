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
   (`gh pr merge --auto --squash`). It merges only after CI is green and the owner runs `approve-head` for
   that exact HEAD. Do not push after asking for approval unless asked: a push invalidates it.

## Report (PR comment and final message)

```
## Changes made
## Checks and results        ← link the PR's CI run; paste `.agent/bin/report-checks <ID>` verbatim (never write "passed" by hand)
## Open questions
## Risks the checks do not cover   ← security, data integrity, migrations/rollback, performance, concurrency, observability
## Maintenance notes          ← new dependencies and why, rewrites, architectural fit, follow-ups
```
