import AppKit
import GuardrailsCore
import SwiftUI

@main
struct GuardrailsApp: App {
    @State private var model = AppModel(configuration: AppConfiguration.fromMainBundle())

    init() {
        DockPresence.observeWindowClosing()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model).tint(Palette.accent)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Guardrails", id: WindowID.projects) {
            ProjectsWindow(model: model).tint(Palette.accent)
        }
        .defaultSize(width: 980, height: 660)

        WindowGroup("Review", id: WindowID.review, for: ActionRequest.self) { $request in
            if let request, case .success(let configuration) = model.configuration {
                ReviewView(request: request, configuration: configuration) { model.actionFinished($0) }
                    .tint(Palette.accent)
            }
        }
        .defaultSize(width: 640, height: 780)

        WindowGroup("Pull Request", id: WindowID.pullRequest, for: PullRequestRef.self) { $ref in
            if let ref {
                PullRequestWindow(ref: ref, model: model).tint(Palette.accent)
            }
        }
        .defaultSize(width: 820, height: 860)

        Window("Welcome to Guardrails", id: WindowID.welcome) {
            OnboardingView(model: model).tint(Palette.accent)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model).tint(Palette.accent)
        }
    }
}

enum WindowID {
    static let projects = "projects"
    static let review = "review"
    static let welcome = "welcome"
    static let pullRequest = "pull-request"
}

/// The Projects window, or what to fix when the app does not know where the kit is.
struct ProjectsWindow: View {
    let model: AppModel

    var body: some View {
        if let projects = model.projects {
            ProjectsView(model: model, projects: projects)
        } else {
            StatusPanel(symbol: "wrench.and.screwdriver", title: "Setup needed", message: model.setupProblem ?? "")
                .padding(Metrics.windowPadding)
                .frame(minWidth: 480, minHeight: 200)
        }
    }
}

/// Shape, not only color, carries the state: a plain shield when quiet, a filled warning shield on alarms.
/// The label is the one view that exists all the time, so it also opens what a clicked notification asks for.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snapshot = model.snapshot
        let symbol = snapshot.alarms.isEmpty ? "checkmark.shield" : "exclamationmark.shield.fill"
        let count = waitingCount(snapshot)
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if count > 0 { Text("\(count)") }
        }
        .onChange(of: model.pendingRoute) { _, route in
            guard let route else { return }
            model.pendingRoute = nil
            follow(route)
        }
        .task {
            // The first launch opens the welcome checklist; closing it once is enough.
            guard !UserDefaults.standard.bool(forKey: Onboarding.completedKey) else { return }
            openWindow(id: WindowID.welcome)
            activateApp()
        }
    }

    private func follow(_ route: InboxRoute) {
        switch route {
        case .review(let url, let title):
            openWindow(id: WindowID.review, value: ActionRequest(kind: .approve, target: url, label: title))
        case .update:
            openWindow(id: WindowID.review, value: ActionRequest(kind: .update, target: "", label: "the kit install"))
        case .browser(let url):
            openInBrowser(url)
            return
        case .projects:
            openWindow(id: WindowID.projects)
        }
        activateApp()
    }
}

/// Brings the app forward when it opens a window from the menu bar.
@MainActor
func activateApp() {
    NSApp.activate()
}

/// Called when a window appears: the app shows its Dock icon and activates only once the window exists,
/// otherwise a menu bar app's new window can open behind the frontmost app.
@MainActor
func bringWindowsForward() {
    Task { @MainActor in
        DockPresence.show()
        NSApp.activate()
        for window in NSApp.windows where window.isVisible && window.canBecomeKey {
            window.orderFrontRegardless()
        }
    }
}

/// The app lives in the menu bar (LSUIElement), but while the Projects or a Review window is open it is a
/// regular app: a Dock icon and a place in Cmd-Tab, so a window that went behind others can be found again.
/// The icon goes away with the last of those windows; a minimized one keeps it.
@MainActor
enum DockPresence {
    static func show() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Registered once at launch; hides the Dock icon when the closing window was the last app window.
    static func observeWindowClosing() {
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            let closing = notification.object as? NSWindow
            MainActor.assumeIsolated { hideIfLastWindow(closing: closing) }
        }
    }

    private static func hideIfLastWindow(closing: NSWindow?) {
        let remaining = NSApp.windows.filter { window in
            window !== closing && isAppWindow(window) && (window.isVisible || window.isMiniaturized)
        }
        if remaining.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Titled windows the app opened (Projects, Review), not the menu bar panel.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }
}
