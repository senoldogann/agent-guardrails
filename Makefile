.PHONY: check lint test test-lang app app-test app-release

check: lint test

lint:
	shellcheck -x install.sh app/build.sh app/release.sh scripts/*.sh bin/* tests/*.sh tests/lang/*.sh hooks-global/*.sh skills/guardrails-init/template/.agent/hooks/*.sh \
		$$(find skills/guardrails-init/template/.agent/bin -type f)

test:
	tests/hooks-global.sh
	tests/pr-target.sh
	tests/guardrails-cli.sh
	tests/install.sh
	tests/human-owned.sh
	tests/smoke.sh
	tests/release.sh
	tests/agent-app.sh
	tests/kit-update.sh

## Slow: real TS/Python/Rust/Swift mini projects (needs pnpm, uv, cargo, swift).
test-lang:
	tests/lang/run.sh

## The owner's macOS app: build it into ~/Applications from this kit install (needs Xcode 26+).
app:
	app/build.sh

app-test:
	swift test --package-path app

## The owner, on macOS: a signed, notarized Guardrails.app attached to the GitHub release of VERSION.
app-release:
	app/release.sh
