import Foundation
import GuardrailsCore
import Observation
import UserNotifications

/// The inbox: loads `guardrails inbox --json` on launch, every five minutes and on demand.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle
        case loading
    }

    let configuration: Result<AppConfiguration, AppConfiguration.LoadError>
    /// The Projects window's data; nil when the app does not know where the kit is.
    let projects: ProjectsModel?
    private(set) var snapshot = InboxSnapshot.empty
    private(set) var loadState = LoadState.idle
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private var hasLoadedOnce = false

    init(configuration: Result<AppConfiguration, AppConfiguration.LoadError>) {
        self.configuration = configuration
        switch configuration {
        case .success(let found): projects = ProjectsModel(configuration: found)
        case .failure: projects = nil
        }
        Task { await self.runRefreshLoop() }
        Task { await requestNotificationPermission() }
    }

    var setupProblem: String? {
        switch configuration {
        case .success: nil
        case .failure(let error): error.description
        }
    }

    func refresh() async {
        guard case .success(let configuration) = configuration, loadState != .loading else { return }
        loadState = .loading
        defer { loadState = .idle }
        do {
            let result = try await runCommand(
                command: ["/bin/bash", configuration.cliPath, "inbox", "--json"],
                environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
            guard result.status == 0 else {
                lastError = describeFailure(result)
                return
            }
            let next = try parseInbox(result.standardOutput)
            if hasLoadedOnce {
                notify(about: newApprovals(previous: snapshot, current: next))
            }
            snapshot = next
            hasLoadedOnce = true
            lastError = nil
            lastUpdated = Date()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Refreshes the inbox and the projects shortly after an action, once GitHub reflects it.
    func refreshSoon(repo: String) {
        Task {
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            await refresh()
            await projects?.loadProjects()
            await projects?.reloadPullRequests(of: repo)
        }
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
        }
    }

    private func describeFailure(_ result: CommandResult) -> String {
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("gh auth login") || message.contains("not logged") {
            return "GitHub CLI is not signed in. Run gh auth login in your terminal, then refresh."
        }
        if message.contains("Could not resolve host") || message.contains("error connecting") {
            return "Offline: GitHub cannot be reached. Showing the last known state."
        }
        return message.isEmpty ? "guardrails inbox exited with status \(result.status)" : message
    }

    private func notify(about approvals: [InboxItem]) {
        for item in approvals {
            let content = UNMutableNotificationContent()
            content.title = "Waiting for your approval"
            content.body = "\(item.repo): \(item.title)"
            content.sound = .default
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

private func requestNotificationPermission() async {
    do {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    } catch {
        // Notifications are optional: without permission the menu bar count still shows waiting approvals.
        NSLog("Guardrails: notification permission request failed: %@", String(describing: error))
    }
}
