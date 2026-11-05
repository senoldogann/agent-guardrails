#!/usr/bin/env bash
# Integration test: Swift template (SwiftPM + swift-testing event stream) through the evidence pipeline.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project swift
cd "$project"
cat >Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LangSwift",
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
EOF
mkdir -p Sources/Domain Tests/DomainTests
cat >Sources/Domain/NotImplemented.swift <<'EOF'
/// Thrown by stubs until the implementation exists.
public struct NotImplemented: Error, CustomStringConvertible {
    public let symbol: String
    public init(_ symbol: String) { self.symbol = symbol }
    public var description: String { "NotImplemented: \(symbol)" }
}
EOF
cat >Tests/DomainTests/PercentPropertyTests.swift <<'EOF'
import Testing
@testable import Domain

@Suite struct PercentPropertyTests {
    @Test("AC-1: accepts [0, 100] and preserves the value", arguments: [0.0, 0.5, 50.0, 99.75, 100.0])
    func ac1AcceptsRangeAndPreservesValue(value: Double) throws {
        #expect(try Percent.make(value).value == value)
    }

    @Test("AC-2: rejects negatives", arguments: [-0.0001, -1.0, -1e300])
    func ac2RejectsNegative(value: Double) {
        #expect(throws: PercentError.negative(value)) { try Percent.make(value) }
    }
}
EOF

write_other_test() {
  cat >Tests/DomainTests/OtherTests.swift <<EOF
import Testing

@Suite struct OtherTests {
    @Test$1 func unitArithmetic() { #expect(1 + 1 == 2) }
}
EOF
}
write_other_test ""

write_percent() {
  cat >Sources/Domain/Percent.swift <<EOF
public struct Percent: Sendable, Equatable {
    public let value: Double
}

public enum PercentError: Error, Equatable {
    case notFinite(Double)
    case negative(Double)
    case above100(Double)
}

extension Percent {
    public static func make(_ value: Double) throws -> Percent {
$1
    }
}
EOF
}
write_stub() { write_percent '        throw NotImplemented("Percent.make")'; }
write_correct() {
  write_percent '        guard value.isFinite else { throw PercentError.notFinite(value) }
        guard value >= 0 else { throw PercentError.negative(value) }
        guard value <= 100 else { throw PercentError.above100(value) }
        return Percent(value: value)'
}
write_wrong() {
  write_percent '        guard value >= 0 else { throw PercentError.negative(value) }
        return Percent(value: value.rounded())'
}
write_exit() {
  write_percent '        exit(0)'
  sed -i '' '1i\
import Foundation
' Sources/Domain/Percent.swift
}

echo "swift:"
write_stub
lock_tests Tests/DomainTests/PercentPropertyTests.swift <<'EOF'
Tests/DomainTests/PercentPropertyTests.swift::PercentPropertyTests > ac1AcceptsRangeAndPreservesValue(value:)
Tests/DomainTests/PercentPropertyTests.swift::PercentPropertyTests > ac2RejectsNegative(value:)
EOF
run_red_green write_stub write_correct write_wrong

write_correct
write_other_test '(.disabled("later"))'
expect_success "disabled test: make test passes (exit code alone would accept it)" make --no-print-directory test
expect_failure "disabled test: verify-green fails" .agent/bin/verify-green "$ticket"
expect_output "disabled test: verify-green names it" "Tests/DomainTests/OtherTests.swift::OtherTests > unitArithmetic()"
write_other_test ""

write_exit
expect_success "exit(0) in implementation: make test passes (exit code alone would accept it)" make --no-print-directory test
expect_failure "exit(0) in implementation: verify-green fails" .agent/bin/verify-green "$ticket"
if command -v swiftlint >/dev/null; then
  expect_failure "exit(0) in implementation: swiftlint rejects it" swiftlint lint --strict --quiet --config .agent/lint/swiftlint.yml Sources Tests
fi

finish swift
