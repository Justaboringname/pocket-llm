import LLMCore
import SwiftUI

/// The conversation. Follows the stream while the user is at the bottom; once they scroll up
/// it stays put and offers a "jump to latest" button instead.
struct TranscriptView: View {
    let feed: TranscriptFeed
    let isGenerating: Bool
    /// Bumped by the parent when the user sends, to re-pin to the bottom.
    let sendCount: Int

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isPinned = true
    @State private var isUserScrolling = false
    @State private var distanceFromBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pinThreshold: CGFloat = 48

    var body: some View {
        let messages = feed.messages
        let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(messages) { message in
                    MessageRow(
                        message: message,
                        canRegenerate: message.id == lastAssistantID && !isGenerating
                            && message.id == messages.last?.id
                    )
                    .equatable()
                    .id(message.id)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom
                - geometry.contentOffset.y - geometry.containerSize.height
        } action: { _, distance in
            distanceFromBottom = distance
            if isUserScrolling {
                isPinned = distance < pinThreshold
            } else if isPinned, distance > 1 {
                // Content grew (streaming) or the keyboard moved: stay at the bottom.
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .interacting || phase == .decelerating
            if phase == .idle {
                isPinned = distanceFromBottom < pinThreshold
            }
        }
        .onChange(of: sendCount) {
            isPinned = true
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                position.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if !isPinned, distanceFromBottom > 160 {
                Button {
                    isPinned = true
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                        position.scrollTo(edge: .bottom)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .padding(.bottom, Theme.Space.s)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel(Text("Jump to latest"))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isPinned)
    }
}
