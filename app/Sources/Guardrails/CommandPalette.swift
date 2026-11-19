import GuardrailsCore
import SwiftUI

/// ⌘K: one field over everything the window can show — the pages, every repository, the pages already open.
/// The queue in the sidebar answers "what waits"; this answers "take me there".
struct CommandPalette: View {
    let model: AppModel
    let projects: ProjectsModel
    @Binding var isShown: Bool

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { isShown = false }
            panel
                .padding(.top, 84)
        }
        .onExitCommand { isShown = false }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Go to a repository or a page", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit(activate)
                    .onKeyPress(.downArrow) { move(by: 1); return .handled }
                    .onKeyPress(.upArrow) { move(by: -1); return .handled }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if items.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture { highlighted = index; activate() }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
                }
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text("↑↓ move · ↵ open · esc close")
                Spacer()
                Text("\(items.count) results")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(Palette.hairline)
        )
        .task { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 9) {
            OcticonImage(icon: item.icon, size: 13)
                .foregroundStyle(isHighlighted ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: 16)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius)
                .fill(isHighlighted ? Palette.hairline : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }

    private var items: [PaletteItem] {
        var all: [PaletteItem] = [
            PaletteItem(title: "Overview", subtitle: "Waiting for you", icon: .apps, page: .overview),
            PaletteItem(title: "Reports", subtitle: "How agent work went", icon: .graph, page: .reports),
        ]
        for page in model.workspace.strip.pages {
            all.append(
                PaletteItem(
                    title: pageTitle(page, workspace: model.workspace, projects: projects),
                    subtitle: "Open",
                    icon: pageSymbol(page, workspace: model.workspace),
                    page: page
                )
            )
        }
        for project in projects.projects {
            all.append(
                PaletteItem(
                    title: project.name,
                    subtitle: project.repo,
                    icon: project.openPRs > 0 ? .pullRequest : .repo,
                    page: .repository(project.repo)
                )
            )
        }
        all.append(PaletteItem(title: "Settings", subtitle: "", icon: .gear, page: .settings))

        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.subtitle.localizedCaseInsensitiveContains(needle)
        }
    }

    private func move(by offset: Int) {
        guard !items.isEmpty else { return }
        highlighted = max(0, min(items.count - 1, highlighted + offset))
    }

    private func activate() {
        guard items.indices.contains(highlighted) else { return }
        model.workspace.show(items[highlighted].page)
        isShown = false
    }
}

private struct PaletteItem: Identifiable {
    let title: String
    let subtitle: String
    let icon: Octicon
    let page: WorkspacePage
    var id: String { "\(page)" }
}
