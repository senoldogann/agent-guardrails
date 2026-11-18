import AppKit
import GuardrailsCore
import ServiceManagement
import SwiftUI

/// Settings (⌘,): how the app runs on this Mac. What is enforced on GitHub is changed in the Projects window.
struct SettingsView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("General") {
                LoginItemToggle()
                RefreshPicker(model: model)
            }
            Section {
                NotificationSetting(shown: model.notificationsShown)
            } header: {
                Text("Notifications")
            } footer: {
                Text("New approvals, alarms and the agent's questions. Clicking one opens what it is about.")
            }
            Section("Projects") {
                ProjectsFolderSetting()
            }
            Section("Activity") {
                ActivitySetting(activity: model.activity)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Kit install") {
                    Text(kitPath).font(.mono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Button("Show the welcome checklist") {
                    model.workspace.show(.welcome)
                }
            }
        }
        .formStyle(.grouped)
        // Switches in graphite: the asset catalog's accent is a light gray for the sidebar selection.
        .tint(Palette.accent)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { bringWindowsForward() }
        .task { await model.recheckNotifications() }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(release) (\(build))"
    }

    private var kitPath: String {
        switch model.configuration {
        case .success(let configuration): configuration.kitPath
        case .failure(let error): error.description
        }
    }
}

/// Registers or removes the login item; on failure the switch goes back to what macOS reports.
struct LoginItemToggle: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Toggle("Open at login", isOn: $opensAtLogin)
            .onChange(of: opensAtLogin) { _, enabled in apply(enabled) }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(Palette.danger)
        }
    }

    private func apply(_ enabled: Bool) {
        let registered = SMAppService.mainApp.status == .enabled
        guard enabled != registered else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = "Could not change the login item: \(error.localizedDescription)"
            opensAtLogin = registered
        }
    }
}

struct RefreshPicker: View {
    let model: AppModel
    @AppStorage(RefreshInterval.key) private var minutes = RefreshInterval.standard

    var body: some View {
        Picker("Check GitHub every", selection: $minutes) {
            ForEach(RefreshInterval.choices, id: \.self) { choice in
                Text(choice == 1 ? "minute" : "\(choice) minutes").tag(choice)
            }
        }
        .onChange(of: minutes) { _, _ in
            Task { await model.refresh() }
        }
    }
}

struct NotificationSetting: View {
    let shown: Bool?

    var body: some View {
        LabeledContent("Shown by macOS") {
            HStack(spacing: 10) {
                switch shown {
                case true?: Label("On", systemImage: "bell").foregroundStyle(Palette.success)
                case false?: Label("Off", systemImage: "bell.slash").foregroundStyle(Palette.warning)
                case nil: ProgressView().controlSize(.small)
                }
                Button(shown == false ? "Allow…" : "Change…", action: openNotificationSettings)
            }
        }
    }
}

struct ProjectsFolderSetting: View {
    @State private var folder = ProjectsFolder.current

    var body: some View {
        LabeledContent("Clones folder") {
            HStack(spacing: 10) {
                Text(folder ?? "Not chosen yet")
                    .font(folder == nil ? .body : .mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folder == nil ? Palette.textSecondary : Palette.textPrimary)
                Button(folder == nil ? "Choose…" : "Change…") {
                    if let chosen = ProjectsFolder.choose() { folder = chosen }
                }
            }
        }
    }
}

struct ActivitySetting: View {
    let activity: ActivityLog

    var body: some View {
        LabeledContent("Entries on this Mac") {
            HStack(spacing: 10) {
                Text("\(activity.entries.count)").monospacedDigit()
                Button("Show in Finder") { activity.showInFinder() }.disabled(activity.entries.isEmpty)
            }
        }
        if let problem = activity.problem {
            Text(problem).font(.caption).foregroundStyle(Palette.danger)
        }
    }
}
