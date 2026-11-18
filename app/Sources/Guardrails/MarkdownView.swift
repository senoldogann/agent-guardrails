import GuardrailsCore
import SwiftUI

/// Markdown an agent or a person wrote on GitHub, shown as blocks with inline formatting. Invisible format
/// characters are removed first, so the text cannot render differently from what it says.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdownBlocks(displaySafe(text)).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inlineMarkdown(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            ListItem(marker: "•", text: text)
        case .numbered(let marker, let text):
            ListItem(marker: marker, text: text)
        case .quote(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 3) }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.mono).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceMuted))
        }
    }
}

struct ListItem: View {
    let marker: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).foregroundStyle(Palette.textSecondary)
            Text(inlineMarkdown(text)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(.leading, 4)
    }
}

/// Bold, italics, code spans and links; text that is not valid Markdown is shown as written.
private func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
