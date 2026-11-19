import LLMCore
import SwiftUI

/// The app's mark: three lines of text and the accent caret, as in the app icon
/// (`scripts/make-app-icon.swift` draws the same geometry).
struct AppMark: View {
    var body: some View {
        Canvas { context, size in
            // Same unit geometry as scripts/make-app-icon.swift, scaled to fit and centred.
            let lineHeight: CGFloat = 0.095
            let lines: [(y: CGFloat, width: CGFloat)] = [(0.22, 0.80), (0.43, 0.64), (0.64, 0.38)]
            let caretUnit = CGRect(x: 0.44, y: 0.5575, width: 0.12, height: 0.26)
            let bounds = CGRect(x: 0, y: 0.22, width: 0.80, height: caretUnit.maxY - 0.22)
            let unit = min(size.width / bounds.width, size.height / bounds.height)
            let origin = CGPoint(
                x: size.width / 2 - bounds.midX * unit, y: size.height / 2 - bounds.midY * unit)
            func rect(_ r: CGRect) -> CGRect {
                CGRect(
                    x: origin.x + r.minX * unit, y: origin.y + r.minY * unit,
                    width: r.width * unit, height: r.height * unit)
            }
            for line in lines {
                let r = rect(CGRect(x: 0, y: line.y, width: line.width, height: lineHeight))
                context.fill(
                    Path(roundedRect: r, cornerRadius: r.height / 2),
                    with: .color(Theme.textSecondary))
            }
            context.fill(
                Path(roundedRect: rect(caretUnit), cornerRadius: unit * 0.022),
                with: .color(Theme.accent))
        }
        .accessibilityHidden(true)
    }
}

/// Full-width button for the one main action on a card: inverted neutral (light on dark,
/// dark on light), so the accent stays reserved for small live elements.
struct PrimaryButton: View {
    let title: Text
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.bold))
                }
                title.font(.body.weight(.semibold))
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Secondary button on a card: neutral fill.
struct SecondaryButton: View {
    let title: Text
    var systemImage: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.footnote.weight(.semibold))
                }
                title.font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(role == .destructive ? Theme.critical : Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// "1.7B · 4-bit · 982 MB"
struct ModelMetaLine: View {
    let spec: ModelSpec

    var body: some View {
        Text(verbatim: "\(spec.parameterCountLabel) · \(spec.quantization.label) · \(Format.bytes(spec.downloadBytes))")
            .font(.mono(.caption))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel(
                Text("\(spec.parameterCountLabel) parameters, \(spec.quantization.label), \(Format.bytes(spec.downloadBytes))"))
    }
}

/// Memory fit as a compact badge (optionally with the reason when it does not fit).
struct FitBadge: View {
    let fit: MemoryFit
    var showsReason = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .background(Theme.surfaceRaised.opacity(0.7), in: Capsule())
            if showsReason, case .tooLarge(let reason) = fit {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showsReason, fit == .tight {
                Text("Fits, with little room to spare. iOS may close the app if other apps need memory.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch fit {
        case .ok: "Fits"
        case .tight: "Tight fit"
        case .tooLarge: "Too large"
        }
    }

    private var icon: String {
        switch fit {
        case .ok: "checkmark.circle.fill"
        case .tight: "exclamationmark.circle.fill"
        case .tooLarge: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch fit {
        case .ok: Theme.positive
        case .tight: Theme.caution
        case .tooLarge: Theme.critical
        }
    }
}

/// Bytes, percentage, a thin accent bar and Cancel.
struct DownloadProgressView: View {
    let progress: Double
    let received: Int64
    let total: Int64
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Format.bytes(received)) of \(Format.bytes(total))")
                    .font(.mono(.footnote))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Text(verbatim: Format.percent(progress))
                    .font(.mono(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.surfaceRaised, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel download"))
            }
            ProgressBar(fraction: progress)
            Label {
                Text("Downloads pause if you leave the app.")
            } icon: {
                Image(systemName: "pause.circle")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.3), value: fraction)
        .accessibilityElement()
        .accessibilityLabel(Text("Download progress"))
        .accessibilityValue(Text(verbatim: Format.percent(fraction)))
    }
}

/// License id as a small outlined badge that opens the license text.
struct LicenseBadge: View {
    let license: ModelLicense
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(license.url)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: displayID)
                Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
            }
            .font(.mono(.caption, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("License: \(displayID)"))
        .accessibilityHint(Text("Opens the license in Safari"))
    }

    private var displayID: String {
        switch license.id.lowercased() {
        case "apache-2.0": "Apache-2.0"
        case "mit": "MIT"
        default: license.id
        }
    }
}

// MARK: - Download confirmation (App Review 4.2.3: say what is downloaded, how big, from where)

extension View {
    /// Asks before downloading `spec` (size and source), or explains that there is not enough
    /// free storage. Set the binding to start.
    func downloadConfirmation(for spec: Binding<ModelSpec?>, environment: AppEnvironment) -> some View {
        modifier(DownloadConfirmation(spec: spec, environment: environment))
    }
}

private struct DownloadConfirmation: ViewModifier {
    @Binding var spec: ModelSpec?
    let environment: AppEnvironment

    func body(content: Content) -> some View {
        let shortfall = spec.flatMap { environment.storageShortfall(for: $0) }
        content
            .alert(
                Text("Download \(spec?.displayName ?? "")?"),
                isPresented: Binding(
                    get: { spec != nil && shortfall == nil },
                    set: { if !$0 { spec = nil } }),
                presenting: spec
            ) { spec in
                Button("Download") {
                    environment.download(spec)
                }
                Button("Cancel", role: .cancel) {}
            } message: { spec in
                Text(
                    "This downloads \(Format.bytes(spec.downloadBytes)) from huggingface.co. Keep the app open until it finishes: downloads pause in the background. Wi-Fi recommended."
                )
            }
            .alert(
                Text("Not enough storage"),
                isPresented: Binding(
                    get: { spec != nil && shortfall != nil },
                    set: { if !$0 { spec = nil } }),
                presenting: spec
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { spec in
                let needed = Format.bytes(shortfall?.required ?? spec.downloadBytes)
                let free = Format.bytes(shortfall?.available ?? 0)
                Text(
                    "\(spec.displayName) needs about \(needed) of free storage, but only \(free) is available. Free up space in Settings › General › iPhone Storage and try again."
                )
            }
    }
}
