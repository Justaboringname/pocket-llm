import LLMCore
import SwiftUI

/// Every catalog model as a card: specs, license, memory fit and install state.
struct ModelsScreen: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDownload: ModelSpec?
    @State private var pendingDelete: ModelSpec?

    private var store: any ModelStore { environment.store }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Models run on this iPhone's GPU. Larger ones answer better but need more memory and are slower.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)

                    ForEach(store.catalog) { spec in
                        ModelCard(
                            spec: spec,
                            environment: environment,
                            onDownload: { pendingDownload = spec },
                            onDelete: { pendingDelete = spec },
                            onUse: {
                                environment.use(spec)
                                dismiss()
                            })
                    }

                    StorageFooter(environment: environment)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.vertical, Theme.Space.s)
            }
            .background(Theme.groupedBackground)
            .navigationTitle(Text("Models"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .downloadConfirmation(for: $pendingDownload, environment: environment)
            .alert(
                Text("Delete \(pendingDelete?.displayName ?? "")?"),
                isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { spec in
                Button("Delete", role: .destructive) { environment.delete(spec) }
                Button("Cancel", role: .cancel) {}
            } message: { spec in
                Text(
                    "This frees \(Format.bytes(bytesOnDisk(spec))). You can download it again later.")
            }
        }
    }

    private func bytesOnDisk(_ spec: ModelSpec) -> Int64 {
        if case .downloaded(let bytes) = store.state(for: spec) { return bytes }
        return spec.downloadBytes
    }
}

private struct ModelCard: View {
    let spec: ModelSpec
    let environment: AppEnvironment
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onUse: () -> Void

    private var chat: ChatViewModel { environment.chat }

    private var isActive: Bool {
        if case .ready(let current) = chat.modelState { return current.id == spec.id }
        return false
    }

    private var isLoading: Bool {
        if case .loading(let current, _) = chat.modelState { return current.id == spec.id }
        return false
    }

    private var isSelected: Bool { chat.currentModel?.id == spec.id }

    var body: some View {
        let state = environment.store.state(for: spec)
        let fit = environment.displayedFit(for: spec)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: spec.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    ModelMetaLine(spec: spec)
                }
                Spacer(minLength: 8)
                headerAction(state: state, fit: fit)
            }

            Text(spec.localizedBlurb)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 8) {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 0) {
                    LicenseBadge(license: spec.license)
                    FitBadge(fit: fit, showsReason: false)
                    if spec.supportsThinkingToggle {
                        HStack(spacing: 4) {
                            Image(systemName: "brain").font(.caption2.weight(.bold))
                            Text("Thinking")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 26)
                        .background(Theme.surfaceRaised.opacity(0.7), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                if state.isDownloaded {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .accessibilityLabel(Text("Delete \(spec.displayName)"))
                }
            }
            .padding(.vertical, -8)

            switch state {
            case .downloading(let progress, let received, let total):
                DownloadProgressView(
                    progress: progress, received: received, total: total,
                    onCancel: { environment.cancelDownload(spec) }
                )
                .padding(.top, 4)
            case .failed(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            default:
                if case .tooLarge(let reason) = fit {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if fit == .tight, !isActive {
                    Text("Fits, with little room to spare. iOS may close the app if other apps need memory.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.groupedRow, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isActive ? Theme.accent : Theme.hairline, lineWidth: isActive ? 1.5 : 1)
        }
        .accessibilityElement(children: .contain)
    }

    /// The one action next to the name: Download, Use, Active, Loading, Retry.
    @ViewBuilder
    private func headerAction(state: ModelInstallState, fit: MemoryFit) -> some View {
        switch state {
        case .notDownloaded:
            if fit.allowsLoading {
                CompactButton(title: Text("Download"), systemImage: "arrow.down", action: onDownload)
                    .accessibilityLabel(
                        Text("Download \(spec.displayName), \(Format.bytes(spec.downloadBytes))"))
            }
        case .downloading:
            EmptyView()
        case .downloaded:
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .labelStyle(AccentIconLabelStyle())
                    .frame(minHeight: 44)
            } else if isLoading {
                ProgressView().controlSize(.small).frame(minWidth: 44, minHeight: 44)
            } else if fit.allowsLoading {
                CompactButton(title: isSelected ? Text("Load") : Text("Use"), systemImage: nil, action: onUse)
                    .disabled(chat.isGenerating)
            }
        case .failed:
            CompactButton(title: Text("Retry"), systemImage: "arrow.clockwise", action: onDownload)
        }
    }
}

/// Small neutral capsule button (44 pt hit target).
private struct CompactButton: View {
    let title: Text
    let systemImage: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.footnote.weight(.bold))
                }
                title.font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(Theme.surfaceRaised, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Theme.accent)
            configuration.title
        }
    }
}

private struct StorageFooter: View {
    let environment: AppEnvironment

    var body: some View {
        let used = Format.bytes(environment.store.totalBytesOnDisk)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                if let free = environment.store.availableDiskBytes() {
                    Text("Models use \(used) · \(Format.bytes(free)) free on this iPhone")
                } else {
                    Text("Models use \(used)")
                }
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            Text("Model files are downloaded from huggingface.co only when you tap Download.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
