.PHONY: check lint test test-lang

check: lint test

lint:
	shellcheck -x install.sh bin/* tests/*.sh tests/lang/*.sh hooks-global/*.sh skills/guardrails-init/template/.agent/hooks/*.sh \
		$$(find skills/guardrails-init/template/.agent/bin -type f)

test:
	tests/hooks-global.sh
	tests/pr-target.sh
	tests/human-owned.sh
	tests/smoke.sh

## Slow: real TS/Python/Rust/Swift mini projects (needs pnpm, uv, cargo, swift).
test-lang:
	tests/lang/run.sh
