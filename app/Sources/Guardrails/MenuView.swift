import AppKit
import GuardrailsCore
import ServiceManagement
import SwiftUI

/// The menu bar panel: what waits for the owner, in a fixed order (alarms, approve, turn on, answer).
struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let problem = model.setupProblem {
                StatusPanel(symbol: "wrench.and.screwdriver", title: "Setup needed", message: problem)
            } else {
                content
            }
            footer
        }
        .padding(Metrics.popoverPadding)
        .frame(width: 390)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Guardrails").font(.displayTitle).tracking(-0.3)
                Text(updatedText).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.loadState == .loading ? 180 : 0))
                    .animation(.easeInOut(duration: 0.4), value: model.loadState)
            }
            .buttonStyle(.glass)
            .disabled(model.loadState == .loading)
            .help("Refresh")
        }
    }

    private var updatedText: String {
        if model.loadState == .loading, model.lastUpdated == nil { return "Loading…" }
        guard let updated = model.lastUpdated else { return "Not loaded yet" }
        return "Updated \(updated.formatted(date: .omitted, time: .shortened))"
    }

    private var content: some View {
        ScrollView {
            InboxList(model: model, open: open)
        }
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Button("Projects") {
                    openWindow(id: WindowID.projects)
                    activateApp()
                }
                .buttonStyle(SecondaryPillStyle())
                Spacer()
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in applyOpensAtLogin(enabled) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            if let loginItemProblem {
                Text(loginItemProblem).font(.caption).foregroundStyle(Palette.danger)
            }
        }
    }

    /// Registers or removes the login item; on failure the switch goes back to what macOS reports.
    private func applyOpensAtLogin(_ enabled: Bool) {
        let registered = SMAppService.mainApp.status == .enabled
        guard enabled != registered else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemProblem = nil
        } catch {
            loginItemProblem = "Could not change the login item: \(error.localizedDescription)"
            opensAtLogin = registered
        }
    }

    private func open(_ request: ActionRequest) {
        openWindow(id: WindowID.review, value: request)
        activateApp()
    }
}

/// The inbox in the menu panel.
struct InboxList: View {
    let model: AppModel
    let open: (ActionRequest) -> Void

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 12) {
            InboxProblems(error: model.lastError, alarms: snapshot.alarms) {
                open(ActionRequest(kind: .update, target: "", label: "the kit install"))
            }
            ItemSection(title: "Approve", items: snapshot.approvals, actionTitle: "Review", disabled: snapshot.hasKitInstallAlarm) {
                open(ActionRequest(kind: .approve, target: $0.url, label: $0.title))
            }
            ItemSection(title: "Turn on", items: snapshot.turnOns, actionTitle: "Turn on", disabled: snapshot.hasKitInstallAlarm) {
                open(ActionRequest(kind: .turnOn, target: $0.url, label: $0.title))
            }
            ItemSection(title: "The agent asks", items: snapshot.answers, actionTitle: "Open", disabled: false) {
                openInBrowser($0.url)
            }
            InboxFooterNote(
                inProgress: snapshot.inProgress.count,
                showsQuiet: snapshot.isQuiet && model.lastError == nil && model.lastUpdated != nil,
                hasRepos: !snapshot.repos.isEmpty)
        }
    }
}

struct InboxProblems: View {
    let error: String?
    let alarms: [InboxItem]
    let update: () -> Void

    var body: some View {
        if let error {
            StatusPanel(symbol: "wifi.exclamationmark", title: "Could not refresh", message: error)
        }
        ForEach(alarms) { alarm in
            // The CLI marks the "kit install is behind its origin main" alarm with the title "update".
            if alarm.repo.isEmpty, alarm.title == "update" {
                UpdateBanner(update: update)
            } else {
                AlarmBanner(text: alarm.note)
            }
        }
    }
}

/// The kit install is behind its origin main: approvals wait until it is updated.
struct UpdateBanner: View {
    let update: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("A kit update is available").font(.system(size: 13, weight: .semibold))
                Text("Approvals and turning repos on or off wait until you update.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Update", action: update).buttonStyle(PrimaryPillStyle())
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius)
                .fill(Palette.surfaceMuted)
                .strokeBorder(Palette.hairline))
    }
}

struct ItemSection: View {
    let title: String
    let items: [InboxItem]
    let actionTitle: String
    let disabled: Bool
    let action: (InboxItem) -> Void

    var body: some View {
        if !items.isEmpty {
            SectionLabel(text: title)
            ForEach(items) { item in
                ItemRow(item: item, actionTitle: actionTitle, disabled: disabled) { action(item) }
            }
        }
    }
}

struct InboxFooterNote: View {
    let inProgress: Int
    let showsQuiet: Bool
    let hasRepos: Bool

    var body: some View {
        if inProgress > 0 {
            Text("\(inProgress) in progress").font(.caption).foregroundStyle(Palette.textSecondary)
        }
        if showsQuiet {
            QuietState(hasRepos: hasRepos)
        }
    }
}

struct ItemRow: View {
    let item: InboxItem
    let actionTitle: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(item.note.isEmpty ? item.repo : "\(item.repo) · \(item.note)")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .buttonStyle(PrimaryPillStyle())
                .disabled(disabled)
                .help(disabled ? "The kit install has an alarm; on, off and approve refuse until it is fixed." : "")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
    }
}

struct StatusPanel: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
    }
}

struct QuietState: View {
    let hasRepos: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.textSecondary)
            Text("Nothing waits for you").font(.system(size: 14, weight: .medium))
            Text(
                hasRepos
                    ? "New approvals show up here and as a notification."
                    : "No enforced repos yet. Ask your agent for /guardrails-init in a project; its PR appears here to turn on."
            )
            .font(.caption)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

func openInBrowser(_ link: String) {
    guard let url = URL(string: link), url.scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}
