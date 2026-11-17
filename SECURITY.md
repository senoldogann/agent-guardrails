# Security policy

agent-guardrails decides whether an AI agent's work can merge, so a way around it is a security issue.

## Reporting

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Please do not open a
public issue. Include the version (`guardrails version`), whether the repository was in status or review mode,
and the steps that show the bypass. You can expect a first answer within a week.

## In scope

- Merging into an enforced repository's default branch without the owner's approval of that exact commit, or
  with a failing or skipped `guard` or language check.
- Changing what `ci-guard` judges from inside a PR: locked spec files, tests, workflows, the guard itself.
- An approval made in the app or with `guardrails approve` that applies to a different commit than the one shown.
- The agent App's token reaching beyond its repository or its permissions (contents and pull requests).
- Code execution from data the kit reads: PR titles, branch names, file names, commit messages.

## Known limits (not vulnerabilities)

These are documented in the README's security model:

- In status mode the agent works with the owner's GitHub login. `bash-guard` matches command text and can be
  evaded by a deliberately disguised command; it guards against mistakes, not an adversary.
- While the agent runs as the owner's computer user, it can reach the owner's own credentials in review mode too.
- Repository administrators other than the owner can change the rulesets.

## Supported versions

Fixes go into the latest release only.
