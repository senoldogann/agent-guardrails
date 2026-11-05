---
name: guardrails-init
description: Install the agent guardrail kit into the current repository (Makefile command contract, .agent scripts, write-guard and stop-check hooks, base-branch CI guard with per-HEAD merge approval, AGENTS.md section). Use when the user asks to set up agent guardrails, spec-first ticket workflow, or "kontrol altyapısı" in a project.
disable-model-invocation: true
---

# Install agent guardrails into a project

Principle: trust human-defined, deterministic checks and the owner's approval, never the agent's own judgment.
Everything is versioned in the project so the agent, CI and teammates read the same rules.

The template lives in `template/` next to this file (resolve this skill's base directory).

## Prerequisites (check, do not install globally)

- The kit is installed on this machine with the kit's `install.sh`: it provides the `/ticket-spec`,
  `/ticket-implement` and `/process-fix` skills and the global `bash-guard` hook that `AGENTS.md` refers to.
  If `~/.claude/skills/ticket-spec` is missing, say so in the PR description.
- `bash`, GNU make 3.81 or newer (the macOS default works), `jq`, plus the language tools listed at the top
  of `template/makefiles/Makefile.<lang>`.

## Steps

1. **Detect the language** from manifests: `package.json` + `tsconfig.json` → typescript,
   `package.json` without tsconfig → javascript, `pyproject.toml` → python, `Cargo.toml` → rust,
   `Package.swift` → swift. Several or none → stop and ask; do not guess.
2. **Refuse to overwrite.** If `.agent/`, `Makefile`, `.claude/settings.json` or `.github/workflows/agent-guard.yml`
   exist, stop and ask how to merge (an existing Makefile can `include .agent/common.mk`).
3. **Branch** `chore/agent-guardrails` from the up-to-date default branch. If that branch already exists
   locally or remotely, stop and ask (it may hold an earlier, unmerged installation).
4. **Copy the template** with `cp -R`:
   - `template/.agent/` → `.agent/` as a whole. It contains files for every language; keep them all: they are
     inert unless the language Makefile uses them, and keeping the directory identical to the kit makes kit
     updates a clean diff. Lint configs (`.agent/lint/`) and test support (`.agent/test-support/`) are used in
     place by the Makefile; do not copy them elsewhere.
   - `template/.claude/settings.json` → `.claude/settings.json`
   - `template/.github/workflows/agent-guard.yml` → `.github/workflows/agent-guard.yml`
   - `template/makefiles/Makefile.<lang>` → `Makefile`
   - `template/ci/checks-<node|python|rust|swift>.yml` → `.github/workflows/checks-<node|python|rust|swift>.yml`
     (node for typescript and javascript; one file per language in the repo)
   - append `template/gitignore.append` to `.gitignore`
5. **Keep kit files out of the project's own formatter and linter** (they follow the kit's style and are
   updated from the kit, never reformatted): `.agent/` and `.claude/settings.json`.
   - Biome: `"files": { "includes": ["**", "!.agent", "!.claude/settings.json"] }` (a list of only
     negations matches nothing; keep any existing positive patterns instead of `"**"`).
   - ruff: `extend-exclude = [".agent"]`. SwiftLint and rustfmt need nothing (no kit sources in their scope).
6. **Install the dev dependencies** listed at the top of the copied `Makefile` with the package manager
   (never global installs) and apply the config lines listed there, if any.
7. **Context in one place:** create or update `AGENTS.md` with the project's verified setup, test, lint,
   typecheck and run commands ("Run: none" for a library without an entry point), then append
   `template/AGENTS.section.md`. `CLAUDE.md` contains only `@AGENTS.md`.
8. **Commit, then verify** (`docs-check` requires `AGENTS.md` to be tracked): commit
   `chore: install agent guardrails kit`, run `make typecheck lint fmt-check test-ids test docs-check` and
   `make ci BASE_SHA=$(git merge-base HEAD origin/<default-branch>)`. Fix only what this installation broke;
   if an existing project check fails, stop and report it.
9. **Open the bootstrap PR** (a normal PR, not a draft) with the verification commands and their real output
   in the description. **Never merge it, never enable auto-merge for it**, whatever general rules say: the
   guard is not on the default branch yet, so the owner reviews and merges this PR by hand.
10. **Tell the owner the steps only they can do** (bash-guard blocks them for agents):
    - review and merge the bootstrap PR;
    - run `.agent/bin/setup-github` and do the manual step it prints;
    - approve PRs with `approve-head <PR link>` in their own terminal (never the agent's); the command is
      on PATH after the kit's `install.sh`, and every ready PR carries it in a comment;
    - create the fine-grained token described in `AGENTS.md` "Agent identity", put it in
      `.claude/settings.local.json` → `env.GH_TOKEN`, use an HTTPS remote and run `gh auth setup-git`.
