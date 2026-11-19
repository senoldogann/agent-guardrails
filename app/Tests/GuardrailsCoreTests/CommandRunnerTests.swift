import Darwin
import Foundation
import Testing
import os

@testable import GuardrailsCore

/// A short limit, so a stuck command shows within seconds. The bound adds both stop graces and slack for a busy
/// test machine; the outer deadline only keeps a regression from hanging the suite.
private let shortLimit = CommandTimeLimit(run: 1, stopGrace: 1)
private let completionBound: Duration = .seconds(6)
private let outerDeadline: Duration = .seconds(20)

private enum Outcome: Sendable {
    case finished(Result<CommandResult, any Error>)
    case outerDeadlinePassed
}

/// Runs the command, but gives up after `outerDeadline`. A task group would wait for a child that never returns,
/// so the first of two unstructured tasks resumes the continuation.
private func runWithinOuterDeadline(_ command: [String]) async -> (outcome: Outcome, elapsed: Duration) {
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let resumeOnce: @Sendable (Outcome) -> Void = { outcome in
            let first = resumed.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: outcome) }
        }
        let timer = Task {
            try await Task.sleep(for: outerDeadline)
            resumeOnce(.outerDeadlinePassed)
        }
        Task {
            defer { timer.cancel() }
            do {
                resumeOnce(.finished(.success(try await runCommand(command: command, environment: [:], limit: shortLimit))))
            } catch {
                resumeOnce(.finished(.failure(error)))
            }
        }
    }
    return (outcome, clock.now - started)
}

private func expectTimeout(_ run: (outcome: Outcome, elapsed: Duration)) {
    switch run.outcome {
    case .outerDeadlinePassed:
        Issue.record("runCommand did not return within \(outerDeadline)")
    case .finished(.success(let result)):
        Issue.record("expected CommandTimeoutError, got status \(result.status)")
    case .finished(.failure(let error)):
        #expect(error is CommandTimeoutError, "unexpected error: \(error)")
        #expect(run.elapsed < completionBound, "took \(run.elapsed)")
    }
}

/// A file a fixture writes a background child's process ID to.
private func pidFile() -> String {
    FileManager.default.temporaryDirectory.appending(path: "guardrails-pid-\(UUID().uuidString)").path
}

private func readPID(_ path: String) throws -> pid_t {
    let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(text) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
    return pid
}

/// Whether the process is gone, waiting up to a second for its new parent to reap it.
private func processIsGone(_ pid: pid_t) async throws -> Bool {
    for _ in 0..<20 {
        if kill(pid, 0) == -1, errno == ESRCH { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

@Suite("command runner")
struct CommandRunnerTests {
    @Test func returnsOutputErrorAndStatus() async throws {
        // Both streams are larger than a pipe buffer, so reading one while the other fills would deadlock.
        let result = try await runCommand(
            command: ["/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' o; head -c 200000 /dev/zero | tr '\\0' e >&2; exit 3"],
            environment: [:], limit: shortLimit)
        #expect(result.status == 3)
        #expect(result.standardOutput.count == 200_000)
        #expect(result.standardError.count == 200_000)
    }

    @Test func stopsADescendantThatOutlivesTheCommand() async throws {
        // The command exits at once, but its background child keeps stdout open.
        let pids = pidFile()
        let run = await runWithinOuterDeadline(["/bin/sh", "-c", "sleep 30 & echo $! > \(pids); exit 0"])
        expectTimeout(run)
        #expect(try await processIsGone(try readPID(pids)), "the background child survived the timeout")
    }

    @Test func killsACommandThatIgnoresTerm() async throws {
        let pids = pidFile()
        let run = await runWithinOuterDeadline(["/bin/sh", "-c", "trap '' TERM; echo $$ > \(pids); sleep 30"])
        expectTimeout(run)
        #expect(try await processIsGone(try readPID(pids)), "the command survived the timeout")
    }

    @Test func killsAQuietChildInTheGroupThatIgnoresTerm() async throws {
        // The child stays in the command's group, ignores SIGTERM and lets go of stdout and stderr, so every stream
        // ends as soon as SIGTERM stops the command: the end of the streams says nothing about the child.
        let pids = pidFile()
        defer {
            if let child = try? readPID(pids) { kill(child, SIGKILL) }
            try? FileManager.default.removeItem(atPath: pids)
        }
        let child = "trap \"\" TERM; exec >/dev/null 2>&1; echo $$ > \(pids).tmp && mv \(pids).tmp \(pids); exec sleep 30"
        // The command waits until the child has written its process ID, so the timeout always finds it ready.
        let run = await runWithinOuterDeadline([
            "/bin/sh", "-c", "/bin/sh -c '\(child)' & while [ ! -f \(pids) ]; do sleep 0.01; done; sleep 30",
        ])
        expectTimeout(run)
        #expect(try await processIsGone(try readPID(pids)), "the child that ignored SIGTERM survived the timeout")
    }

    @Test func stopsReadingWhenADescendantLeavesTheProcessGroup() async throws {
        // `set -m` puts the background job in its own process group, out of reach of the group signals.
        let pids = pidFile()
        let run = await runWithinOuterDeadline(["/bin/sh", "-c", "set -m; sleep 30 & echo $! > \(pids); wait"])
        expectTimeout(run)
        let escaped = try readPID(pids)
        kill(escaped, SIGKILL)
    }
}
