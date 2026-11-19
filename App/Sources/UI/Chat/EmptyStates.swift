import LLMCore
import SwiftUI

/// What the chat shows when there are no messages: first-run onboarding, a model picker, or
/// suggested prompts.
struct ChatEmptyState: View {
    let environment: AppEnvironment
    let onPrompt: (String) -> Void

    var body: some View {
        let chat = environment.chat
        Group {
            if environment.downloadedModels.isEmpty, chat.currentModel == nil {
                OnboardingPanel(environment: environment)
            } else if let spec = chat.currentModel {
                SuggestionsPanel(
                    spec: spec,
                    isEnabled: (chat.modelState.isReady || chat.modelState == .unloaded(spec))
                        && !environment.safety.isGenerationBlocked,
                    onPrompt: onPrompt)
            } else {
                ChooseModelPanel(environment: environment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - First run

private struct OnboardingPanel: View {
    let environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                AppMark()
                    .frame(width: 52, height: 52)
                    .padding(.top, Theme.Space.l)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Chat with a language model that runs entirely on this iPhone.")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Nothing you type is sent to a server.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let spec = ModelRecommendation.recommended(environment: environment) {
                    RecommendedModelCard(spec: spec, environment: environment)
                } else {
                    Text("None of the models fits in this iPhone's memory right now. Close other apps and try again.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }

                Button {
                    environment.sheet = .models
                } label: {
                    HStack(spacing: 6) {
                        Text("All models")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct RecommendedModelCard: View {
    let spec: ModelSpec
    let environment: AppEnvironment
    @State private var pendingDownload: ModelSpec?

    var body: some View {
        let state = environment.store.state(for: spec)
        VStack(alignment: .leading, spacing: 14) {
            Text("Recommended for this iPhone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: spec.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    FitBadge(fit: environment.displayedFit(for: spec), showsReason: false)
                }
                ModelMetaLine(spec: spec)
            }

            Text(spec.localizedBlurb)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch state {
            case .notDownloaded:
                PrimaryButton(
                    title: Text("Download · \(Format.bytes(spec.downloadBytes))"),
                    systemImage: "arrow.down"
                ) {
                    pendingDownload = spec
                }
                .accessibilityIdentifier("onboarding.download")
                Text("From huggingface.co. Keep the app open while it downloads.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            case .downloading(let progress, let received, let total):
                DownloadProgressView(
                    progress: progress, received: received, total: total,
                    onCancel: { environment.cancelDownload(spec) })
            case .downloaded:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading \(spec.displayName)…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(minHeight: 44)
            case .failed(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                PrimaryButton(title: Text("Try again"), systemImage: "arrow.clockwise") {
                    pendingDownload = spec
                }
            }
        }
        .padding(Theme.Space.l + 2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
        .downloadConfirmation(for: $pendingDownload, environment: environment)
    }
}

/// The model to recommend on first run. The rule lives in LLMCore
/// (`ModelCatalog.recommendedFirstModel`, unit-tested): Qwen3 1.7B when its memory fit is `.ok`,
/// otherwise Qwen3 0.6B when that is `.ok`, otherwise none.
enum ModelRecommendation {
    @MainActor
    static func recommended(environment: AppEnvironment) -> ModelSpec? {
        ModelCatalog.recommendedFirstModel(in: environment.store.catalog) {
            environment.chat.memoryFit(for: $0)
        }
    }
}

// MARK: - Models downloaded, none selected

private struct ChooseModelPanel: View {
    let environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Spacer(minLength: Theme.Space.xxl)
                Text("Pick a model to start")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                VStack(spacing: 8) {
                    ForEach(environment.downloadedModels) { spec in
                        Button {
                            environment.use(spec)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: spec.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    ModelMetaLine(spec: spec)
                                }
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.m)
                            .frame(minHeight: 56)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!environment.chat.memoryFit(for: spec).allowsLoading)
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
        }
    }
}

// MARK: - Ready, no messages

private struct SuggestionsPanel: View {
    let spec: ModelSpec
    /// Off while the model loads (or failed to load): the composer explains why.
    let isEnabled: Bool
    let onPrompt: (String) -> Void

    private var prompts: [String] {
        [
            String(localized: "Explain how a language model picks its next word, in plain terms."),
            String(localized: "Write a Swift function that checks whether a string is a palindrome."),
            String(localized: "Give me three ideas for a quick weeknight dinner."),
            String(localized: "Write a four-line poem about a train at night."),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: spec.displayName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    ModelMetaLine(spec: spec)
                        .padding(.bottom, 4)
                    Text("Running on this iPhone. Nothing is sent to a server.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 8) {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                        Button {
                            onPrompt(prompt)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(prompt)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.top, 3)
                            }
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, 14)
                            .frame(minHeight: 52)
                            .background(
                                Theme.surface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)
                        .opacity(isEnabled ? 1 : 0.5)
                        .accessibilityHint(Text("Sends this message"))
                        .accessibilityIdentifier("suggestion.\(index)")
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
    }
}
