---
name: guardrails-init
description: Install the agent guardrail kit into the current repository (Makefile command contract, .agent scripts, write-guard and stop-check hooks, base-branch CI guard with per-HEAD merge approval, AGENTS.md section). Use when the user asks to set up agent guardrails, spec-first ticket workflow, or "kontrol altyapısı" in a project.
disable-model-invocation: true
---

# Install agent guardrails into a project

Principle: trust human-defined, deterministic checks and the owner's approval, never the agent's own judgment.
Everything is versioned in the project so the agent, CI and teammates read the same rules.

The template lives in `template/` next to this file (resolve this skill's base directory).

## Steps

1. **Detect the language** from manifests: `package.json` + `tsconfig.json` → typescript,
   `package.json` without tsconfig → javascript, `pyproject.toml` → python, `Cargo.toml` → rust,
   `Package.swift` → swift. Several or none → ask the user; do not guess.
2. **Refuse to overwrite.** If `.agent/`, `Makefile`, `.claude/settings.json` or `.github/workflows/agent-guard.yml`
   exist, show what exists and ask how to merge (an existing Makefile can `include .agent/common.mk`).
3. **Work on a branch** `chore/agent-guardrails`. This bootstrap PR is reviewed manually: the guard is not on
   the default branch yet.
4. **Copy the template** with `cp -R`:
   - `template/.agent/` → `.agent/`; `template/.claude/settings.json` → `.claude/settings.json`
   - `template/.github/workflows/agent-guard.yml` → `.github/workflows/agent-guard.yml`
   - append `template/gitignore.append` to `.gitignore` (personal context and tokens stay local)
   - `template/makefiles/Makefile.<lang>` → `Makefile`; `template/ci/checks-<node|python|rust|swift>.yml` →
     `.github/workflows/checks-<node|python|rust|swift>.yml` (one per language in the repo)
   - the language's lint/restriction configs and test-support files as described in `template/.agent/lint/` and
     `template/.agent/test-support/` READMEs.
5. **Wire the toolchain** with the package manager (never global installs), following the comments at the top of
   the copied Makefile (required dev dependencies and config per language).
6. **Context in one place:** append `template/AGENTS.section.md` to `AGENTS.md` (create it with verified
   setup/test/lint/typecheck/run commands if missing); `CLAUDE.md` contains only `@AGENTS.md`.
7. **Verify:** run `make typecheck lint fmt-check test-ids test docs-check` and paste the output.
8. **Open the bootstrap PR** and tell the owner the steps only they can do (the agent's bash-guard blocks them):
   - merge the bootstrap PR after reviewing it;
   - run `.agent/bin/setup-github <their-login>` (environment, ruleset, repo and Actions settings);
   - create the fine-grained token described in AGENTS.md "Agent identity" and put it in
     `.claude/settings.local.json` → `env.GH_TOKEN` (gitignored), then run `gh auth setup-git`.
