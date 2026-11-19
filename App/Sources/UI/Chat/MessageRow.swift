import LLMCore
import SwiftUI
import UIKit

/// Actions a message row can trigger (kept out of the row's equality).
struct MessageActions: Sendable {
    var regenerate: @MainActor () -> Void = {}
    var selectText: @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var messageActions = MessageActions()
}

/// One message. `Equatable`, so finished rows skip `body` while another message streams.
struct MessageRow: View, Equatable {
    let message: ChatMessage
    /// Regenerate is offered on the last assistant message only, and not while generating.
    let canRegenerate: Bool

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.canRegenerate == rhs.canRegenerate
    }

    var body: some View {
        switch message.role {
        case .user: UserBubble(message: message)
        case .assistant: AssistantMessage(message: message, canRegenerate: canRegenerate)
        }
    }
}

// MARK: - User

private struct UserBubble: View {
    let message: ChatMessage
    @Environment(\.messageActions) private var actions

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(message.text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Theme.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                )
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .contextMenu {
                    MessageMenu(text: message.text, canRegenerate: false, actions: actions)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You: \(message.text)"))
    }
}

// MARK: - Assistant

private struct AssistantMessage: View {
    let message: ChatMessage
    let canRegenerate: Bool
    @Environment(\.messageActions) private var actions

    private var isStreaming: Bool { message.state == .streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.thinking.isEmpty {
                ThinkingDisclosure(
                    thinking: message.thinking,
                    duration: message.thinkingDuration,
                    isThinking: isStreaming && message.thinkingDuration == nil,
                    wasCutOff: message.isThinkingUnterminated && !isStreaming,
                    // A finished reply with no answer (length limit or Stop while thinking, or
                    // an empty answer after the block): the thinking is all there is to read.
                    expandsByDefault: !isStreaming && message.text.isEmpty)
            }
            if !message.text.isEmpty || (isStreaming && message.thinking.isEmpty) {
                MarkdownView(
                    blocks: BlockCache.blocks(for: message),
                    showsCaret: isStreaming)
            }
            if !isStreaming {
                MessageFooter(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.contextMenuPreview, Rectangle())
        .contextMenu {
            if !isStreaming {
                MessageMenu(text: message.text, canRegenerate: canRegenerate, actions: actions)
            }
        }
    }
}

/// Parsed blocks of finished messages are kept; only the streaming text is parsed again.
@MainActor
private enum BlockCache {
    private final class Box {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        return cache
    }()

    static func blocks(for message: ChatMessage) -> [MarkdownBlock] {
        guard message.state != .streaming else { return MarkdownParser.parse(message.text) }
        let key = "\(message.id.uuidString)#\(message.text.utf8.count)#\(message.text.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownParser.parse(message.text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}

private struct MessageMenu: View {
    let text: String
    let canRegenerate: Bool
    let actions: MessageActions

    var body: some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            actions.selectText(text)
        } label: {
            Label("Select Text", systemImage: "selection.pin.in.out")
        }
        ShareLink(item: text) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        if canRegenerate {
            Divider()
            Button {
                actions.regenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
    }
}

// MARK: - Thinking

private struct ThinkingDisclosure: View {
    let thinking: String
    let duration: TimeInterval?
    let isThinking: Bool
    let wasCutOff: Bool
    /// Expanded until the user collapses it. Derived rather than an initial `@State` value,
    /// because the row keeps its identity (and state) when a streaming reply finishes.
    let expandsByDefault: Bool

    /// The user's choice; `nil` until they tap, then it wins over ``expandsByDefault``.
    @State private var userExpanded: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { userExpanded ?? expandsByDefault }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                let expand = !isExpanded
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { userExpanded = expand }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label
                        .font(.footnote.weight(.medium).monospacedDigit())
                    if isThinking {
                        PulsingDot(color: Theme.textTertiary, size: 5)
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            .accessibilityLabel(label)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text("Shows the model's reasoning"))

            if isExpanded {
                Text(thinking)
                    .font(.footnote)
                    .lineSpacing(2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.hairline).frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
    }

    private var label: Text {
        if isThinking {
            return Text("Thinking…")
        }
        guard let duration else { return Text("Reasoning") }
        let seconds = Format.shortSeconds(duration)
        return wasCutOff ? Text("Thought for \(seconds) s · cut off") : Text("Thought for \(seconds) s")
    }
}

// MARK: - Footer

private struct MessageFooter: View {
    let message: ChatMessage

    private enum Item: Hashable {
        case rate(Double)
        case firstToken(TimeInterval)
        case tokens(Int)
        case lengthLimit
        /// The limit was reached inside the thinking block, before any answer.
        case lengthLimitWhileThinking
        /// The model never closed its thinking block; that text is shown as the answer.
        case thinkingPromoted
        case stopped
        case failed
    }

    private var items: [Item] {
        var items: [Item] = []
        if let stats = message.stats {
            if stats.generatedTokens > 1 { items.append(.rate(stats.tokensPerSecond)) }
            if let ttft = stats.timeToFirstToken { items.append(.firstToken(ttft)) }
            items.append(.tokens(stats.generatedTokens))
            if stats.stopReason == .maxTokens, message.state == .done {
                let ranOutWhileThinking =
                    message.text.isEmpty && message.isThinkingUnterminated
                    && !message.thinking.isEmpty
                items.append(ranOutWhileThinking ? .lengthLimitWhileThinking : .lengthLimit)
            }
        }
        if message.isThinkingPromoted { items.append(.thinkingPromoted) }
        switch message.state {
        case .stopped: items.append(.stopped)
        case .failed: items.append(.failed)
        case .streaming, .done: break
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    if index > 0 {
                        Text(verbatim: "·").accessibilityHidden(true)
                    }
                    view(for: item)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)

            if case .failed(let reason) = message.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func view(for item: Item) -> some View {
        switch item {
        case .rate(let rate):
            Text("\(Format.rate(rate)) tok/s")
        case .firstToken(let seconds):
            Text("first token \(Format.seconds(seconds)) s")
        case .tokens(let count):
            Text("\(count) tokens")
        case .lengthLimit:
            marker("Length limit", systemImage: "arrow.right.to.line", color: Theme.textSecondary)
        case .lengthLimitWhileThinking:
            marker(
                "Length limit while thinking", systemImage: "arrow.right.to.line",
                color: Theme.textSecondary)
        case .thinkingPromoted:
            marker("Reasoning shown as answer", systemImage: "brain", color: Theme.textSecondary)
        case .stopped:
            marker("Stopped", systemImage: "stop.circle", color: Theme.textSecondary)
        case .failed:
            marker("Failed", systemImage: "exclamationmark.triangle.fill", color: Theme.critical)
        }
    }

    private func marker(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
    }
}

// MARK: - Small shared pieces

/// A live indicator. It pulses in size, never in opacity: a half-transparent accent over the
/// dark greys would read as brown.
struct PulsingDot: View {
    var color: Color = Theme.accent
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var small = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(small ? 0.55 : 1)
            .frame(width: size, height: size)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    small = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Lays children out left to right, wrapping to new lines (footers and badges at large
/// Dynamic Type sizes). Items are centred vertically within their line.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> ([Line], [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        var lines: [Line] = []
        var current = Line()
        for (index, size) in sizes.enumerated() {
            let needed = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty, needed > width {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return (lines, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (lines, _) = lines(for: subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(lines.count - 1, 0))
        let maxWidth = lines.map(\.width).max() ?? 0
        return CGSize(width: min(maxWidth, width), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let (lines, sizes) = lines(for: subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }
}
