import LLMCore
import SwiftUI

/// Message field, send/stop button and the thinking toggle. Explains itself when it cannot
/// send (no model, loading, too hot).
struct Composer: View {
    let environment: AppEnvironment
    @Binding var draft: String
    var focus: FocusState<Bool>.Binding
    /// Without messages the empty state already explains missing models; no status line then.
    let hasMessages: Bool
    let onSend: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chat: ChatViewModel { environment.chat }

    private var status: ComposerStatus? {
        if environment.safety.isGenerationBlocked { return .tooHot }
        switch chat.modelState {
        case .noModel:
            return environment.downloadedModels.isEmpty ? .needsDownload : .needsModel
        case .loading(let spec, let progress):
            return .loading(name: spec.displayName, progress: progress)
        case .failed(let spec, _):
            return .loadFailed(spec)
        case .ready, .unloaded:
            return nil
        }
    }

    private var canType: Bool {
        switch status {
        case .needsDownload, .needsModel: false
        default: true
        }
    }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        guard hasText, !chat.isGenerating else { return false }
        return status == nil  // Loading, no model, load failed and too hot all block sending.
    }

    private var showsThinkingToggle: Bool {
        chat.currentModel?.supportsThinkingToggle == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status, showsStatusLine(status) {
                StatusLine(status: status, environment: environment)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
            if showsThinkingToggle {
                field
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                HStack(alignment: .center) {
                    ThinkingToggle(isOn: Binding(
                        get: { chat.settings.thinkingEnabled },
                        set: { chat.settings.thinkingEnabled = $0 }))
                    Spacer()
                    sendButton
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    field
                        .padding(.leading, 10)
                        .padding(.bottom, 6)
                    sendButton
                }
                .padding(.trailing, 6)
                .padding(.vertical, 6)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous))
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: status)
    }

    private var field: some View {
        // Custom prompt color: the system placeholder grey is blue-tinted.
        TextField(text: $draft, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary), axis: .vertical) {
            Text("Message")
        }
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...6)
            .focused(focus)
            .disabled(!canType)
            .submitLabel(.return)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .accessibilityLabel(Text("Message"))
            .accessibilityIdentifier("composer.field")
    }

    private func showsStatusLine(_ status: ComposerStatus) -> Bool {
        switch status {
        case .needsDownload, .needsModel: hasMessages
        case .tooHot: false  // The readout strip above says it.
        case .loading, .loadFailed: true
        }
    }

    private var placeholder: LocalizedStringKey {
        switch status {
        case .needsDownload: "Download a model to start"
        case .needsModel: "Choose a model to start"
        default: "Message"
        }
    }

    private var sendButton: some View {
        let generating = chat.isGenerating
        let enabled = generating || canSend
        return Button {
            if generating {
                Task { await chat.stop() }
            } else {
                onSend()
            }
        } label: {
            Image(systemName: generating ? "stop.fill" : "arrow.up")
                .font(.system(size: generating ? 14 : 17, weight: .bold))
                .foregroundStyle(enabled ? Theme.onAccent : Theme.textTertiary)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 36, height: 36)
                .background(enabled ? Theme.accent : Theme.surfaceRaised, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(generating ? Text("Stop generating") : Text("Send"))
        .accessibilityIdentifier("composer.send")
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: generating)
    }
}

private struct ThinkingToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                Text("Thinking")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                Capsule().fill(isOn ? Theme.surfaceRaised : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Thinking"))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityHint(Text("When on, the model reasons before it answers. Slower, often better."))
        .accessibilityAddTraits(.isToggle)
    }
}

private enum ComposerStatus: Equatable {
    case needsDownload
    case needsModel
    case loading(name: String, progress: Double?)
    case loadFailed(ModelSpec)
    case tooHot
}

/// One line above the field saying why sending is not possible (or what is happening).
private struct StatusLine: View {
    let status: ComposerStatus
    let environment: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .needsDownload:
                icon("arrow.down.circle")
                Text("No model on this iPhone yet.")
                Spacer(minLength: 4)
                Button("Models") { environment.sheet = .models }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, -8)
            case .needsModel:
                icon("cpu")
                Text("No model selected.")
                Spacer(minLength: 4)
                Button("Choose") { environment.sheet = .models }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, -8)
            case .loading(let name, let progress):
                if let progress, progress > 0, progress < 1 {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text("Loading \(name)…")
                Spacer(minLength: 0)
            case .loadFailed(let spec):
                icon("exclamationmark.triangle", color: Theme.critical)
                Text("\(spec.displayName) could not be loaded.")
                Spacer(minLength: 4)
                Button("Retry") { environment.use(spec) }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, -8)
            case .tooHot:
                icon("thermometer.high", color: Theme.critical)
                Text("Paused: device too hot")
                Spacer(minLength: 0)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(2)
        .frame(minHeight: 28)
    }

    private func icon(_ name: String, color: Color = Theme.textSecondary) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
