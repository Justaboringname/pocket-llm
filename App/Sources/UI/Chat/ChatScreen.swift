import LLMCore
import SwiftUI

/// The root screen: model pill and actions on top, the conversation, and the bottom panel
/// (error banner, live readout, composer).
struct ChatScreen: View {
    let environment: AppEnvironment

    @State private var feed: TranscriptFeed
    @State private var draft = ""
    @State private var sendCount = 0
    @State private var finishCount = 0
    @State private var selectedText: SelectableText?
    @State private var confirmingNewChat = false
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(environment: AppEnvironment) {
        self.environment = environment
        _feed = State(initialValue: TranscriptFeed(chat: environment.chat))
    }

    private var chat: ChatViewModel { environment.chat }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModelPill(environment: environment)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        startNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(feed.hasMessages ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .disabled(!feed.hasMessages)
                    .accessibilityLabel(Text("New conversation"))
                    .accessibilityIdentifier("toolbar.newConversation")

                    Button {
                        environment.sheet = .settings
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityLabel(Text("Settings"))
                    .accessibilityIdentifier("toolbar.settings")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPanel
            }
            .environment(
                \.messageActions,
                MessageActions(
                    regenerate: {
                        sendCount += 1
                        Task { await chat.regenerate() }
                    },
                    selectText: { selectedText = SelectableText(text: $0) }))
            .sheet(item: $selectedText) { item in
                SelectTextSheet(text: item.text)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
            .sensoryFeedback(.success, trigger: finishCount)
            .onChange(of: chat.isGenerating) { wasGenerating, isGenerating in
                if wasGenerating, !isGenerating { finishCount += 1 }
            }
    }

    @ViewBuilder private var content: some View {
        if !feed.hasMessages {
            ChatEmptyState(environment: environment) { prompt in
                send(prompt)
            }
        } else {
            TranscriptView(feed: feed, isGenerating: chat.isGenerating, sendCount: sendCount)
        }
    }

    private var showsStrip: Bool {
        chat.isGenerating || environment.safety.isThermalWarning
    }

    private var bottomPanel: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 8) {
                if let error = chat.lastError {
                    ErrorBanner(message: error) { chat.clearError() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showsStrip {
                    InstrumentStrip(chat: chat, safety: environment.safety)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Composer(
                    environment: environment, draft: $draft, focus: $composerFocused,
                    hasMessages: feed.hasMessages
                ) {
                    send(draft)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: showsStrip)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: chat.lastError)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chat.isGenerating else { return }
        draft = ""
        sendCount += 1
        Task {
            let sent = await chat.send(trimmed)
            if !sent, draft.isEmpty { draft = trimmed }  // Give the text back if it was refused.
        }
    }

    private func startNewConversation() {
        draft = ""
        Task { await chat.newConversation() }
    }
}

/// The tappable pill in the top bar: current model and its state.
struct ModelPill: View {
    let environment: AppEnvironment

    var body: some View {
        let state = environment.chat.modelState
        Button {
            environment.sheet = .models
        } label: {
            HStack(spacing: 7) {
                StateDot(state: state)
                Text(title(for: state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 36)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle(for: state))
        .accessibilityHint(Text("Opens the model list"))
        .accessibilityIdentifier("toolbar.modelPill")
    }

    private func title(for state: ModelSessionState) -> String {
        state.spec?.displayName ?? String(localized: "Choose model")
    }

    private func accessibilityTitle(for state: ModelSessionState) -> Text {
        switch state {
        case .noModel: Text("No model selected")
        case .loading(let spec, _): Text("Model: \(spec.displayName), loading")
        case .ready(let spec): Text("Model: \(spec.displayName), ready")
        case .unloaded(let spec): Text("Model: \(spec.displayName), loads when you send")
        case .failed(let spec, _): Text("Model: \(spec.displayName), failed to load")
        }
    }
}

private struct StateDot: View {
    let state: ModelSessionState

    var body: some View {
        switch state {
        case .noModel:
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5).frame(width: 8, height: 8)
        case .loading:
            PulsingDot(color: Theme.accent, size: 8)
        case .ready:
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
        case .unloaded:
            Circle().strokeBorder(Theme.accent, lineWidth: 1.5).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(Theme.critical).frame(width: 8, height: 8)
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.critical)
                .padding(.top, 2)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -12)
            .padding(.trailing, -8)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

/// Full message text in a selectable text view, for copying part of a reply.
private struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .background(Theme.background)
                .navigationTitle(Text("Select Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationBackground(Theme.background)
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Theme.textPrimary)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
