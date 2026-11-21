# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/). A release is cut by raising `VERSION` and moving the
`Unreleased` entries under a heading for that version; merging that to `main` tags and publishes it.

## [Unreleased]

### Changed

- A pull request's review is one board. The chain of gates — spec, guard, checks, approval, merge — is drawn
  as a rail at the top of the window, filled where it is proved, ringed where the owner stands and red where it
  is broken. The evidence sits on the left; the commit the approval lands on, with the one Approve button
  (`Approve c4a1f2e`), sits on the right. The bottom action bar is gone for pull requests.
- The tab strip is gone. What the window shows lives in the sidebar, where the queue already was: the browse
  pages, then **Open** with every page open right now and a close button on hover, then the repositories. `⌘K`
  opens one field over the pages, the repositories and the open pages.
- A repository page opens with the same chain the review board draws, one level up: kit, ruleset, approval, and
  the merge queue where the repository has one.
- Reports start with the window's totals — merges, failed runs, re-approvals, merges without an approval — and
  each merge without an approval on its final commit opens its pull request.
- When sensitive files change, the review's primary button is now "Open changes on GitHub" until the diff is
  opened, then Approve. Before, Approve stayed disabled with only a small gray hint. Approve is also disabled
  once GitHub reports a newer commit than the one under review.
- An alarm in the menu panel has a Restore… button that shows the turn-on plan. Inbox rows use secondary
  buttons, and diffs show deletions in neutral gray, because red in the app means a problem.
- A repository whose default branch has no security workflow yet is a note pointing at the kit update PR, not
  an alarm. With the workflow there, a ruleset without the security check is still an alarm.
- `guardrails on` without a target says what it needs instead of printing the whole usage.

### Fixed

- `guardrails on` switching a repository from status mode to review mode replaced the branch ruleset, dropping
  merge-approval, before it created the review ruleset. If GitHub refused that second write, or the command
  was stopped in between, the repository was left with no rule that required the owner's approval. The review
  ruleset now goes in first, as merge-approval already did when a repository leaves review mode, so an
  approval rule holds after every step. A stop now prints which rules are on and the command that finishes the
  change. After a failed bootstrap merge, the retry line now repeats the flags the owner gave; before, it
  named only the link.
- The review board showed "Guard failed" for a guard run that a newer run had cancelled, while the CLI and the
  approval go by the newer run. It now reads the guard as the CLI does (the run named exactly "guard", a real
  failure first, else the newest run), counts a rerun check by its newest run, and lists a replaced run as
  replaced; the pull request window no longer counts such a cancelled run as failing, and the inbox's checks
  note counts a rerun by its newest run too. A bootstrap PR's chain no longer waits for a guard that cannot
  run before the turn-on, and a failing check there is shown as a reason to look before turning on, not as a
  stop. An enforced repository with an inbox alarm about it (such as a disabled review ruleset) is shown as an
  alarm everywhere: its page, with Restore and without the "status mode" card or Switch to review mode, the
  sidebar and the overview. After a run, only the merge can still be listed as missing, and the checks line is
  gone. An own merge or a turn-on now shows that GitHub recorded no review. The approval's success text no
  longer promises a merge that only auto-merge makes, and the Reports row is now called "Without an approval".
- In a Python project on Python 3.9 to 3.11, every `make test` failed before any test ran: the kit's pytest
  plugin used Python 3.12's `type` statement, and the language adapter tests only ran 3.12. It now loads on
  3.9 and newer, so Python 3.11 projects pass the whole gate; on 3.9 and 3.10 the mutation gate still needs
  3.11 (`tomllib`). The smoke test parses the kit's Python files with their oldest supported grammar.
  `finish`, `start-implement`, `spec-lock` and `ci-run`, run by a relative path from a subdirectory, no longer
  fail to find the scripts next to them, also with `CDPATH` exported. Projects take both fixes with their next
  kit update.
- A repository page in alarm drew its chain as enforced: the ruleset filled in as "protected", and the
  approval as done. The alarm can mean the ruleset is disabled or missing, or that GitHub cannot read the
  repository, so the chain now marks the ruleset broken ("alarm: not confirmed") and the kit and approval
  unknown, with a dashed ring, until the alarm is fixed. A repository a teammate enforces from another Mac no
  longer reads as off ("not installed", "stays open"): its links are unknown here.
- A repository page drew an enforced repository as fully protected before the app had read the inbox, after
  an inbox read had failed, and when the last read did not cover the repository, although only the inbox reads
  every kit ruleset and would show a disabled review ruleset as an alarm. Until the inbox's last read succeeded
  and covered the repository, its chain now reads "waiting for the inbox", its card claims no protection, and
  the menu bar shows a plain shield. The waiting count on a repository, its activity and its pull request
  list missed what came under its name in another case than the projects list's; names are now compared
  without case, as GitHub compares them.
- The review board said "Every check the kit runs passed" when some runs were skipped or neutral, and "No
  checks reported" while checks were still running, still loading or could not be read. It now says passed
  only when every run passed, names skipped and neutral runs (also in the Checks list), and keeps running,
  loading, unreadable and empty apart; a failure still comes first. The approval and merge links follow the
  action: right after the confirmation for `on` and for the owner's own merge, through the merge queue for a
  queued PR, and auto-merge or a person for any other approval. After a success they show what happened; after
  a failed run they claim nothing.
- `guardrails report` counted any review still in the approved state as an approval of a merged PR, whatever
  commit it approved. A PR whose only approval was of an earlier commit (in status mode, where pushes dismiss
  no review, or after a push that did not dismiss it) did not appear under merges without an approval on the
  final commit. A review now counts only when it approves the PR's head commit (`headRefOid`, now part of the
  report's query), and so does a merge-approval status. The final commit is that head, not the last commit
  GitHub happens to list.
- In a Python project, `make lint` failed on the kit's own `.agent/workflow/check.py`: `escape-check` found
  its `# noqa: E402` comments. The file now needs no suppression, and the smoke test runs `escape-check` in
  every language over the kit's own files.
- A command that runs past the app's time limit is now always followed by SIGKILL to its whole process group
  after the grace. Before, SIGKILL was skipped once the output streams ended, so a child in the group that
  ignored SIGTERM and let go of its output kept running after the timeout.
- `docs/pilot.md` no longer says that the checks prove the code meets the locked spec. A green run records
  that the evaluated commit passed the locked tests and configured checks; it does not prove complete coverage.
- `guardrails off` prepared its removal plan, before the owner's confirmation, by editing files in a fresh
  clone of the repository with `AGENTS.md.tmp` and `Makefile.tmp` beside them, following any symbolic link the
  repository held. A link to a file outside the clone let that preparation rewrite or delete the file, even
  when the owner then cancelled. The removal is now staged in the clone's index only: blobs are read by object
  id, edits are written as new blobs, links are removed or kept as links and never followed, and no temporary
  file is made. A linked `AGENTS.md`, `Makefile`, `.claude` or `.cursor` is kept and named in the plan. Errors
  while preparing the plan now stop `off` before anything is pushed; before, they were ignored. The clones
  `on` and `off` make run no git hooks, whatever the owner's git settings install (a hooks path, a template
  directory or hooks defined in git config), and `off` commits exactly the planned tree, signed when the owner's
  git signs commits, so a hook can neither run the repository's code before the confirmation nor change the
  pushed removal.

### Security

- bash-guard let several plain commands past its checks in kit repositories, and Claude Code's file tools past
  it entirely. Now refused:
  - a gh call nested in another's arguments (`$(gh pr review --approve)`, backticks, `<(…)`);
  - a variable or command substitution in a gh merge, edit, auth or api call;
  - checked flags in other spellings (`--base=x`, `-Bx`, `--admin=true`, `-fbody=x`, `-ht`), and flags on a
    continuation line (a line ending in `\`); gh spelled `GH`;
  - commands that drop the session's identity so gh and git fall back to the owner's login (`env -i`,
    `env -`, `/usr/bin/env -i`, `exec -c`, clearing `GIT_CONFIG_*`, tmux, screen, cron and launchd jobs, a new
    Terminal, osascript's `do shell script`, ssh to this machine), also after `X=1`, `if`, `{`, in a
    here-string or in text piped to a shell;
  - git settings passed with `git -c`, `git --config-env`, `git config` with a value, or through
    `GIT_CONFIG_*` and `GIT_SSH*` (set, cleared, read with `read` or `for`, or printed), including a remote's
    URL, push URL and push target, a branch's remote and aliases (which can run a shell); git's own options
    before the subcommand (`git -C . push origin main`);
  - the same commands behind a wrapper with arguments of its own (`nice`, `timeout 60`, `exec -a x`), after a
    leading redirection or in a `case` arm, and in another kit repository than the session's
    (`git -C <repo>`, `cd <repo> &&`);
  - printing the environment (`export`, `declare -x`, `env` without a command, `ps e`, interpreters reading
    it);
  - an owner command run by a reader as its pager or filter (`git grep -O'…'`, `rg --pre`, `git --output`);
  - changing the user's hook registrations or their directories, or `disableAllHooks`, from the shell, in any
    spelling the shell reads the same: `$HOME`, `..`, `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, quotes, a glob,
    brace or variable in the name, a `cd` or `-C` out of the project, a recursive copy, sync or archive into
    such a directory or the home directory, an interpreter given it; and running an agent with another
    `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Reading them stays allowed, with readers that cannot write (not `sed`
    or `less`). A project's own `.claude/settings*.json` stays writable from the shell (git restores it, the
    kit copies it).

  These rules match a command where it runs, not a word in a commit message, a title or a remote command:
  "add CSV export", "GH Actions", "only if set", `fix(env)`, `git switch -c fix/credential-rotation`,
  `git -C dir`, ssh port forwards and `rg GIT_ASKPASS` stay allowed. A line that only looks continued is
  matched as written too, so it cannot join the next command to its own. A hook input whose command or path is
  not a string is refused.
- bash-guard runs with `bash -p`, so the environment cannot make it source a file first (`BASH_ENV`), and it
  allows a call only through an explicit allow: on macOS's Bash 3.2 an internal error, even a fatal one, used
  to end with status 0 and let the call through. A git that fails for any reason other than "not a git
  repository" counts as a kit repository, so the full rules stay on.
- In Claude Code, bash-guard now also checks the file tools (Read, Grep, Glob, Edit, Write, MultiEdit,
  NotebookEdit) by the path, with `x/..` resolved as Claude Code resolves it, every link resolved (a relative
  link from its real directory), `~` expanded, and places compared by file identity, so another spelling of
  the same place (another case on macOS, the `/System/Volumes/Data` firmlink) counts. An edit of a hook
  registration is replayed on the file, and refused when its `old_string` is not in the file as written (the
  Edit tool also matches curly quotes for straight ones):
  - none may read or write `~/.config/agent-guardrails` (the enforced repositories and the agent App's private
    key), and no Grep may search it or a parent directory;
  - no write may go into the kit install;
  - a write to the user's hook registrations (Claude Code's settings, also under `CLAUDE_CONFIG_DIR`, and
    Cursor's and Codex's `hooks.json`, also under `CODEX_HOME`) must leave every kit hook entry as it is and
    parse as the agents parse JSON (jq accepts `NaN`, which would make them ignore the file, hooks and all);
  - no file may be written as JSON that sets `disableAllHooks` (a copy from the shell could make it settings);
  - in kit repositories, credentials are refused at their real place (gh's config directory, git's credential
    stores, `~/.netrc`, Claude Code's local settings), not in any file of the same name.

  Run `./install.sh` (Update does) to register these hooks.

## [0.6.0] - 2026-11-19

### Added

- The README describes how a project takes a new kit: which template files to copy, why
  `agent-guard.yml` follows in its own PR, and how to check that nothing still differs.
- CI runs the real language-adapter tests for every supported language on PRs and on `main`, and before each
  release.

### Changed

- The README no longer says that nothing merges until the human approves the exact commit without naming
  the exceptions. It now states what approvals on github.com or GitHub Mobile skip in review mode, and that
  administrators (including the owner for their own PRs and for Cursor or Codex PRs) can merge without a
  review. `docs/pilot.md` holds the pilot brief: the promise the kit can back, what it does not promise, what
  to measure and the proposed decision thresholds.

### Fixed

- A ruleset exclude pattern that matches the default branch in another case (`refs/heads/MAIN` for `main`) now
  counts as excluding it: the inbox raises an alarm and approvals no longer trust that ruleset. Include
  patterns still count only with the same case.
- Organization repositories are no longer invisible before they are enforced:
  - The inbox offers turn-on for the owner's bootstrap PRs in any repository the owner administers.
  - The inbox raises an alarm for any repository this Mac enforced that dropped out of its list, whoever owns it. A new `enforced-history` file next to the list records what this Mac enforced and did not turn off.
  - The app's project list shows the 25 most recently pushed organization repositories the owner administers, plus every repository this Mac enforced or with the owner's bootstrap PR.
  - A repository a teammate enforced from their own Mac shows under "Enforced elsewhere" for information, never as an alarm.
- The inbox and project list fail with an error when GitHub's search answer lacks its results or holds fewer
  results than its total, instead of reading it as "nothing found".
- `guardrails approve` shows which files a re-lock of a spec lock stops or starts locking, read from both
  versions of the lock. It asks a separate `unlock` confirmation for every dropped file, and the app shows
  both in the plan.
- In review mode, `guardrails approve` reads GitHub's push log to detect when your account made the newest
  push to an agent's PR. GitHub would never count your review then, so it merges the whole PR through your
  admin bypass, pinned to the confirmed commit. It names that push (account, commit, time) before you confirm.
  Before, it posted a review that left the PR waiting.
- `guardrails on` no longer switches a repository from review mode to status mode on a Mac without the agent
  App. It refuses and says what to do. `--status-mode` makes the switch on purpose.
- The guard and the merge queue guard reject a spec lock that is not exactly what `spec-lock` writes: an
  empty, malformed or duplicated manifest, a path outside the repository, a missing metadata or locked file,
  or a lock that disappears. A re-lock that changes which files are locked passes as an amendment and is
  listed for the owner under "SPEC LOCK SCOPE CHANGED". `spec-lock` and `lock-verify` check the same locally.
- `approve-head` and `guardrails on <PR>` show the files of exactly the base and head they read, so a push
  during the review can no longer swap the list. A PR whose file list GitHub may have cut off (300 files or
  more) is refused, and the approval writes nothing if the PR moved. A project whose existing spec locks are
  not what `spec-lock` writes must re-lock them before updating, because its update PR's checks fail
  otherwise.
- The guard summary drops control characters and backticks from the accepted-mutant lines a PR adds, as it
  already did for accepted security findings, so a reason cannot close the summary's code fence and hide the
  sections after it.
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

[Unreleased]: https://github.com/senoldogann/agent-guardrails/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/senoldogann/agent-guardrails/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/senoldogann/agent-guardrails/releases/tag/v0.1.0
