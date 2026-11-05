# Swift spec patterns

Tools: SwiftPM, swift-testing (XCTest is disabled in the Makefile), SwiftLint `--strict` with
`.agent/lint/swiftlint.yml`, `swift format`. Results come from the swift-testing event stream.
Implementation code under `Sources/` may not exit the process, crash (`fatalError`,
`preconditionFailure`), import a test framework, or patch the runtime (SwiftLint custom rules).

`private init` restricts construction to one file, but the contract and implementation live in
separate files. So the guarantee holds outside the module (internal init is invisible there);
inside the module, `escape-check swift` + review keep `init(validated:)` calls in the implementation
file. Put domain types in their own SwiftPM target to make the module boundary the guarantee.

## Contract (locked): `Sources/Domain/Percent.contract.swift` and `Sources/Domain/NotImplemented.swift`

Stubs must throw, and a typed `throws(PercentError)` cannot throw `NotImplemented`, so contract
functions use untyped `throws` and document the error type. Tests pin the errors with
`#expect(throws: PercentError.negative(v))`.

```swift
/// A percentage in [0, 100]. Only `Percent.make(_:)` produces one outside this module.
public struct Percent: Sendable, Equatable, Comparable {
    public let value: Double
    /// Called only by the validating factory in Percent.swift.
    init(validated value: Double) { self.value = value }
    public static func < (lhs: Percent, rhs: Percent) -> Bool { lhs.value < rhs.value }
}

public enum PercentError: Error, Equatable {
    case notFinite(Double)
    case negative(Double)
    case above100(Double)
}

public protocol PercentFactory {
    /// Throws `PercentError` for invalid input.
    static func make(_ value: Double) throws -> Percent
}
```

```swift
/// Thrown by stubs until the implementation exists.
public struct NotImplemented: Error, CustomStringConvertible {
    public let symbol: String
    public init(_ symbol: String) { self.symbol = symbol }
    public var description: String { "NotImplemented: \(symbol)" }
}
```

## Implementation stub (write-allowed): `Sources/Domain/Percent.swift`

The stub throws, never `fatalError`: a crash kills the test process and every remaining test
result with it. The spec gate requires every locked test to fail with `NotImplemented`.

```swift
extension Percent: PercentFactory {
    public static func make(_ value: Double) throws -> Percent {
        throw NotImplemented("Percent.make")
    }
}
```

## Property tests (locked): `Tests/DomainTests/PercentPropertyTests.swift`

- One top-level `@Suite` per file, named after the file; tests outside a suite are rejected. The ID
  is `Tests/<Target>/<Suite>.swift::<Suite> > <function(labels:)>`.
- Name every test function `ac<n><Behaviour>` (one criterion per test); the display name may repeat
  it (`@Test("AC-1: ...")`) but is not part of the ID.
- `@Test(arguments:)` is fine: all cases share the function's ID.

Use SwiftCheck if it resolves with the current toolchain. Otherwise `@Test(arguments:)` over a
seeded generator plus explicit edge values (`0`, `-0.0`, `100`, `100.0000001`, `.nan`, `.infinity`,
`-.leastNonzeroMagnitude`), each in the criterion it belongs to. This has no shrinking: list it as
a risk.

```swift
import Testing
@testable import Domain

@Suite struct PercentPropertyTests {
    @Test("AC-1: accepts [0, 100] and preserves the value", arguments: [0.0, -0.0, 0.5, 50.0, 100.0])
    func ac1AcceptsRangeAndPreservesValue(value: Double) throws {
        #expect(try Percent.make(value).value == value)
    }

    @Test("AC-2: rejects finite negatives", arguments: [-.leastNonzeroMagnitude, -1.0, -1e300])
    func ac2RejectsNegative(value: Double) {
        #expect(throws: PercentError.negative(value)) { try Percent.make(value) }
    }
}
```

## Acceptance

One swift-testing test per scenario in `Tests/<Target>/<Feature>AcceptanceTests.swift` (one suite
per file, named after it), functions named `ac<n><Scenario>`, Given/When/Then as comments (locked).
A `specs/<ID>/*.feature` file is optional documentation.
