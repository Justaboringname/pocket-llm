import Foundation
import LLMCore
import SwiftUI

/// Number formatting for the readout and stats (locale-aware separators, fixed precision so
/// digits do not jump while they update).
enum Format {
    /// "42.1"
    static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    }

    /// "0.38"
    static func seconds(_ value: TimeInterval) -> String {
        let digits = value < 10 ? 2 : 1
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }

    /// "1.4"
    static func shortSeconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    }

    static func bytes(_ value: Int64) -> String {
        ByteFormatting.string(value)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteFormatting.string(value)
    }

    /// RAM sizes use binary units, as iOS does ("8 GB" for 8 GiB).
    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Opens only web links in the system browser; anything else in model output (custom URL
/// schemes, `tel:`, …) is ignored.
struct SafeLinkHandling: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(
            \.openURL,
            OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
                else { return .discarded }
                return .systemAction
            })
    }
}

extension View {
    func safeLinkHandling() -> some View { modifier(SafeLinkHandling()) }
}

/// Build-setting driven links (Info.plist keys filled from `Config/Base.xcconfig`).
enum AppLinks {
    static var privacyPolicy: URL? { url(forInfoKey: "PrivacyPolicyURL") }
    static var support: URL? { url(forInfoKey: "SupportURL") }

    private static func url(forInfoKey key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    static func huggingFacePage(for spec: ModelSpec) -> URL? {
        URL(string: "https://huggingface.co/\(spec.repoID)")
    }
}
