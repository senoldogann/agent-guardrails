import GuardrailsCore
import SwiftUI

/// Sets a project up: finds or clones it into the projects folder, then opens Terminal with Claude Code
/// running /guardrails-init. Nothing is enforced yet; the owner turns it on after the bootstrap PR appears.
struct SetupSheet: View {
    let project: Project
    let onLaunched: () -> Void
    @State private var model: SetupModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up \(project.name)").font(.displayTitle).tracking(-0.3)
            Text("Claude adds the guardrails kit in Terminal and opens a bootstrap PR. You stay in control: it runs with its normal permission prompts, and nothing is enforced until you turn it on.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let model {
                FolderStep(model: model)
                CloneStep(model: model)
            }
            Spacer(minLength: 0)
            SetupActions(model: model, dismiss: { dismiss() }, onLaunched: onLaunched)
        }
        .padding(Metrics.windowPadding)
        .frame(width: 520, height: 440)
        .task {
            let created = SetupModel(project: project)
            model = created
            await created.check()
        }
    }
}

struct FolderStep: View {
    let model: SetupModel

    var body: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Projects folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                    Text(model.folder ?? "Not chosen yet").font(.mono).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(model.folder == nil ? "Choose…" : "Change…") {
                    Task { await model.chooseFolder() }
                }
                .secondaryAction()
            }
        }
    }
}

struct CloneStep: View {
    let model: SetupModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local clone").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                if let path = model.targetPath {
                    Text(path).font(.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                CloneStatus(step: model.step, branch: model.project.branch)
            }
        }
    }
}

struct CloneStatus: View {
    let step: SetupModel.Step
    let branch: String

    var body: some View {
        switch step {
        case .needsFolder:
            Text("Choose the folder that holds your clones.").font(.caption).foregroundStyle(Palette.textSecondary)
        case .checking, .cloning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step == .cloning ? "Cloning…" : "Checking…").font(.caption)
            }
        case .clone(.missing):
            Text("No clone here yet. Clone it to start.").font(.caption).foregroundStyle(Palette.textSecondary)
        case .clone(.ready):
            Label("Clean clone on \(branch), origin matches", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Palette.success)
        case .clone(.problem(let message)), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        case .launched:
            Label("Terminal opened. Follow Claude there.", systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(Palette.success)
        }
    }
}

struct SetupActions: View {
    let model: SetupModel?
    let dismiss: () -> Void
    let onLaunched: () -> Void

    var body: some View {
        HStack {
            Button(model?.step == .launched ? "Done" : "Cancel", action: dismiss)
                .secondaryAction()
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let model {
                switch model.step {
                case .clone(.missing):
                    Button("Clone") { Task { await model.cloneRepository() } }
                        .primaryAction()
                case .clone(.ready):
                    Button {
                        Task {
                            await model.launchSetup()
                            if model.step == .launched { onLaunched() }
                        }
                    } label: {
                        Label("Open Terminal and set up", systemImage: "terminal")
                    }
                    .primaryAction()
                case .clone(.problem), .failed:
                    Button("Check again") { Task { await model.check() } }
                        .secondaryAction()
                case .needsFolder, .checking, .cloning, .launched:
                    EmptyView()
                }
            }
        }
    }
}
