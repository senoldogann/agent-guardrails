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

/// How long a command may run, and how long it then gets after each stop signal before the next step.
public struct CommandTimeLimit: Sendable, Equatable {
    public let run: TimeInterval
    public let stopGrace: TimeInterval

    public init(run: TimeInterval, stopGrace: TimeInterval) {
        self.run = run
        self.stopGrace = stopGrace
    }
}

/// `guardrails inbox` over many repositories, with GitHub's retries, stays well below five minutes; a command
/// still running then hangs (a stalled network, a prompt nobody sees).
public let commandTimeLimit = CommandTimeLimit(run: 300, stopGrace: 2)

/// A command that ran past its time limit and was stopped.
public struct CommandTimeoutError: Error, CustomStringConvertible {
    public let command: [String]
    public let limit: CommandTimeLimit
    public var description: String {
        "\(command.joined(separator: " ")) did not finish within \(Int(limit.run)) seconds and was stopped"
    }
}

/// Runs a non-interactive command (for example `guardrails inbox --json`) and collects its output. A command
/// still running after `commandTimeLimit` is stopped and `CommandTimeoutError` is thrown, so a hung command cannot
/// hold a refresh forever.
public func runCommand(command: [String], environment: [String: String]) async throws -> CommandResult {
    try await runCommand(command: command, environment: environment, limit: commandTimeLimit)
}

/// `runCommand` with its own time limit; tests use short ones. The call returns within `limit.run` plus two
/// `limit.stopGrace`, whatever the command and its descendants do.
func runCommand(command: [String], environment: [String: String], limit: CommandTimeLimit) async throws
    -> CommandResult
{
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do {
                continuation.resume(
                    returning: try runCommandBlocking(command: command, environment: environment, limit: limit))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The command runs in its own process group, so a timeout reaches every descendant that stayed in it: SIGTERM
/// first, then SIGKILL for whatever is left of the group after `stopGrace`. The end of the output streams and the
/// command's exit say nothing about the rest of the group (a child that ignores SIGTERM may have let go of the
/// pipes), so SIGKILL always follows; the wait before it only ends early once the group holds nothing but the
/// command. A descendant that left the group (`setsid`, job control) cannot be reached by group signals at all and
/// may keep the output pipes open forever, so after the second grace the pipes are closed without waiting for
/// their end. The command itself stays unreaped until both signals are sent, which keeps its process ID, and with
/// it the group ID, from being reused while the group is signalled.
private func runCommandBlocking(command: [String], environment: [String: String], limit: CommandTimeLimit) throws
    -> CommandResult
{
    var streams = try spawnInOwnGroup(command: command, environment: environment)
    defer { streams.closeAll() }
    let clock = ContinuousClock()
    if try streams.drain(until: clock.now + .seconds(limit.run)) {
        return CommandResult(
            status: try reap(streams.pid, command: command),
            standardOutput: String(decoding: streams.outputData, as: UTF8.self),
            standardError: String(decoding: streams.errorData, as: UTF8.self))
    }
    let termDeadline = clock.now + .seconds(limit.stopGrace)
    kill(-streams.pid, SIGTERM)
    _ = try streams.drain(until: termDeadline)
    waitUntilGroupHoldsOnly(leader: streams.pid, until: termDeadline)
    kill(-streams.pid, SIGKILL)
    _ = try streams.drain(until: clock.now + .seconds(limit.stopGrace))
    if streams.hasExited {
        _ = try reap(streams.pid, command: command)
    } else {
        // Only a process stuck in the kernel outlives SIGKILL this long; reap it whenever it goes.
        let pid = streams.pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }
    throw CommandTimeoutError(command: command, limit: limit)
}

/// The read ends of a running command: its stdout, its stderr, and a pipe that closes when the command exits.
/// Reading all three in one poll loop means a full stderr pipe cannot stall stdout, and a deadline bounds every
/// wait.
private struct CommandStreams {
    let pid: pid_t
    let command: [String]
    let output: Int32
    let error: Int32
    let exitNotice: Int32
    var open: [Int32]
    var outputData = Data()
    var errorData = Data()

    var hasExited: Bool { !open.contains(exitNotice) }

    /// Reads what arrives until every stream has ended (true) or the deadline passes (false).
    mutating func drain(until deadline: ContinuousClock.Instant) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !open.isEmpty {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            var descriptors = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if poll(&descriptors, nfds_t(descriptors.count), pollMilliseconds(remaining)) < 0 {
                guard errno == EINTR else { throw SpawnError(call: "poll", code: errno, command: command) }
                continue
            }
            for ready in descriptors where ready.revents != 0 {
                let count = read(ready.fd, &buffer, buffer.count)
                if count > 0 {
                    if ready.fd == output { outputData.append(contentsOf: buffer[0..<count]) }
                    if ready.fd == error { errorData.append(contentsOf: buffer[0..<count]) }
                } else if count == 0 {
                    close(ready.fd)
                    open.removeAll { $0 == ready.fd }
                } else if errno != EINTR {
                    throw SpawnError(call: "read", code: errno, command: command)
                }
            }
        }
        return true
    }

    mutating func closeAll() {
        for descriptor in open { close(descriptor) }
        open = []
    }
}

/// poll(2) takes whole milliseconds; rounding up keeps it from spinning just before the deadline.
private func pollMilliseconds(_ duration: Duration) -> Int32 {
    let (seconds, attoseconds) = duration.components
    let milliseconds = seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
    return Int32(clamping: milliseconds)
}

/// Starts the command in a new process group with stdin on /dev/null, default signal handling and only the
/// descriptors set up here, as Foundation's Process would, and watches for its exit without reaping it.
private func spawnInOwnGroup(command: [String], environment: [String: String]) throws -> CommandStreams {
    let output = try makePipe(command: command)
    let errors: (read: Int32, write: Int32)
    let exitNotice: (read: Int32, write: Int32)
    do {
        errors = try makePipe(command: command)
    } catch {
        closeAll([output.read, output.write])
        throw error
    }
    do {
        exitNotice = try makePipe(command: command)
    } catch {
        closeAll([output.read, output.write, errors.read, errors.write])
        throw error
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, output.write, 1)
    posix_spawn_file_actions_adddup2(&actions, errors.write, 2)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)

    let argv = command.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var spawned: pid_t = 0
    let status = posix_spawn(&spawned, command[0], &actions, &attributes, argv, envp)
    close(output.write)
    close(errors.write)
    guard status == 0 else {
        closeAll([output.read, errors.read, exitNotice.read, exitNotice.write])
        throw SpawnError(call: "posix_spawn", code: status, command: command)
    }
    let pid = spawned
    let noticeWrite = exitNotice.write
    Thread.detachNewThread {
        // WNOWAIT leaves the command a zombie: its process ID stays taken until `reap`.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        close(noticeWrite)
    }
    return CommandStreams(
        pid: pid, command: command, output: output.read, error: errors.read, exitNotice: exitNotice.read,
        open: [output.read, errors.read, exitNotice.read])
}

/// Gives the processes of the group that `leader` leads time to act on SIGTERM: returns once none but the leader
/// (still unreaped, so possibly a zombie) is left in the group, or at the deadline.
private func waitUntilGroupHoldsOnly(leader: pid_t, until deadline: ContinuousClock.Instant) {
    while ContinuousClock.now < deadline, groupHasOtherMembers(leader: leader) {
        usleep(20_000)
    }
}

/// Whether the process group that `leader` leads holds any process besides it. A list that cannot be read counts
/// as yes: the caller then waits out its grace and sends SIGKILL to the group either way.
private func groupHasOtherMembers(leader: pid_t) -> Bool {
    var members = [pid_t](repeating: 0, count: 256)
    let bytes = proc_listpids(
        UInt32(PROC_PGRP_ONLY), UInt32(leader), &members, Int32(members.count * MemoryLayout<pid_t>.size))
    guard bytes >= 0 else { return true }
    return members.prefix(Int(bytes) / MemoryLayout<pid_t>.size).contains { $0 != 0 && $0 != leader }
}

/// Collects the exit status of a command that has exited.
private func reap(_ pid: pid_t, command: [String]) throws -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        guard errno == EINTR else { throw SpawnError(call: "waitpid", code: errno, command: command) }
    }
    return exitCode(fromWaitStatus: status)
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
