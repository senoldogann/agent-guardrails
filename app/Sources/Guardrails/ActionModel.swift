import AppKit
import Foundation
import GuardrailsCore
import LocalAuthentication
import Observation

/// One run of `guardrails approve|on|off|update|agent create` in a pseudo-terminal. The review screen shows the plan the CLI
/// announced; each confirmation is checked against that plan and needs Touch ID (or the login password).
@MainActor
@Observable
final class ActionModel {
    enum Phase: Equatable {
        case preparing
        case awaitingConfirmation(ConfirmRequest)
        case verifyingOwner(ConfirmRequest)
        case working
        case succeeded
        case failed(String)
        case cancelled
    }

    let request: ActionRequest
    private(set) var phase = Phase.preparing
    private(set) var plan: Plan?
    private(set) var log = ""
    private(set) var diffOpened = false
    private(set) var canCancel = true
    private(set) var ownerCheckProblem: String?
    private let configuration: AppConfiguration
    private var session: TerminalSession?

    init(request: ActionRequest, configuration: AppConfiguration) {
        self.request = request
        self.configuration = configuration
    }

    var needsDiffReview: Bool { plan?.pullRequest?.needsDiffReview ?? false }

    /// Where the run stands, as the chain of gates shows it.
    var progress: ActionProgress {
        switch phase {
        case .preparing: .preparing
        case .awaitingConfirmation, .verifyingOwner: .awaiting
        case .working: .working
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
    var isRunning: Bool {
        switch phase {
        case .preparing, .awaitingConfirmation, .verifyingOwner, .working: true
        case .succeeded, .failed, .cancelled: false
        }
    }

    /// Starts the run outside the window's lifetime: closing the window after the final confirmation must not
    /// stop reading the CLI, or the outcome would be lost while the merge or approval goes on.
    func start(onFinish: @escaping @MainActor (ActionModel) -> Void) {
        Task {
            await self.run()
            onFinish(self)
        }
    }

    private func run() async {
        let started: TerminalSession
        do {
            started = try TerminalSession(
                command: terminalCommand(cliPath: configuration.cliPath, arguments: request.arguments),
                environment: cliEnvironment(
                    inherited: ProcessInfo.processInfo.environment, eventsDescriptor: eventsDescriptor))
        } catch {
            phase = .failed("Could not start guardrails: \(error)")
            return
        }
        session = started
        for await output in started.output {
            handle(output)
        }
    }

    func markDiffOpened() {
        diffOpened = true
    }

    /// Checks the pending confirmation against the plan, asks for Touch ID, then types it for the CLI.
    func confirm() async {
        guard case .awaitingConfirmation(let pending) = phase, let plan else { return }
        let answer: String
        do {
            answer = try confirmationAnswer(for: pending, plan: plan)
        } catch {
            stop(with: "Stopped without changing anything: \(error)")
            return
        }
        phase = .verifyingOwner(pending)
        ownerCheckProblem = nil
        do {
            try await verifyOwner(reason: ownerCheckReason(for: pending, plan: plan))
        } catch {
            ownerCheckProblem = error.localizedDescription
            if phase == .verifyingOwner(pending) { phase = .awaitingConfirmation(pending) }
            return
        }
        // The owner may have cancelled, or the CLI may have stopped, while the Touch ID prompt was open.
        guard phase == .verifyingOwner(pending) else { return }
        if isFinalConfirmation(pending, plan: plan) { canCancel = false }
        do {
            try session?.send(answer + "\n")
        } catch {
            stop(with: "Could not send the confirmation to guardrails: \(error)")
            return
        }
        phase = .working
    }

    func cancel() {
        guard canCancel, isRunning else { return }
        phase = .cancelled
        session?.closeInput()
        let session = session
        Task {
            do {
                try await Task.sleep(for: cancelGracePeriod)
            } catch {
                return
            }
            session?.terminate()
        }
    }

    private func handle(_ output: SessionOutput) {
        switch output {
        case .terminal(let text):
            log += text.replacingOccurrences(of: "\r", with: "")
        case .event:
            // After Cancel or a stop the CLI may still announce its next step; it must not bring the buttons back.
            guard isRunning else { return }
            handleEvent(output)
        case .invalidEvent(let error):
            guard isRunning else { return }
            stop(with: error.description)
        case .exited(let code):
            switch phase {
            case .cancelled, .failed: return
            default: phase = code == 0 ? .succeeded : .failed(lastLines(of: log))
            }
            if code == 0, request.kind == .update { relaunchAfterUpdate() }
        }
    }

    private func handleEvent(_ output: SessionOutput) {
        switch output {
        case .event(.plan(let announced)):
            // One run announces one plan; a second one could change what the owner already read.
            guard plan == nil else {
                stop(with: "guardrails announced a second plan; stopped without confirming anything.")
                return
            }
            if announced.leavesReviewMode {
                stop(with: "\(ConfirmationError.leavesReviewMode(repo: announced.repo)); stopped without confirming anything.")
                return
            }
            if request.kind == .turnOnMergeQueue {
                guard case .turnOnRepo(let repoPlan) = announced, repoPlan.withMergeQueue, repoPlan.repo == request.target else {
                    stop(with: "guardrails did not plan to turn on the merge queue for \(request.target); stopped without confirming anything.")
                    return
                }
            }
            plan = announced
        case .event(.confirm(let pending)):
            phase = .awaitingConfirmation(pending)
        default:
            return
        }
    }

    /// The update rebuilt and replaced this app on disk; start the new copy and quit this one.
    private func relaunchAfterUpdate() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The new copy starts after this one has quit (relaunchDelay > quitDelay), so macOS opens a fresh process.
        relaunch.arguments = ["-c", "sleep \(relaunchDelaySeconds); exec /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try relaunch.run()
        } catch {
            phase = .failed("Updated, but could not restart Guardrails (\(error)). Quit and open it again.")
            return
        }
        Task {
            do {
                try await Task.sleep(for: quitDelay)
            } catch {
                return
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private func stop(with message: String) {
        phase = .failed(message)
        canCancel = false
        session?.closeInput()
        session?.terminate()
    }
}

private func lastLines(of log: String) -> String {
    let lines = log.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return lines.suffix(6).joined(separator: "\n")
}

/// After Cancel the CLI gets this long to stop on its own (its input is closed) before it is terminated.
private let cancelGracePeriod = Duration.seconds(2)
/// After an update this copy quits after quitDelay; the rebuilt copy is opened after relaunchDelaySeconds.
private let quitDelay = Duration.seconds(1)
private let relaunchDelaySeconds = 2

/// Touch ID, or the login password where Touch ID is not available. A new context per check, with no
/// reuse window, so one touch never covers a second step.
private func verifyOwner(reason: String) async throws {
    let context = LAContext()
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var availability: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else {
        throw availability ?? LAError(.biometryNotAvailable)
    }
    _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
}
