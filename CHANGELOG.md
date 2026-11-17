# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/). A release is cut by raising `VERSION` and moving the
`Unreleased` entries under a heading for that version; merging that to `main` tags and publishes it.

## [Unreleased]

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

- The Projects list no longer fails with "invalid character '<'" when GitHub needs long for the repository query:
  smaller pages and retries with backoff.
