# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/). A release is cut by raising `VERSION` and moving the
`Unreleased` entries under a heading for that version; merging that to `main` tags and publishes it.

## [Unreleased]

### Changed

- The README no longer says that nothing merges until the human approves the exact commit without naming
  the exceptions. It now states what approvals on github.com or GitHub Mobile skip in review mode, and that
  administrators (including the owner for their own PRs and for Cursor or Codex PRs) can merge without a
  review. `docs/pilot.md` holds the pilot brief: the promise the kit can back, what it does not promise, what
  to measure and the proposed decision thresholds.

### Fixed

- The guard and the owner's approval read workflow files with a real YAML parser (vendored PyYAML 6.0.3
  scanner and parser, run as data with `python3`) instead of line regexes. Escaped or quoted spellings of
  `checks`/`statuses` write, `write-all` and reserved job names are now caught, and duplicate keys, anchors,
  aliases, merge keys, tags, multiple documents and non-scalar keys fail closed. `python3` 3.8 or newer is now
  required for the owner's commands.
- The inbox and `guardrails approve` notice when a ruleset stops protecting the default branch. Each of these
  raises an alarm:
  - a branch or review ruleset that no longer targets branches;
  - one that no longer covers the current default branch: its `ref_name` conditions were retargeted or exclude
    the default branch. Patterns that GitHub and the kit could read differently count as excluding it;
  - a tag ruleset that no longer covers every tag, or that lost its creation, update or deletion rule;
  - a bypass list other than the one `guardrails on` applies.

  Approval mode applies the same rules, so `guardrails approve` refuses while the rulesets do not protect the
  default branch.
- The app's command timeout now always ends. A timed-out command and its process group get SIGTERM, then
  SIGKILL after a short grace, and the app stops reading output that an escaped child process keeps open.
  Before, a command that ignored SIGTERM, or a background child holding its output, could keep a refresh
  waiting indefinitely.
- README, AGENTS.md, the project AGENTS section and the ticket-implement skill now describe the stop-check
  hook exactly. It sends the agent back while checks fail, and after three failures in a row it lets the agent
  stop with a warning. It is a local convenience; GitHub's guard, required checks and approvals decide what
  merges.

## [0.5.0] - 2026-11-19

### Added

- Opt-in GitHub merge queue for organization repositories in review mode: `guardrails on <owner/repo>
  --merge-queue`, or **Turn on merge queue** in the app.
  - The queue is squash-only, every PR must pass every check, and groups are small.
  - A plain `on` keeps the queue, `--no-merge-queue` removes it, and the inbox alarms when it goes missing.
  - The kit's workflows report `guard`, `security` and the language checks on merge groups. The guard uses
    the default branch's new `ci-guard-group`.
  - Queued PRs no longer show as waiting for approval.
  - Existing projects take the update in two PRs: first everything except `agent-guard.yml`, then
    `agent-guard.yml`.
- Team notifications: the kit workflow `agent-notify.yml` posts to a Slack incoming webhook and/or a Microsoft
  Teams Workflows webhook when a PR waits for approval, is blocked, asks a question, is approved or merged. It
  stays off until the owner adds the secret `GUARDRAILS_SLACK_WEBHOOK` or `GUARDRAILS_TEAMS_WEBHOOK`.
  `guardrails on` compares it with the installed kit like the guard workflow.
- A required `security` check in every kit project: gitleaks (secrets in the PR's commits), osv-scanner
  (known vulnerabilities in dependency lockfiles) and Semgrep CE (insecure code in changed files, pinned
  community security rules, no login). The tools are pinned and checked by SHA-256 or pip hashes. Inline
  suppressions and the scanners' own ignore files have no effect. Only a reviewed line in
  `.github/security-ignore` (marked `!!` for the owner) accepts a finding. gitleaks and Semgrep lines count
  only in the PR that adds them. Projects set up earlier need a kit
  update PR and `guardrails on <owner/repo>` again; until then the inbox shows an alarm.
- Cursor and Codex agents are guarded by the same bash-guard rules as Claude Code. `install.sh` registers the
  hooks in `~/.cursor/hooks.json` and `~/.codex/hooks.json` when those tools are set up (trust them once in
  Codex's `/hooks`), Cursor's file reads are checked for credentials, and `/guardrails-init` commits
  `.cursor/hooks.json` so teammates' Cursor agents are guarded too. Cursor and Codex work with the owner's gh
  login; the agent App identity stays Claude Code only. README "Supported agents" lists what each agent
  enforces.
- `guardrails report [owner/repo] [--days N] [--json]` and a Reports page in the app. Both are read-only and
  show, for each enforced repository over the last 7, 30 or 90 days: merged pull requests by the agent App and
  by people; median and 90th percentile time from ready for review to approval and to merge; re-approvals
  after a push; failing guard and checks runs; merges without an approval on the final commit; and every
  ruleset change with its time, author and what changed.

### Changed

- Pages are left-aligned and fill the window instead of a centered column of at most 760 points, so a
  full-screen window uses its width.
- The Code tab of a pull request starts with the number of files and lines changed and a Collapse all /
  Expand all button; each file still opens and closes on its own.
- A pull request page reads the PR again every 20 seconds while a check runs, so it shows the checks finish
  instead of "1 running" until you refresh.
- Settings is a plain button in the sidebar's bottom corner, as in Claude and Linear, instead of a list row;
  the agent App panel moved from the sidebar into Settings → Agent (its name, and Manage… or Create…).

### Fixed

- The guard fetches a PR's head commit (and a merge group's commits) with the run's read-only token when the
  default branch checkout does not already hold it, so fork PRs and private repositories are judged instead
  of failing the fetch. `make check` runs `tests/notify.sh` again; a stray line continuation passed it to
  `tests/report.sh` as an argument.
- In the Liquid Glass style a light-mode window over a dark one (or an inactive window) turned a muddy gray:
  the window material took the color of what was behind it. A light veil (dark in dark mode) now keeps the
  page clean in both modes. Borders and dividers are softer.

## [0.4.0] - 2026-11-19

### Added

- A second style in Settings → Appearance: **Solid**, flat surfaces in black and white instead of Liquid
  Glass (a near-black window in dark mode, a light gray close to white in light mode, black or white primary
  buttons). The same section chooses Light, Dark or the system's appearance for the window and the menu bar
  panel.
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

- A calmer look, after Claude, Linear and GitHub's Primer: every icon is an Octicon SVG in one color (no SF
  Symbols); green and amber are gone, and red is kept for what is wrong (alarms, failed checks, destructive
  actions); headings are small and in sentence case; every page is one centered column; rows of a kind sit in
  one container split by hairlines instead of a card each; the empty inbox is one line; the status bar sits
  flush at the bottom; repositories show their plain GitHub icon instead of a tinted tile.
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

- A push to a PR that waits for your approval notifies again: inbox items carry the PR's HEAD SHA
  (`inbox --json` has a `sha` field), so the changed PR counts as new.
- The app tells "offline" apart from "signed out" and from a login GitHub refused (expired or revoked), each
  with what to do; network errors other than DNS failures used to show gh's raw message.
- Allow… asks macOS for permission when the app was never answered, instead of opening System Settings,
  where an app that was never answered has no switch yet.
- bash-guard no longer treats a word such as `.configuration` in a command as the owner's config folder.
- `guardrails on` in status mode says how a team switches to review mode.
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

- The inbox compares each enforced repository's live rulesets with what the kit set up, not only whether the
  main one is active: a missing or inactive review or tag ruleset, a bypass list, a removed rule, required checks
  no longer pinned to GitHub Actions, other merge methods, or no rule requiring the owner's approval each raise
  an alarm.
- In a kit repository with the agent App registered, gh and `git push` are blocked when the session's identity
  was not set up for that repository (the session started elsewhere), instead of running with the owner's login.
- `guardrails update` updates only the active install (the clone whose bash-guard Claude Code runs). Updating
  another clone moved every link and hook to it; a test build of the app did that once.
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

[Unreleased]: https://github.com/senoldogann/agent-guardrails/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/senoldogann/agent-guardrails/releases/tag/v0.1.0
