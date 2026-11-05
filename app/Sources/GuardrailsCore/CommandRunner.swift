import Foundation

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String
}

/// Runs a non-interactive command (for example `guardrails inbox --json`) and collects its output.
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
    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try errorHandle.close()
    let errorData = try Data(contentsOf: errorURL)
    return CommandResult(
        status: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self))
}
