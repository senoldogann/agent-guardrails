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

`install.sh` links the skills into `~/.claude/skills`, registers two hooks in `~/.claude/settings.json`
(after backing it up) and links the `guardrails` command onto `PATH`. It checks everything it needs before
changing anything. To update, run `git pull --ff-only` in the clone, then `install.sh` and `make app` again.
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

1. `guardrails agent create` registers a private GitHub App in your browser. It may write contents and pull
   requests only: no workflows, administration or statuses.
2. Install it with **Only select repositories** on the projects the agent works in.
3. Make sure each project has `.github/CODEOWNERS` whose first line is `* @<you>` (new set-up PRs add it).
4. Run `guardrails on <owner/repo>` again. The ruleset then requires a code owner's review that GitHub
   dismisses on every new push, and lets you, as admin, merge your own PRs (`gh pr merge --admin`).

`guardrails agent status` shows where the App is installed; `guardrails status` shows each project's mode.
While the agent runs as your computer user it can still reach your own login, so the identity separates
whose work is whose (and makes reviews possible); it is not a security boundary against the agent itself.

## How it is enforced

Hooks and the app are conveniences: an agent running as your user could get around them. The boundary is
on GitHub: a ruleset on the default branch, and a `ci-guard` job that runs from the base branch and checks
every PR against the locked spec. Only you can change either.

For the repository layout and the contributor commands, see [AGENTS.md](AGENTS.md).
