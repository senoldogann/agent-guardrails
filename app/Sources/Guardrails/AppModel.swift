import AppKit
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
    /// What the owner did in the app and what arrived for them, kept on this Mac.
    let activity = ActivityLog()
    private(set) var snapshot = InboxSnapshot.empty
    private(set) var loadState = LoadState.idle
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    /// Set when the owner clicks a notification; the menu bar label opens it and clears it.
    var pendingRoute: InboxRoute?
    /// False when macOS shows none of the app's notifications (denied, or alert style None); nil until known.
    private(set) var notificationsShown: Bool?
    private var hasLoadedOnce = false
    /// A refresh asked for while one runs: it runs again afterwards, so it reads what an action just changed.
    private var refreshesAgain = false
    /// The notification center keeps only a weak reference to its delegate.
    private var notificationDelegate: NotificationDelegate?

    init(configuration: Result<AppConfiguration, AppConfiguration.LoadError>) {
        self.configuration = configuration
        switch configuration {
        case .success(let found): projects = ProjectsModel(configuration: found)
        case .failure: projects = nil
        }
        let delegate = NotificationDelegate { [weak self] route in self?.pendingRoute = route }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
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
        guard case .success(let configuration) = configuration else { return }
        guard loadState != .loading else {
            refreshesAgain = true
            return
        }
        loadState = .loading
        defer {
            loadState = .idle
            if refreshesAgain {
                refreshesAgain = false
                Task { await refresh() }
            }
        }
        do {
            let result = try await runCommand(
                command: ["/bin/bash", configuration.cliPath, "inbox", "--json"],
                environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
            guard result.status == 0 else {
                lastError = describeCommandFailure(result, command: "guardrails inbox")
                return
            }
            let next = try parseInbox(result.standardOutput)
            if hasLoadedOnce {
                let arrived = newAttentionItems(previous: snapshot, current: next)
                notify(about: arrived)
                activity.record(arrivalEntries(arrived, at: Date()))
            }
            snapshot = next
            let waiting = waitingCount(next)
            // Shown while the app has its Dock icon (a window is open); the menu bar item shows the same count.
            NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
            notificationsShown = await notificationsAreShown()
            hasLoadedOnce = true
            lastError = nil
            lastUpdated = Date()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Asks macOS again whether it shows the app's notifications, e.g. after the owner changed the setting.
    func recheckNotifications() async {
        notificationsShown = await notificationsAreShown()
    }

    /// Logs how a Review window's action ended and refreshes what it changed.
    func actionFinished(_ action: ActionModel) {
        if let entry = activityEntry(for: action, at: Date()) { activity.record([entry]) }
        refreshSoon(repo: action.request.repo)
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

    /// Refreshes, then waits the interval chosen in Settings. The interval is read again every half minute, so
    /// a shorter one takes effect without waiting out the old one.
    private func runRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            let started = Date()
            while Date().timeIntervalSince(started) < Double(RefreshInterval.minutes * 60) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    private func notify(about items: [InboxItem]) {
        for item in items {
            let text = notificationText(for: item)
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            do {
                content.userInfo = [notificationItemKey: try JSONEncoder().encode(item)]
            } catch {
                NSLog("Guardrails: could not attach the inbox item to its notification: %@", String(describing: error))
            }
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            Task {
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    NSLog("Guardrails: notification %@ was not added: %@", item.id, String(describing: error))
                }
            }
        }
    }
}

/// Whether macOS shows the app's notifications at all: allowed, with an alert style other than None.
private func notificationsAreShown() async -> Bool {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    return allowed && settings.alertStyle != .none
}

/// System Settings › Notifications, at this app's page.
func openNotificationSettings() {
    guard let id = Bundle.main.bundleIdentifier,
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    else { return }
    NSWorkspace.shared.open(url)
}

private let notificationItemKey = "inboxItem"

/// Shows notifications while the app is in front (a window is open) and routes a click to the item's action.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let follow: @MainActor @Sendable (InboxRoute) -> Void

    init(follow: @escaping @MainActor @Sendable (InboxRoute) -> Void) {
        self.follow = follow
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let data = response.notification.request.content.userInfo[notificationItemKey] as? Data else {
            NSLog("Guardrails: a notification without its inbox item was clicked")
            return
        }
        do {
            await follow(inboxRoute(for: try JSONDecoder().decode(InboxItem.self, from: data)))
        } catch {
            NSLog("Guardrails: could not read a clicked notification's inbox item: %@", String(describing: error))
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

/// How often the inbox is loaded, set in Settings.
enum RefreshInterval {
    static let key = "refreshMinutes"
    static let choices = [1, 5, 15, 30]
    static let standard = 5

    static var minutes: Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return choices.contains(stored) ? stored : standard
    }
}

/// Whether gh is signed in to github.com: `gh auth status` exits 0 only then.
func githubIsSignedIn() async throws -> Bool {
    let result = try await runCommand(
        command: ["/usr/bin/env", "gh", "auth", "status", "--hostname", "github.com"],
        environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
    return result.status == 0
}
