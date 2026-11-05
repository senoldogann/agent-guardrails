#!/usr/bin/env bash
# Integration test: Swift app project. An Xcode project (generated with xcodegen) holds a macOS app whose
# logic lives in the local package Packages/Core; the gates run on that package (SWIFT_PKG) and
# `typecheck` also compiles the app (APP_SCHEME). Needs swift, xcodebuild and xcodegen.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project swift
cd "$project"
pkg=Packages/Core
sed -i '' -e "s#^SWIFT_PKG := .*#SWIFT_PKG := $pkg#" -e 's#^APP_SCHEME :=.*#APP_SCHEME := App#' \
  -e 's#^APP_DESTINATION := .*#APP_DESTINATION := generic/platform=macOS#' Makefile

mkdir -p "$pkg/Sources/Domain" "$pkg/Tests/DomainTests" App
cat >"$pkg/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Domain", targets: ["Domain"])],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
EOF
cat >"$pkg/Sources/Domain/NotImplemented.swift" <<'EOF'
/// Thrown by stubs until the implementation exists.
public struct NotImplemented: Error, CustomStringConvertible {
    public let symbol: String
    public init(_ symbol: String) { self.symbol = symbol }
    public var description: String { "NotImplemented: \(symbol)" }
}
EOF
cat >"$pkg/Tests/DomainTests/PercentPropertyTests.swift" <<'EOF'
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
# App code outside the package: a force-try that escape-check must not see, because the gates cover the package.
cat >App/AppMain.swift <<'EOF'
import Domain

@main
struct AppMain {
    static func main() {
        let percent = try! Percent.make(5)
        print(percent.value)
    }
}
EOF
cat >project.yml <<EOF
name: App
options:
  bundleIdPrefix: dev.example.kit
packages:
  Core:
    path: $pkg
targets:
  App:
    type: tool
    platform: macOS
    deploymentTarget: "14.0"
    sources: [App]
    dependencies:
      - package: Core
        product: Domain
EOF

write_percent() {
  cat >"$pkg/Sources/Domain/Percent.swift" <<EOF
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

echo "swift-xcode:"
xcodegen generate --quiet >"$project/.out" 2>&1 || {
  fail "xcodegen generate"
  cat "$project/.out"
}
git add -A
write_stub
expect_success "typecheck builds the package and compiles the app" make --no-print-directory typecheck
git add -A
expect_success "escape-check covers only the package" .agent/bin/escape-check swift "$pkg"
expect_failure "the app's force-try is outside the gates, not unseen" .agent/bin/escape-check swift .
lock_tests "$pkg/Tests/DomainTests/PercentPropertyTests.swift" <<EOF
$pkg/Tests/DomainTests/PercentPropertyTests.swift::PercentPropertyTests > ac1AcceptsRangeAndPreservesValue(value:)
$pkg/Tests/DomainTests/PercentPropertyTests.swift::PercentPropertyTests > ac2RejectsNegative(value:)
EOF
run_red_green write_stub write_correct write_wrong
expect_result "result IDs carry the package path" \
  "$pkg/Tests/DomainTests/PercentPropertyTests.swift::PercentPropertyTests > ac1AcceptsRangeAndPreservesValue(value:)" failed "Expectation failed"

write_correct
printf 'public func brokenForApp() {}\n' >>"$pkg/Sources/Domain/Percent.swift"
sed -i '' 's/try! Percent.make(5)/try! Percent.make(5, missing: 1)/' App/AppMain.swift
expect_failure "an app that no longer compiles fails typecheck" make --no-print-directory typecheck
finish swift-xcode
