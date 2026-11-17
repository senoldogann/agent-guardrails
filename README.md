# agent-guardrails

Makes AI coding agents' work verifiable. You write the spec first: types, property tests and acceptance
scenarios. The agent then works only inside that locked spec, deterministic checks (local hooks and CI)
decide when the work is done, and nothing merges until you approve the exact commit.

The kit acts only in projects you turn it on for. Everywhere else your agents work as before.

## Requirements

- macOS or Linux with `git`, `jq` and the GitHub CLI `gh`, signed in (`gh auth login`).
- [Claude Code](https://claude.com/claude-code), which runs the skills and hooks.
- A writable directory on `PATH`: `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`.
- For the menu bar app: macOS 26 and Xcode 26 or newer.
- For `make check`: `shellcheck`.

## Install

Install from a clone you don't develop in. The owner commands compare projects against this checkout and
refuse to run when it has local changes.

```sh
git clone https://github.com/senoldogann/agent-guardrails ~/.local/share/agent-guardrails
~/.local/share/agent-guardrails/install.sh
make -C ~/.local/share/agent-guardrails app   # optional, macOS: installs ~/Applications/Guardrails.app
```

`install.sh` links the skills into `~/.claude/skills`, registers the global hooks in `~/.claude/settings.json`
(after backing it up) and links the `guardrails` command onto `PATH`. It checks everything it needs before
changing anything. To update, press **Update** in the menu bar app when it offers one, or run
`guardrails update`: it shows the new commits, asks you to confirm the exact one, fast-forwards the clone,
runs `install.sh` again and rebuilds the app.
`make app` signs the app with your "Developer ID Application" identity when the keychain has one (ad hoc
otherwise, for this Mac only). `make app-release` builds a notarized copy for other Macs and attaches it to
the GitHub release of `VERSION`; it needs `xcrun notarytool store-credentials guardrails-notary` once. A
downloaded app expects the kit at `~/.local/share/agent-guardrails`.
`guardrails version` shows the installed version; what changed between versions is in
[CHANGELOG.md](CHANGELOG.md) and on the releases page.

## Daily use

1. In a project, ask Claude for `/guardrails-init`. It opens a set-up PR. In the app you can do the same from
   the Projects window with **Set up…**.
2. Turn the project on once you have read that PR: `guardrails on <PR URL>`, or **Turn on** in the app.
3. Work ticket by ticket: `/ticket-spec` writes the spec and its open questions, you answer and lock it, and
   `/ticket-implement` builds against it.
4. When CI is green, approve the PR's exact HEAD with `guardrails approve <PR URL>` or **Review** in the app.
   Approving takes a typed confirmation, and in the app also Touch ID. In review mode (below) an approving
   review on github.com or GitHub Mobile works too.

Run `guardrails` with no arguments to see what waits for you. `guardrails off <owner/repo>` turns a project
off again.

## The agent's own GitHub identity (review mode)

Without it the agent works with your GitHub login. GitHub does not let you approve your own pull requests, so
the kit records your approval as a commit status (status mode). With an agent App the agent pushes and opens
PRs as the App's bot, and you approve them like any teammate's PR (review mode):

1. **Create…** under Agent identity in the app's Projects window (or `guardrails agent create`) registers a
   private GitHub App in your browser. It may write contents and pull requests only: no workflows,
   administration or statuses.
2. Install it with **Only select repositories** on the projects the agent works in (**Manage** in the app).
3. Make sure each project has `.github/CODEOWNERS` whose first line is `* @<you>` (new set-up PRs add it).
4. Press **Switch to review mode** on the project in the app (or run `guardrails on <owner/repo>` again). A
   code owner's review is then required, and GitHub dismisses it on every new push. **Review** on your own
   PR merges it with your admin bypass, which skips the review but never the checks.

`guardrails agent status` shows where the App is installed; `guardrails status` shows each project's mode.
While the agent runs as your computer user it can still reach your own login, so the identity separates
whose work is whose (and makes reviews possible); it is not a security boundary against the agent itself.

## How it is enforced

Hooks and the app are conveniences: an agent running as your user could get around them. The boundary is
on GitHub: a ruleset on the default branch, and a `ci-guard` job that runs from the base branch and checks
every PR against the locked spec. Only you can change either.

For the repository layout and the contributor commands, see [AGENTS.md](AGENTS.md).
