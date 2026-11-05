// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Guardrails",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Guardrails", targets: ["Guardrails"]),
    ],
    targets: [
        .target(name: "GuardrailsCore"),
        .executableTarget(name: "Guardrails", dependencies: ["GuardrailsCore"]),
        .testTarget(name: "GuardrailsCoreTests", dependencies: ["GuardrailsCore"]),
    ]
)
