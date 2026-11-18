# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/). A release is cut by raising `VERSION` and moving the
`Unreleased` entries under a heading for that version; merging that to `main` tags and publishes it.

## [Unreleased]

### Added

- The Projects window opens on an **Overview**: what waits for you, with the same actions as the menu bar, and
  the enforced repositories, alarms first. ⌘R refreshes and ⌘F searches.
- Sidebar rows say why a repository needs you (its alarm, a bootstrap PR to turn on, or how many approvals and
  questions wait) instead of its last push; the group of repositories that are off starts closed, and a
  search still finds them.
- Notifications for new alarms and agent questions as well as approvals; a click opens the PR's Review window,
  the kit update, the question on GitHub, or the Projects window. They also show while the app is in front.
- The Dock icon carries the number of approvals and questions that wait, like the menu bar item.
- When macOS shows none of the app's notifications, the inbox says so, with a button to the app's page in
  System Settings.
- The Review window shows what the owner approves against, read from GitHub at exactly the planned commit:
  the size of the change, every check run (failed first, each linked), the steps each `checks-<lang>` gate ran
  and its mutation verdict from that job's CI log, and the acceptance criteria and properties of the spec the
  PR carries. The CLI's plan and the checks' own results still decide.
- An activity log of what you approved, merged, turned on or off and updated in the app, and of what arrived
  in your inbox: on the overview, on each repository's page, and in
  `~/Library/Application Support/Guardrails/activity.jsonl` (newest 500 kept once it passes 1000).
- A Settings window (⌘,): open at login, how often to check GitHub, notifications, the clones folder, the
  activity log, the version and the kit install.
- A welcome checklist at the first launch (again from Settings): kit installed, GitHub CLI signed in,
  notifications allowed, the agent's own GitHub App (recommended) and a first repository turned on, each with
  its live state and the button that does it.
- A pull request window: click a PR on a repository's page to read its description (Markdown), checks,
  comments, history and diff, and to comment, request changes, turn auto-merge on or off, convert it to a
  draft or mark it ready, close or reopen it, or copy its link, number or checkout command. **Merge…**
  appears once the head is approved and GitHub reports it mergeable, and merges exactly that commit; an
  unapproved PR offers **Review…**, which still runs `approve-head`.

### Changed

- Everything opens in one window, laid out like an editor: the sidebar shows the overview, the repositories
  and settings in the first tab; pull requests, reviews and the welcome checklist open in tabs of their own
  (⌘W closes one, ⌃Tab and ⌃⇧Tab move between them), and a status bar shows when the inbox was read and what
  waits. Settings (⌘,) is a page of this window. A review tab keeps its run while you switch tabs.
- The window is Liquid Glass: a translucent window background, glass tabs and status bar, and translucent
  cards that keep their text's contrast. Pages use up to 1040 points, so the window fills a full screen well.
- Repositories show GitHub's own icon (repository, private or fork) on a tile tinted by their state instead of
  their first letter.
- Buttons are Liquid Glass: the primary action in the app's graphite accent, so its label stays readable in
  light, dark and inactive windows; the agent panel is a glass card. The off-white page background is gone.
- Open at login moved from the menu bar panel to Settings; the panel has a Settings button instead.
- In light mode the selected sidebar row is light gray instead of near-black.

### Fixed

- Review window: "Open changes on GitHub" shows exactly the planned commit (a compare view), the size of the
  change shows only while it describes that commit, and a PR that moved after the check says so.
- Agent-written titles, labels, file names and notification texts drop invisible format characters everywhere,
  not only in the PR list.
- Cancelling a Review, or a run that stopped while Touch ID was open, no longer brings back the confirm button
  or logs a failure; closing the window after the last confirmation keeps reading the CLI, so the result is
  still logged. Writing to a CLI that already exited cannot crash the app.
- A refresh or projects load asked for while one runs now runs right after it, so an action shows up at once; a
  shorter refresh interval takes effect without waiting out the old one; commands that hang are stopped after
  five minutes.
- A PR list that cannot load says why instead of loading forever; stale repositories and the inbox's notes
  (such as an unreachable kit origin) are shown.
- One unreadable line no longer hides the whole activity log; the closed welcome window stays closed; Review
  opens a new run for a PR whose old window is still open; icon buttons have VoiceOver labels; characters cut
  between two chunks of CLI output stay whole; checks read every page, and GitHub's refusals are not retried.
- An approved PR without auto-merge said "merges when checks pass" although nothing would merge it; `guardrails
  prs --json` now reports `autoMerge` and says "auto-merge is off, so merge it yourself" in that case.
- bash-guard blocked harmless commands whose text mixed non-ASCII characters (such as `…`) with escaped
  quotes, because a UTF-8 `awk` stopped on them; it now splits commands byte by byte.

- `ci-run` no longer risks dying of SIGPIPE while it looks for a draft spec, and the kit drift check stops on
  a `diff` error instead of reporting no drift.
- `install.sh` also checks for `curl` and `openssl`, which creating the agent App needs.
- Sidebar repository names are drawn as primary text again (they were dimmer than the line below them), and
  the agent App panel shows the App's full name.
- While the Projects window or a Review window is open, the app has a Dock icon and a place in Cmd-Tab, so a
  window that went behind other apps can be brought back; with the last window closed it is a menu bar item
  again.
- bash-guard no longer blocks every command that mentions topics together with a path or repository named
  `agent-guardrails` (such as a search in the kit's own clone, or setting the kit repository's topics); it
  still blocks adding, removing or searching the `agent-guardrails` topic itself.

### Security

- The workflow permission scan (ci-guard, `approve-head`, `guardrails on`) now finds a check or status write
  grant in every one-line YAML spelling (quoted, `!!str`, flow mapping) and a write value on its own line;
  ci-guard also refuses YAML tags in workflows a PR changes, so `name: !!str guard` cannot pass as a job name.
- `approve-head` counts only a guard run of this PR into the default branch; another PR with the same head into
  a branch the agent can push to runs that branch's `agent-guard.yml`.
- `approve-head` marks guardrail files (`.agent/`, `.claude/`, other `.github/` files, Makefiles, code
  owners) `!!` like workflows and asks for the second confirmation for them too.
- The file list of a PR must be complete: a page that fails or GitHub's 3000-file cap stops the approval.
- Checking the kit install against its origin passes git the origin's URL, so the remote's settings (an
  upload program) cannot run; only an https GitHub or local path origin is accepted.
- ci-guard refuses changed file names with control characters or backticks, which could forge lines of the
  step summary.

## [0.3.0] - 2026-11-17

### Added

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
- `agent-guardrails` is installed as a second name of `guardrails`, which other tools also use.
- MIT license, a security policy with private vulnerability reporting, contributing notes, a bug report
  form, and a README that explains the flow, what the kit changes on GitHub and its security limits.

### Fixed

- GitHub errors no longer read as answers: an unreadable ruleset, PR list, topic search or App installation
  list now stops `guardrails`, `inbox`, `status`, `on` and the Projects window with the call that failed,
  instead of reporting a missing ruleset, an empty inbox or an App installed nowhere.
- `install.sh` checks every link it will make before changing anything, so a file in the way leaves no half
  install.
- `revoke` refuses an unreviewed kit install and the agent's environment, like `approve`.
- The agent's prompt reminder no longer says it always works with the owner's GitHub identity.
- The agent App registration waits ten minutes in total, not ten minutes per browser request.

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

[Unreleased]: https://github.com/senoldogann/agent-guardrails/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/senoldogann/agent-guardrails/releases/tag/v0.1.0
