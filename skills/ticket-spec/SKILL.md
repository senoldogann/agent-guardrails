---
name: ticket-spec
description: Spec phase for a ticket - write branded contract types with throwing NotImplemented stubs, property-based and acceptance tests named by AC, and open questions, without implementing anything; ends in a draft PR the owner reviews. Use when the user runs /ticket-spec <ID> or asks to prepare the control layer before an agent implements a ticket.
argument-hint: <TICKET-ID> [ticket text]
disable-model-invocation: true
---

# Spec phase for ticket $ARGUMENTS

You prepare the control layer an implementer will be judged by. You write **no implementation**.
Requires the guardrail kit (`.agent/` exists); otherwise stop and suggest `/guardrails-init`.

## 0. Enter the phase

- Read `AGENTS.md`. Get the ticket text from the arguments or `gh issue view <n> --json title,body`.
  If it is unavailable, stop and ask.
- Branch `feat/<ID>-<slug>` from the default branch. Run `.agent/bin/start-spec <ID>`. The write-guard now lets
  you create new files and write `specs/<ID>/`; existing files are read-only (except this ticket's locked files
  when amending). Never edit `.agent/` or bypass the guard via Bash.
- Read `references/<language>.md` next to this file and follow it exactly (stub form, pinned runner
  config, AC naming, banned constructs).

## 1. `specs/<ID>/acceptance-criteria.md`

Copy the ticket's criteria verbatim as `- AC-<n>: <text>`. Do not invent criteria; gaps go to open questions.

## 2. Contracts and stubs

- Every domain concept is a brand/newtype produced only by a validating smart constructor; every invalid input
  class has a named error variant. Contract files hold types, errors and signatures (locked).
- Implementation stubs fail with a message containing `NotImplemented` (never crash the process).
- No escape hatches. If the language cannot express a guarantee, say so in open questions.

## 3. Tests (locked)

- List invariants in `specs/<ID>/properties.md`, one line each, then one property test per invariant. Cover zero,
  empty, null/None/undefined where the type admits it, boundaries and just-outside, NaN/Infinity, huge values,
  Unicode/whitespace. Constructor properties go both ways (accepts valid with value preserved; rejects each
  invalid class with its specific error).
- Acceptance: one test per concrete example, its name starting with exactly one AC reference
  (`AC-1: ...` / `test_ac_1_...` / `ac_1_...` / `ac1...`). `.feature` files are optional documentation.
- Pin runner configuration inside each test (runs, seed handling, phases) as the reference shows; no
  parametrized/each tests without explicit IDs.

## 4. `specs/<ID>/OPEN_QUESTIONS.md`

Every point the ticket leaves undecided (rounding, currency, ranges, error behaviour, overlaps, files you could not
edit). Never guess, never write the decision yourself:

```markdown
## Q1: <question>
Context: <why it matters, which AC/property it affects>
Options: <A / B / ...> (no recommendation unless asked)
Decision:
```

No open questions → the single line `No open questions.`

## 5. Lock metadata

- `specs/<ID>/locked-files`: every contract, test and support file you wrote (not stubs).
- `specs/<ID>/write-allow`: bash globs (`*` matches `/`) of implementation files only (stubs and the modules the
  implementation needs). `spec-lock` rejects patterns reaching tests, configs, manifests or dotfiles.

## 6. Hand-off

- Commit, push, open a **draft** PR (`gh pr create --draft`) titled `spec(<ID>): ...`.
- Open questions exist → run `.agent/bin/block "Please decide OPEN_QUESTIONS.md in PR #<n>"` and stop. After the
  owner answers (they edit the file or tell you), re-run `/ticket-spec <ID>` to fold decisions into contracts/tests.
- All decided → `.agent/bin/spec-lock <ID>`, then `.agent/bin/finish` (runs `make check-spec`: locked tests must all
  fail on NotImplemented), commit `spec(<ID>): lock`, push. CI runs the spec gate on that commit.
- Tell the owner the spec is ready for review. Do not start implementing in the same session.

Output: one section per file (path, purpose, summary), then the open questions.
