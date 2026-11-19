import SwiftUI
import UIKit

/// Inline Markdown (bold, italic, code spans, links) → `AttributedString`, cached by source.
///
/// While a reply streams only its last block changes, so every earlier block is a cache hit
/// and only the tail is parsed again.
@MainActor
enum InlineMarkdown {
    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 1500
        return cache
    }()

    static func render(_ source: String) -> AttributedString {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = parse(source)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    private static func parse(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].backgroundColor = Theme.surfaceRaised
                attributed[run.range].font = .system(.subheadline, design: .monospaced)
            }
            if run.link != nil {
                attributed[run.range].underlineStyle = .single
                attributed[run.range].foregroundColor = Theme.textPrimary
            }
        }
        return attributed
    }
}

/// Renders model output as blocks. Long-pressing the whole message is handled by the caller.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// Shows the streaming caret after the last block.
    var showsCaret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(
                    block: block,
                    showsCaret: showsCaret && index == blocks.count - 1
                )
                .padding(.top, index == 0 ? 0 : spacing(before: block, after: blocks[index - 1]))
            }
            if showsCaret, blocks.isEmpty {
                StreamingCaret()
            }
        }
    }

    private func spacing(before block: MarkdownBlock, after previous: MarkdownBlock) -> CGFloat {
        switch (previous.kind, block.kind) {
        case (.listItem, .listItem): return 6
        case (_, .heading): return 20
        case (.heading, _): return 8
        default: return 12
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let showsCaret: Bool

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            inline(text)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.textPrimary)
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let marker {
                    Text(verbatim: marker)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 20, alignment: .trailing)
                } else {
                    Text(verbatim: depth == 0 ? "•" : "◦")
                        .font(.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minWidth: 12, alignment: .center)
                }
                inline(text)
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, CGFloat(depth) * 20)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(Theme.textTertiary.opacity(0.6))
                    .frame(width: 3)
                inline(text)
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code, showsCaret: showsCaret)
        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 8) {
                TableBlockView(header: header, rows: rows)
                if showsCaret { StreamingCaret() }
            }
        case .rule:
            VStack(alignment: .leading, spacing: 8) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                if showsCaret { StreamingCaret() }
            }
        }
    }

    private func inline(_ source: String) -> Text {
        var attributed = InlineMarkdown.render(source)
        if showsCaret {
            attributed.append(StreamingCaret.attributed)
        }
        return Text(attributed)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

/// The caret shown at the end of a streaming reply.
struct StreamingCaret: View {
    static var attributed: AttributedString {
        var caret = AttributedString("\u{2009}\u{258D}")  // thin space + left five-eighths block
        caret.foregroundColor = Theme.accent
        return caret
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Blinks on/off like a terminal cursor (no fade: a faded accent reads as brown).
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let visible =
                reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(visible ? Theme.accent : Color.clear)
                .frame(width: 9, height: 18)
        }
        .accessibilityHidden(true)
    }
}

/// A fenced code block: monospaced card with the language and a copy button.
struct CodeBlockView: View {
    let language: String
    let code: String
    var showsCaret = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: language.isEmpty ? "code" : language.lowercased())
                    .font(.mono(.caption))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .contentTransition(.symbolEffect(.replace))
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(copied ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
            }
            .padding(.leading, 14)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                codeText
                    .font(.mono(.footnote))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Fades the right edge so lines that continue off-screen read as scrollable.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 20)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.code, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.code, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }

    private var codeText: Text {
        var attributed = AttributedString(code)
        if showsCaret { attributed.append(StreamingCaret.attributed) }
        return Text(attributed)
    }
}

/// A simple pipe table, scrollable sideways when wide.
private struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(InlineMarkdown.render(cell))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            Text(InlineMarkdown.render(column < row.count ? row[column] : ""))
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.code, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.code, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}
