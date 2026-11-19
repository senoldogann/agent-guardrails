# Pilot brief

A founder-assisted, paid pilot to find out whether agent-guardrails is worth more to a team than it costs them. It is a plan, not a result: no customer has run the kit yet, and every threshold below is a proposal to agree on before the pilot starts.

## Hypothesis

GitHub teams that already let coding agents open pull requests are bottlenecked on review. They will spend less total human time per merged change, and trust the result more, when a human locks the spec and tests up front and approves an exact commit that deterministic checks have judged, than when they review agent PRs line by line.

## What the kit can promise

For a repository turned on in review mode, on the default branch:

- **Exact head.** No PR merges unless the default branch's guard and the required checks passed on its exact head commit.
- **Locked contract.** The agent cannot change the locked spec and tests of a ticket without the guard failing or showing the change to the owner. A new lock that drops a protected file is listed for the owner.
- **Exact-commit approval.** A human approves the exact commit, and a new push needs a new approval. The approval shows the files of exactly that base and head, and changes to guardrail files need a second confirmation.
- **Detected weakening.** The owner's inbox raises an alarm when the rulesets stop protecting the default branch. Causes include a ruleset that is disabled, retargeted, excluded, missing a rule, or carries an extra bypass actor.
- **Visible exceptions.** Merges that skipped an approval are visible afterwards (`guardrails report`).

## What it does not promise

- **Business correctness.** The checks prove the code meets the spec the team locked, not that the spec is right.
- **Isolation from an agent running as the same computer user.** Local hooks and the app are conveniences, not a boundary. The README's "Security model and limits" section is the reference.
- **Protection in status mode against a deliberately hostile agent.**
- **Protection against repository administrators.** They can merge without review in review mode, and can change or remove rulesets. The kit detects and reports this; it does not prevent it.
- **A measured security improvement.** A pilot of a few teams cannot establish one statistically, and no claim of that kind will be made from it.
- **Equal support for every agent.** Cursor and Codex get the shell-command guard only; Claude Code gets the full set.

## Who the pilot is for

Three to five independent teams, each with:

- 2–8 developers already using Claude Code on a GitHub repository, with review as the stated bottleneck;
- one designated owner on macOS who holds repository admin and approves;
- a repository whose new work is mostly domain logic in TypeScript with pnpm, or Python with uv;
- organization repositories in review mode, with the agent's GitHub App installed.

Leave out repositories that would mostly measure the kit's friction rather than its value:

- **Existing code that clashes with the kit's checks.** Existing `src/` code that is heavy on I/O or async code, which the kit's lint rules restrict.
- **Pipelines that break under `guardrails on`.** Existing CI that depends on actions pinned by tag, or on a default token that can write.
- **Branching the kit does not support.** Hotfix or release branches that must merge outside the default branch.
- **Unsupported languages or layouts.** Languages beyond those above, polyglot monorepos, or teams on Windows.

## Format

- **Duration:** six weeks per team.
- **Price:** a paid pilot at a fixed fee agreed up front. A small fee is enough to test willingness to pay; the fee is not the point.
- **Week 0:** the founder installs with the team on a call and records the time taken. Together they pick 10–20 upcoming tickets of comparable size from the team's backlog.
- **Weeks 1–4:** the team works with the kit, and the founder answers support requests.
- **Weeks 5–6:** the founder steps back and answers only blocking defects. Whether the team keeps using the kit without help is part of the result.
- **Release freeze:** kit releases are frozen during each pilot, except fixes for blocking defects. Every release costs each team a kit update.

## What to measure

The measurement is manual, through a shared sheet per team. It needs no telemetry or backend. For every ticket, record:

| Measure | How |
|---|---|
| Human time per ticket | Minutes spent on the spec, answering questions, amendments, review and approvals, each logged by the person who spent them |
| Elapsed time | Ticket start to merge, and ready-for-review to approval (`guardrails report` gives the second) |
| False blocks | Every time a check or the guard blocked work the team judged correct, with the rule that fired and the minutes lost |
| Repeated approvals | Approvals needed per merged PR (`guardrails report` counts re-approvals after a push) |
| CI runtime and cost | Actions minutes per merged PR, from the repository's billing usage |
| Escaped defects | Defects found after merge in work done under the kit, against the baseline |

Per team, record:

| Measure | How |
|---|---|
| Installation effort | Founder and team hours to get the first repository turned on |
| Ongoing support | Founder hours per week, with the cause of each request |
| Unassisted use | Tickets done under the kit in weeks 5–6 without founder help, as a share of the team's agent tickets |
| Willingness to pay | Whether the team pays the pilot fee, and whether it signs up for continued use at a stated price |

## Baseline

The comparison is against similar work in the team's existing process, not against an idealized one:

- Before the pilot, each team logs the same human-time and defect measures for 5–10 recently merged agent PRs of comparable size, reconstructed from PR history with the people involved.
- During the pilot, where practical, the team alternates comparable tickets between its usual process and the kit, with the same logging. Without that alternation, the comparison is weaker, and the report must say so.

## Decision criteria

These thresholds are proposals to agree before the pilot starts. They are not evidence.

- **Continue:**
  - in at least two teams, median human time per ticket is no worse than the baseline, and at least 25% lower on the tickets that fit;
  - no team reports a merge that bypassed the guard or checks without the kit showing it;
  - false blocks average under one per ticket by week 4;
  - at least two teams keep using the kit in weeks 5–6 without founder help;
  - at least two teams agree to pay to continue.
- **Narrow:** the value holds only for some kinds of work or repositories, for example new domain logic but not changes to existing code. Restrict the product and its claims to that segment and run a second pilot there.
- **Stop or rethink:** stop investing in the product as it is if any of these holds:
  - human time is higher than the baseline in most teams;
  - support stays above about four founder hours per team per week after week 2;
  - no team will pay to continue.
