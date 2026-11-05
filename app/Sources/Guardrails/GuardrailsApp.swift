import AppKit
import GuardrailsCore
import SwiftUI

@main
struct GuardrailsApp: App {
    @State private var model = AppModel(configuration: AppConfiguration.fromMainBundle())

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("Guardrails", id: WindowID.repositories) {
            ReposView(model: model)
        }
        .defaultSize(width: 680, height: 560)

        WindowGroup("Review", id: WindowID.review, for: ActionRequest.self) { $request in
            if let request, case .success(let configuration) = model.configuration {
                ReviewView(request: request, configuration: configuration) { model.refreshSoon() }
            }
        }
        .defaultSize(width: 560, height: 660)
    }
}

enum WindowID {
    static let repositories = "repositories"
    static let review = "review"
}

/// Shape, not only color, carries the state: a plain shield when quiet, a filled warning shield on alarms.
struct MenuBarLabel: View {
    let snapshot: InboxSnapshot

    var body: some View {
        let symbol = snapshot.alarms.isEmpty ? "checkmark.shield" : "exclamationmark.shield.fill"
        let count = snapshot.approvals.count + snapshot.answers.count
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if count > 0 { Text("\(count)") }
        }
    }
}

/// Brings the app forward when it opens a window from the menu bar (the app has no Dock icon).
@MainActor
func activateApp() {
    NSApp.activate()
}

/// Called when a window appears: the app activates only once the window exists, otherwise a menu bar app's
/// new window can open behind the frontmost app.
@MainActor
func bringWindowsForward() {
    Task { @MainActor in
        NSApp.activate()
        for window in NSApp.windows where window.isVisible && window.canBecomeKey {
            window.orderFrontRegardless()
        }
    }
}
