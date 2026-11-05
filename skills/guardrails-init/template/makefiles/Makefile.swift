# Command contract for agents and CI. Language targets here; shared gates in .agent/common.mk.
# Prerequisites: bash, GNU-compatible make, jq, Swift 6 toolchain (SwiftPM), SwiftLint.
# Tests use swift-testing; one top-level @Suite per test file, named after the file.
# Test results are judged from the normalized files in $(RESULTS), never from exit codes alone.
# Tests use swift-testing only (XCTest is disabled), one top-level @Suite per file named after it.
include .agent/common.mk

RESULTS := .agent/reports/results
EVENT_STREAM := --experimental-event-stream-version 0 --experimental-event-stream-output

.PHONY: typecheck lint fmt-check test-ids test test-prop test-mutation

typecheck:
	swift build --build-tests -Xswiftc -warnings-as-errors

lint:
	swiftlint lint --strict --config .agent/lint/swiftlint.yml Sources Tests
	.agent/bin/escape-check swift

fmt-check:
	swift format lint --strict --recursive Sources Tests

## Every test ID without running tests; stdout carries only IDs.
test-ids:
	@mkdir -p $(RESULTS)
	@swift test list --disable-xctest >$(RESULTS)/ids.swift.txt
	@.agent/bin/results-swift-ids $(RESULTS)/ids.swift.txt

# $(call swift_results,<name>,<swift test filters>): runs swift test, writes $(RESULTS)/<name>.tsv,
# exits with swift test's exit code (or the adapter's).
define swift_results
	@mkdir -p $(RESULTS) && rm -f $(RESULTS)/$(1).events.jsonl $(RESULTS)/$(1).tsv
	@status=0; swift test --disable-xctest $(EVENT_STREAM) $(RESULTS)/$(1).events.jsonl $(2) || status=$$?; \
	.agent/bin/results-swift $(RESULTS)/$(1).events.jsonl >$(RESULTS)/$(1).tsv.tmp && \
	mv $(RESULTS)/$(1).tsv.tmp $(RESULTS)/$(1).tsv && exit $$status
endef

## Full suite -> $(RESULTS)/test.tsv.
test:
	$(call swift_results,test,)

## Property tests (suites named *PropertyTests) -> $(RESULTS)/test-prop.tsv.
test-prop:
	$(call swift_results,test-prop,--filter PropertyTests)

## No mutation gate for Swift: Muter reports wrong results on swift-testing and has no recent release.
## Swift relies on deterministic boundary tables in the locked tests.
test-mutation:
	@echo "no mutation gate for Swift"
