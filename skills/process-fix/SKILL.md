---
name: process-fix
description: Fix a recurring agent mistake at its source - ask why it happened, then improve the context (AGENTS.md, skills) or add a deterministic check, instead of hand-editing the code. Use when the user says an agent keeps making the same mistake, or runs /process-fix.
argument-hint: <description of the recurring mistake>
disable-model-invocation: true
---

# Process fix: $ARGUMENTS

A mistake that repeats is a process bug. Do not patch the code by hand; fix what led the agent there.

1. **Evidence.** Collect two or more concrete occurrences (commits, PR comments, transcript
   excerpts). One occurrence is not a pattern: say so and stop.
2. **Why.** For each occurrence, state what the agent knew and did not know at that moment: missing
   or ambiguous context, conflicting instructions, a check that did not exist, or a check that ran
   too late.
3. **Pick the strongest fix**, in this order:
   1. A deterministic check (type, lint rule, test, `escape-check` pattern, ci-guard rule).
   2. A skill or template change that makes the right path the default.
   3. One precise line in `AGENTS.md`, current state only, no history, no dates.
4. **Prove it.** Show the new check failing on the original mistake and passing on correct code.
5. **Place the learning.** Anything a teammate or another agent session needs goes into the repository
   (check, skill, template, `AGENTS.md`). Only personal preferences go to local memory (`CLAUDE.local.md`,
   `~/.claude`); a team rule that exists only in someone's memory is a defect.
6. **Propose, do not apply.** These files are human-owned (`.agent/`, `.claude/`, `.github/`,
   `AGENTS.md`, `Makefile`). Write the change as a diff, then open a PR only if the user approves;
   the CI guard requires human approval for it anyway. The reason goes in the PR/commit message, not
   in the docs.
