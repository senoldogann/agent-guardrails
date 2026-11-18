import Darwin
import Foundation

/// What a running CLI produced: terminal text (for the details log), a structured event, or its exit.
public enum SessionOutput: Sendable, Equatable {
    case terminal(String)
    case event(CLIEvent)
    case invalidEvent(EventParseError)
    case exited(Int32)
}

extension EventParseError: Equatable {
    public static func == (lhs: EventParseError, rhs: EventParseError) -> Bool {
        lhs.line == rhs.line && lhs.reason == rhs.reason
    }
}

public struct SpawnError: Error, CustomStringConvertible {
    public let call: String
    public let code: Int32
    public let command: [String]

    public var description: String {
        "\(call) failed (\(String(cString: strerror(code)))) for: \(command.joined(separator: " "))"
    }
}

/// The descriptor the CLI writes its JSON events to (see GUARDRAILS_EVENTS_FD in bin/guardrails).
public let eventsDescriptor: Int32 = 3

/// Runs a command with stdin/stdout/stderr on pipes and descriptor 3 on a separate events pipe.
/// Foundation's Process closes every descriptor above 2, so this uses posix_spawn directly.
/// Not Sendable: own it from one actor and read `output` there.
public final class TerminalSession {
    public let output: AsyncStream<SessionOutput>
    private let pid: pid_t
    private var inputDescriptor: Int32

    public init(command: [String], environment: [String: String]) throws {
        let input = try makePipe(command: command)
        let terminal: (read: Int32, write: Int32)
        let events: (read: Int32, write: Int32)
        do {
            terminal = try makePipe(command: command)
        } catch {
            closeAll([input.read, input.write])
            throw error
        }
        do {
            events = try makePipe(command: command)
        } catch {
            closeAll([input.read, input.write, terminal.read, terminal.write])
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input.read, 0)
        posix_spawn_file_actions_adddup2(&actions, terminal.write, 1)
        posix_spawn_file_actions_adddup2(&actions, terminal.write, 2)
        posix_spawn_file_actions_adddup2(&actions, events.write, eventsDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors above survive; the child gets its own process group so cancel reaches all of it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, command[0], &actions, &attributes, argv, envp)
        close(input.read)
        close(terminal.write)
        close(events.write)
        guard status == 0 else {
            close(input.write)
            close(terminal.read)
            close(events.read)
            throw SpawnError(call: "posix_spawn", code: status, command: command)
        }
        pid = childPID
        inputDescriptor = input.write

        let (stream, continuation) = AsyncStream.makeStream(of: SessionOutput.self)
        output = stream
        let readers = DispatchGroup()
        let terminalRead = terminal.read
        let eventsRead = events.read

        readers.enter()
        Thread.detachNewThread {
            // A chunk can end inside a multi-byte character; its first bytes wait for the next chunk.
            var cutOff = Data()
            readChunks(from: terminalRead) { chunk in
                let (whole, rest) = splitAtLastWholeCharacter(cutOff + chunk)
                cutOff = rest
                if !whole.isEmpty { continuation.yield(.terminal(String(decoding: whole, as: UTF8.self))) }
            }
            if !cutOff.isEmpty { continuation.yield(.terminal(String(decoding: cutOff, as: UTF8.self))) }
            close(terminalRead)
            readers.leave()
        }
        readers.enter()
        Thread.detachNewThread {
            var pending = Data()
            readChunks(from: eventsRead) { chunk in
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    do {
                        continuation.yield(.event(try parseEvent(line)))
                    } catch let error as EventParseError {
                        continuation.yield(.invalidEvent(error))
                    } catch {
                        continuation.yield(.invalidEvent(EventParseError(line: line, reason: String(describing: error))))
                    }
                }
            }
            close(eventsRead)
            readers.leave()
        }
        let spawned = childPID
        Thread.detachNewThread {
            var waitStatus: Int32 = 0
            while waitpid(spawned, &waitStatus, 0) == -1, errno == EINTR {}
            readers.wait()
            continuation.yield(.exited(exitCode(fromWaitStatus: waitStatus)))
            continuation.finish()
        }
    }

    deinit {
        closeInput()
    }

    /// Types text into the terminal the CLI reads its confirmation from.
    public func send(_ text: String) throws {
        guard inputDescriptor >= 0 else {
            throw SpawnError(call: "write (input already closed)", code: EBADF, command: [])
        }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(inputDescriptor, base + offset, buffer.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw SpawnError(call: "write", code: errno, command: [])
            }
            offset += written
        }
    }

    /// Ends the input: script(1) sends end-of-file, the CLI's `read` fails and it stops without changing anything.
    public func closeInput() {
        guard inputDescriptor >= 0 else { return }
        close(inputDescriptor)
        inputDescriptor = -1
    }

    /// Stops the whole process group.
    public func terminate() {
        kill(-pid, SIGTERM)
    }
}

private func makePipe(command: [String]) throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw SpawnError(call: "pipe", code: errno, command: command) }
    return (descriptors[0], descriptors[1])
}

private func readChunks(from descriptor: Int32, handle: (Data) -> Void) {
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
            handle(Data(buffer[0..<count]))
        } else if count < 0, errno == EINTR {
            continue
        } else {
            return
        }
    }
}

/// The exit code of a waitpid status, or 128 + signal number when the process was killed.
public func exitCode(fromWaitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

/// Closes descriptors of a session that could not be started.
private func closeAll(_ descriptors: [Int32]) {
    for descriptor in descriptors { close(descriptor) }
}

/// Splits bytes read from a stream into the part that ends on a whole UTF-8 character and the first bytes of a
/// character cut off at the end, which belong in front of the next chunk.
public func splitAtLastWholeCharacter(_ data: Data) -> (whole: Data, rest: Data) {
    let bytes = [UInt8](data)
    var start = bytes.count - 1
    while start >= 0, bytes.count - start <= 4, bytes[start] & 0xC0 == 0x80 { start -= 1 }
    guard start >= 0 else { return (data, Data()) }
    let lead = bytes[start]
    let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
    guard bytes.count - start < length else { return (data, Data()) }
    return (Data(bytes[..<start]), Data(bytes[start...]))
}
