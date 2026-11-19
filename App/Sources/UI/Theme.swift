import SwiftUI
import UIKit

/// Design tokens. Every color the UI uses comes from here.
///
/// Greys are strictly neutral (R = G = B) in both appearances: the dark background is `#181818`,
/// raised surfaces `#212121`–`#262626`, hairlines about 8 % white. The single accent is used
/// sparingly (send button, progress, the active model, the live readout).
enum Theme {

    // MARK: - Accent

    /// The accent in one place. `scripts/make-app-icon.swift` reads this literal to draw the app
    /// icon and to write `AccentColor.colorset`, so change it here and re-run that script.
    static let accentHex: UInt32 = 0xF5691F

    /// The accent color. In DEBUG builds the environment variable `LLM_ACCENT` (hex, e.g.
    /// `5AA5FF`) overrides it, so comparison screenshots can be rendered without rebuilding.
    static let accent: Color = Color(rgb: resolvedAccentHex)

    /// Glyph color on an accent fill: whichever of near-black or white contrasts more.
    static let onAccent: Color = {
        let accentLuminance = relativeLuminance(resolvedAccentHex)
        let dark = relativeLuminance(0x141414)
        let contrastWithDark = (accentLuminance + 0.05) / (dark + 0.05)
        let contrastWithWhite = 1.05 / (accentLuminance + 0.05)
        return contrastWithDark >= contrastWithWhite ? Color(rgb: 0x141414) : .white
    }()

    private static let resolvedAccentHex: UInt32 = {
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["LLM_ACCENT"],
                let value = UInt32(raw.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
            {
                return value
            }
        #endif
        return accentHex
    }()

    // MARK: - Neutrals (dark / light)

    static let background = Color(dark: 0x181818, light: 0xFFFFFF)
    /// Cards, code blocks, user bubbles.
    static let surface = Color(dark: 0x212121, light: 0xF3F3F3)
    /// Controls and chips placed on a surface.
    static let surfaceRaised = Color(dark: 0x2A2A2A, light: 0xE8E8E8)
    /// Grouped screens (Settings): page behind the rows.
    static let groupedBackground = Color(dark: 0x181818, light: 0xF2F2F2)
    /// Grouped screens: the rows.
    static let groupedRow = Color(dark: 0x222222, light: 0xFFFFFF)
    static let hairline = Color(dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x000000, lightAlpha: 0.08)

    static let textPrimary = Color(dark: 0xEDEDED, light: 0x161616)
    static let textSecondary = Color(dark: 0xA3A3A3, light: 0x505050)
    /// Still ≥ 4.5 : 1 on the background and on every surface (incl. `surfaceRaised`) in both
    /// appearances.
    static let textTertiary = Color(dark: 0x909090, light: 0x686868)

    // MARK: - Status colors (small marks only)

    static let positive = Color(dark: 0x3DD68C, light: 0x1E8A4C)
    static let caution = Color(dark: 0xF2C94C, light: 0xA86B00)
    static let critical = Color(dark: 0xFF6159, light: 0xD1281D)

    // MARK: - Shape and spacing

    enum Radius {
        static let card: CGFloat = 18
        static let bubble: CGFloat = 20
        static let code: CGFloat = 12
        static let composer: CGFloat = 24
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Horizontal page margin.
    static let margin: CGFloat = 16

    // MARK: - Helpers

    static func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((rgb >> 16) & 0xFF) + 0.7152 * channel((rgb >> 8) & 0xFF)
            + 0.0722 * channel(rgb & 0xFF)
    }
}

extension Color {
    init(rgb: UInt32, alpha: Double = 1) {
        self.init(uiColor: UIColor(rgb: rgb, alpha: alpha))
    }

    /// A color that follows the appearance.
    init(dark: UInt32, darkAlpha: Double = 1, light: UInt32, lightAlpha: Double = 1) {
        self.init(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(rgb: dark, alpha: darkAlpha) : UIColor(rgb: light, alpha: lightAlpha)
            })
    }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha)
    }
}

extension Font {
    /// Monospaced system font for numbers and code.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}
