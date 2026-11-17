# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/). A release is cut by raising `VERSION` and moving the
`Unreleased` entries under a heading for that version; merging that to `main` tags and publishes it.

## [Unreleased]

### Fixed

- GitHub errors no longer read as answers: an unreadable ruleset, PR list, topic search or App installation
  list now stops `guardrails`, `inbox`, `status`, `on` and the Projects window with the call that failed,
  instead of reporting a missing ruleset, an empty inbox or an App installed nowhere.
- `install.sh` checks every link it will make before changing anything, so a file in the way leaves no half
  install.
- `revoke` refuses an unreviewed kit install and the agent's environment, like `approve`.
- The agent's prompt reminder no longer says it always works with the owner's GitHub identity.
- The agent App registration waits ten minutes in total, not ten minutes per browser request.

### Added

- `agent-guardrails` is installed as a second name of `guardrails`, which other tools also use.

- `guardrails update` and the app's **Update** button: show the new commits of the kit's main, confirm the
  exact commit with Touch ID, fast-forward the install, run `install.sh` and rebuild and restart the app.
- In review mode, approving your own PR merges it with your admin bypass at exactly the confirmed commit
  (the review is skipped, the checks are not), so **Review** works for every PR.
- The Projects window shows each enforced repository's approval mode, a **Switch to review mode** button
  where the agent App is installed, a link to add a repository to the App, and an Agent identity panel that
  creates the App or opens its repository settings. `guardrails projects --json` reports `mode` and
  `agentApp`; `guardrails agent status --json` describes the App without network calls.
- `make app` signs the app with the keychain's Developer ID Application identity (hardened runtime, secure
  timestamp) and verifies the signature; `make app-release` notarizes and staples a copy for other Macs and
  attaches it to the GitHub release.

## [0.2.0] - 2026-11-17

### Fixed

- `guardrails on`, `off` and `status` clone over HTTPS with gh's credentials, so they work when gh prefers
  SSH but the machine has no GitHub SSH key, and they stop at a failed clone instead of reporting the kit
  files as missing.

### Added

- `guardrails agent create` registers the agent's own GitHub App from a manifest (contents and pull requests
  write, no workflows or administration); `guardrails agent status` shows where it is installed and flags an
  install on all repositories or extra permissions.
- In a kit repository where that App is installed, a new global hook gives each agent session a one-hour token of
  the App limited to that repository: gh and git push run as the App's bot, so its PRs can be approved with
  ordinary GitHub reviews. Run `install.sh` again to register the hook.
- Review mode: `guardrails on` on a repository where the agent App is installed requires a code owner's
  GitHub review instead of the `merge-approval` status (stale reviews dismissed on push, last push approved by
  someone else). The review lives in its own ruleset that admins may bypass through a PR; nobody can bypass
  the checks. It refuses without a CODEOWNERS whose first rule is `* @<owner>` or with errors GitHub reports.
  `guardrails approve` submits that review pinned to the reviewed commit; `guardrails revoke`
  dismisses it. `/guardrails-init` adds `.github/CODEOWNERS`.
- Every enforced repository gets a tag ruleset: only admins create, move or delete tags.
- `guardrails status` shows each repository's approval mode and tag protection; `guardrails agent status`
  lists every repository the App is installed on.

## [0.1.0] - 2026-11-17

First versioned release of the kit as it is used today.

### Added

- Spec-first workflow: `/ticket-spec` writes types, property tests, acceptance scenarios and open questions with
  recommendations; the owner locks the spec; `/ticket-implement` builds against it.
- Deterministic checks: per-project hooks (write guard, stop check), `ci-guard` run from the default branch via
  `pull_request_target`, mutation testing as a test-strength gate, language adapters for TypeScript, Python, Rust
  and Swift.
- Owner approval of a PR's exact HEAD as the `merge-approval` commit status, required by a repository ruleset.
- The `guardrails` command: inbox, turning a repository on or off, approving and revoking, status, and read-only
  JSON output for the app.
- Global hooks that block owner-only GitHub actions and credential reads in kit repositories.
- Guardrails, a macOS menu bar app: inbox, Projects window with each repository's state and open PRs, set-up
  through Claude in Terminal, and Touch ID before approvals.
- `guardrails version` and the app's version both read `VERSION`.

### Fixed

- The Projects list no longer fails with "invalid character '<'" when GitHub takes long to answer the repository query:
  smaller pages and retries with backoff.

[Unreleased]: https://github.com/senoldogann/agent-guardrails/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/senoldogann/agent-guardrails/releases/tag/v0.1.0
