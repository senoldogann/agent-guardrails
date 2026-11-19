import AppKit
import GuardrailsCore
import SwiftUI

@main
struct GuardrailsApp: App {
    @State private var model = AppModel(configuration: AppConfiguration.fromMainBundle())

    init() {
        // Writing to a CLI that already exited must fail with EPIPE (and be reported), not kill the app.
        signal(SIGPIPE, SIG_IGN)
        DockPresence.observeWindowClosing()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // Every page opens in this one window, in tabs: repositories, pull requests, reviews, settings and the
        // welcome checklist.
        Window("Guardrails", id: WindowID.main) {
            ProjectsWindow(model: model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }
    }
}

enum WindowID {
    static let main = "main"
}

/// Settings… (⌘,) opens the Settings page in the main window instead of a window of its own.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.workspace.show(.settings)
                openMainWindow(openWindow)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// Opens (or brings forward) the main window; the caller has already chosen its page.
@MainActor
func openMainWindow(_ openWindow: OpenWindowAction) {
    openWindow(id: WindowID.main)
    activateApp()
}

/// The Projects window, or what to fix when the app does not know where the kit is.
struct ProjectsWindow: View {
    let model: AppModel

    var body: some View {
        if let projects = model.projects {
            MainWindow(model: model, projects: projects)
        } else {
            StatusPanel(symbol: .tools, title: "Setup needed", message: model.setupProblem ?? "")
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
        let symbol: Octicon = snapshot.alarms.isEmpty ? .shieldCheck : .shieldX
        let count = waitingCount(snapshot)
        HStack(spacing: 3) {
            // The menu bar draws the 16-point template image itself, in the menu bar's own color.
            Image(nsImage: symbol.image)
            if count > 0 { Text("\(count)") }
        }
        .onChange(of: model.pendingRoute) { _, route in
            guard let route else { return }
            model.pendingRoute = nil
            follow(route)
        }
        .task {
            applyAppearance(storedAppearance())
            // The first launch opens the welcome checklist; closing it once is enough.
            guard !UserDefaults.standard.bool(forKey: Onboarding.completedKey) else { return }
            model.workspace.show(.welcome)
            openMainWindow(openWindow)
        }
    }

    private func follow(_ route: InboxRoute) {
        switch route {
        case .review(let url, let title):
            model.openReview(ActionRequest(kind: .approve, target: url, label: title))
        case .update:
            model.openReview(ActionRequest(kind: .update, target: "", label: "the kit install"))
        case .browser(let url):
            openInBrowser(url)
            return
        case .projects:
            model.workspace.show(.overview)
        }
        openMainWindow(openWindow)
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
