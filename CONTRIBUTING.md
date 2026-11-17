# Contributing

Issues and pull requests are welcome. For anything larger than a fix, open an issue first so we can agree on
the approach.

- Read [AGENTS.md](AGENTS.md): it has the layout, the commands and the conventions (Bash 3.2 compatible scripts,
  no silent fallbacks, errors that name what failed).
- Run `make check` (shellcheck and the offline tests) before you push; for changes under `app/`, also
  `make app-test` on macOS. CI runs both.
- One change per PR, with a [Conventional Commits](https://www.conventionalcommits.org/) title, and a description
  of what changed, why, and how you checked it. User-visible changes get a line under `Unreleased` in
  [CHANGELOG.md](CHANGELOG.md).
- Security issues go through [SECURITY.md](SECURITY.md), not public issues.
