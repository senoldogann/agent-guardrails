# Command contract for agents and CI. Language targets here; shared gates in .agent/common.mk.
# Prerequisites: bash, GNU-compatible make, jq, Swift 6 toolchain (SwiftPM), SwiftLint; Xcode when
# APP_SCHEME is set.
# Tests use swift-testing only (XCTest is disabled), one top-level @Suite per file named after it.
# Test results are judged from the normalized files in $(RESULTS), never from exit codes alone.
include .agent/common.mk

# The SwiftPM package the gates run on: "." when Package.swift is at the repository root. In an Xcode
# app project, the local package that holds the logic tickets change (for example Packages/Core); the
# app target stays outside the test gates and only has to compile (APP_SCHEME).
SWIFT_PKG := .
# Xcode scheme that `typecheck` also builds, compile-only and without a simulator, so a package change
# cannot break the app unnoticed. Empty for a plain package. xcodebuild finds the project in the
# repository root; the package must also build for macOS, where `swift test` runs.
APP_SCHEME :=
APP_DESTINATION := generic/platform=iOS Simulator

RESULTS := .agent/reports/results
EVENT_STREAM := --experimental-event-stream-version 0 --experimental-event-stream-output
# Event stream paths are absolute: older swift test resolves a relative one against --package-path.
PKG := --package-path $(SWIFT_PKG)

.PHONY: typecheck lint fmt-check test-ids test test-prop test-mutation

typecheck:
	swift build $(PKG) --build-tests -Xswiftc -warnings-as-errors
	$(if $(APP_SCHEME),xcodebuild build -quiet -scheme '$(APP_SCHEME)' -destination '$(APP_DESTINATION)' CODE_SIGNING_ALLOWED=NO)

lint:
	swiftlint lint --strict --config .agent/lint/swiftlint.yml $(SWIFT_PKG)/Sources $(SWIFT_PKG)/Tests
	.agent/bin/escape-check swift $(SWIFT_PKG)

fmt-check:
	swift format lint --strict --recursive $(SWIFT_PKG)/Sources $(SWIFT_PKG)/Tests

## Every test ID without running tests; stdout carries only IDs.
test-ids:
	@mkdir -p $(RESULTS)
	@swift test list $(PKG) --disable-xctest >$(RESULTS)/ids.swift.txt
	@.agent/bin/results-swift-ids $(RESULTS)/ids.swift.txt $(SWIFT_PKG)

# $(call swift_results,<name>,<swift test filters>): runs swift test, writes $(RESULTS)/<name>.tsv,
# exits with swift test's exit code (or the adapter's).
define swift_results
	@mkdir -p $(RESULTS) && rm -f $(RESULTS)/$(1).events.jsonl $(RESULTS)/$(1).tsv
	@status=0; swift test $(PKG) --disable-xctest $(EVENT_STREAM) $(CURDIR)/$(RESULTS)/$(1).events.jsonl $(2) || status=$$?; \
	.agent/bin/results-swift $(RESULTS)/$(1).events.jsonl $(SWIFT_PKG) >$(RESULTS)/$(1).tsv.tmp && \
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
