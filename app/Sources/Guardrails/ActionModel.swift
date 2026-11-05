import Foundation
import GuardrailsCore
import LocalAuthentication
import Observation

/// One run of `guardrails approve|on|off` in a pseudo-terminal. The review screen shows the plan the CLI
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
    var isRunning: Bool {
        switch phase {
        case .preparing, .awaitingConfirmation, .verifyingOwner, .working: true
        case .succeeded, .failed, .cancelled: false
        }
    }

    func run() async {
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
            phase = .awaitingConfirmation(pending)
            return
        }
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
                try await Task.sleep(for: .seconds(2))
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
        case .event(.plan(let announced)):
            plan = announced
        case .event(.confirm(let pending)):
            phase = .awaitingConfirmation(pending)
        case .invalidEvent(let error):
            stop(with: error.description)
        case .exited(let code):
            switch phase {
            case .cancelled, .failed: return
            default: phase = code == 0 ? .succeeded : .failed(lastLines(of: log))
            }
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
