import Foundation

/// The `User-Agent` sent with model downloads: `<app name>/<version>`, built from the bundle at
/// runtime so renaming the app or bumping its version needs no code change.
public enum UserAgent {
    /// - Name: `CFBundleDisplayName`, else `CFBundleName`, reduced to HTTP token characters
    ///   (RFC 9110: letters, digits and ``!#$%&'*+-.^_`|~``), so "Pocket LLM" becomes
    ///   "PocketLLM". A name with no token characters left (e.g. only CJK) falls back to the next
    ///   key, then to "App".
    /// - Version: `CFBundleShortVersionString`, else "0", reduced the same way.
    public static func make(infoDictionary: [String: Any]?) -> String {
        let info = infoDictionary ?? [:]
        let name =
            ["CFBundleDisplayName", "CFBundleName"]
            .lazy
            .compactMap { info[$0] as? String }
            .map(tokenCharacters)
            .first { !$0.isEmpty } ?? "App"
        let version = (info["CFBundleShortVersionString"] as? String).map(tokenCharacters) ?? ""
        return "\(name)/\(version.isEmpty ? "0" : version)"
    }

    /// For the running app.
    public static var current: String {
        make(infoDictionary: Bundle.main.infoDictionary)
    }

    private static let allowedPunctuation = Set("!#$%&'*+-.^_`|~")

    private static func tokenCharacters(_ text: String) -> String {
        String(
            text.filter { character in
                character.isASCII
                    && (character.isLetter || character.isNumber
                        || allowedPunctuation.contains(character))
            })
    }
}
