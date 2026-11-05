# Shared guardrail targets, included by the project Makefile, which defines the language targets:
#   typecheck lint fmt-check test-ids test test-prop
# `test` writes normalized results to .agent/reports/results/test.tsv (see verify-green/verify-red).

AGENT_TICKET := $(shell .agent/bin/active-ticket)
SPEC_TICKET ?= $(AGENT_TICKET)
CHECK_LOG := .agent/reports/$(if $(AGENT_TICKET),$(AGENT_TICKET),no-ticket)/checks.log

.PHONY: mutation ci check check-spec check-draft questions-lint-ticket test-red verify-green-all verify-green-others verify-red-ticket trace tests-lock-check lock-verify-all docs-check

## Entry point for CI (BASE_SHA = PR base): spec gate on the PR's last spec commit, full gate on HEAD.
ci:
	@test -n "$(BASE_SHA)" || { echo "ci: BASE_SHA is required" >&2; exit 1; }
	@.agent/bin/ci-run "$(BASE_SHA)"

## Full gate (implement phase, CI): everything green, every locked test of every ticket passed.
check:
	@.agent/bin/run-checks "$(CHECK_LOG)" typecheck lint fmt-check test verify-green-all trace tests-lock-check lock-verify-all docs-check

## Spec gate: contracts compile, specs trace to criteria, every locked test of SPEC_TICKET fails on
## NotImplemented, nothing else fails, and every other ticket stays green.
check-spec:
	@.agent/bin/run-checks "$(CHECK_LOG)" typecheck lint fmt-check questions-lint-ticket test-red verify-red-ticket verify-green-others trace tests-lock-check lock-verify-all docs-check

## Draft gate for a spec that is not locked yet: it must compile, lint and ask its questions properly.
check-draft:
	@.agent/bin/run-checks "$(CHECK_LOG)" typecheck lint fmt-check questions-lint-ticket docs-check

questions-lint-ticket:
	@test -n "$(SPEC_TICKET)" || { echo "questions-lint-ticket: no ticket (start-spec or SPEC_TICKET=...)" >&2; exit 1; }
	@.agent/bin/questions-lint "$(SPEC_TICKET)"

## Runs the suite for its results only; failures are expected against stubs and judged by verify-red.
test-red:
	@$(MAKE) --no-print-directory test; echo "test-red: runner exit code $$? (judged by verify-red-ticket)"

verify-green-all:
	@for lock in specs/*/tests.lock; do \
		[ -f "$$lock" ] || continue; \
		.agent/bin/verify-green "$$(basename "$$(dirname "$$lock")")" || exit 1; \
	done

verify-red-ticket:
	@test -n "$(SPEC_TICKET)" || { echo "verify-red-ticket: no ticket (start-spec or SPEC_TICKET=...)" >&2; exit 1; }
	@.agent/bin/verify-red "$(SPEC_TICKET)"
	@.agent/bin/unexpected-failures "$(SPEC_TICKET)"

verify-green-others:
	@for lock in specs/*/tests.lock; do \
		[ -f "$$lock" ] || continue; \
		ticket=$$(basename "$$(dirname "$$lock")"); \
		[ "$$ticket" = "$(SPEC_TICKET)" ] || .agent/bin/verify-green "$$ticket" || exit 1; \
	done

trace:
	@.agent/bin/trace-check

tests-lock-check:
	@.agent/bin/tests-lock-check

lock-verify-all:
	@for lock in specs/*/spec.lock; do \
		[ -f "$$lock" ] || continue; \
		.agent/bin/lock-verify "$$(basename "$$(dirname "$$lock")")" || exit 1; \
	done

docs-check:
	@.agent/bin/docs-check

## Mutation gate on demand (slow): mutants of the source changed since BASE_SHA must all be killed.
mutation:
	@test -n "$(BASE_SHA)" || { echo "mutation: BASE_SHA is required (e.g. BASE_SHA=$$(git merge-base HEAD origin/main))" >&2; exit 1; }
	@.agent/bin/mutation-scope "$(BASE_SHA)"
	@if [ -s .agent/reports/mutation/scope.txt ]; then $(MAKE) --no-print-directory test-mutation && .agent/bin/mutation-gate; fi
