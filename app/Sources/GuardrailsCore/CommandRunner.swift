import Foundation

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// The longest a non-interactive command may run. `guardrails inbox` over many repositories, with GitHub's
/// retries, stays well below it; a command still running then hangs (a stalled network, a prompt nobody sees).
public let commandTimeout: TimeInterval = 300

/// A command that ran past `commandTimeout` and was stopped.
public struct CommandTimeoutError: Error, CustomStringConvertible {
    public let command: [String]
    public var description: String {
        "\(command.joined(separator: " ")) did not finish within \(Int(commandTimeout)) seconds and was stopped"
    }
}

/// Runs a non-interactive command (for example `guardrails inbox --json`) and collects its output. It is stopped
/// after `commandTimeout`, so a hung command cannot hold a refresh forever.
public func runCommand(command: [String], environment: [String: String]) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do {
                continuation.resume(returning: try runCommandBlocking(command: command, environment: environment))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func runCommandBlocking(command: [String], environment: [String: String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    // stderr goes to a file so a long error text cannot fill a pipe while stdout is being read.
    let errorURL = FileManager.default.temporaryDirectory.appending(path: "guardrails-\(UUID().uuidString).err")
    guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: errorURL.path])
    }
    defer { try? FileManager.default.removeItem(at: errorURL) }
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    process.standardError = errorHandle
    let started = Date()
    try process.run()
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: deadline)
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    try errorHandle.close()
    if process.terminationReason == .uncaughtSignal, Date().timeIntervalSince(started) >= commandTimeout {
        throw CommandTimeoutError(command: command)
    }
    let errorData = try Data(contentsOf: errorURL)
    return CommandResult(
        status: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self))
}

/// What a failed guardrails command means for the owner. GitHub cannot be reached, the GitHub CLI is signed
/// out, its login was revoked or expired, or GitHub's rate limit is hit: each gets its own sentence with what
/// to do, because "offline" and "signed out" need different fixes. Anything else is the command's own message.
public func describeCommandFailure(_ result: CommandResult, command: String) -> String {
    let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    let has = { (markers: [String]) in markers.contains { message.contains($0) } }
    if has(["gh auth login", "not logged into", "not logged in"]) {
        return "GitHub CLI is not signed in. Run gh auth login in your terminal, then refresh."
    }
    if has(["Bad credentials", "HTTP 401"]) {
        return "GitHub refused the GitHub CLI's login: it expired or was revoked. Run gh auth login in your terminal, then refresh."
    }
    if has([
        "Could not resolve host", "error connecting", "no such host", "dial tcp", "connection refused",
        "network is unreachable", "i/o timeout", "TLS handshake timeout", "Failed to connect",
    ]) {
        return "Offline: GitHub cannot be reached. Showing the last known state."
    }
    if has(["API rate limit"]) {
        return "GitHub's API rate limit is reached. Try again in a few minutes."
    }
    if has(["GitHub did not answer"]) {
        return "GitHub did not answer in time, three tries in a row. Refresh to try again."
    }
    return message.isEmpty ? "\(command) exited with status \(result.status)" : message
}
