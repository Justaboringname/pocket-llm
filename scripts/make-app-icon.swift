#!/usr/bin/env swift
// Draws the app icon and writes the accent color into the asset catalog.
//
//   swift scripts/make-app-icon.swift
//
// Reads the accent from `Theme.accentHex` in App/Sources/UI/Theme.swift (the one place it is
// defined) and writes:
//   App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  (opaque, no alpha)
//   App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json
// The artwork: three lines of text and a block caret — a reply being written — on a neutral
// dark field with a faint measurement grid. Same geometry as `AppMark` in Components.swift.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let themeFile = root.appending(path: "App/Sources/UI/Theme.swift")
let assets = root.appending(path: "App/Resources/Assets.xcassets")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: Accent from Theme.swift

guard let theme = try? String(contentsOf: themeFile, encoding: .utf8) else {
    fail("cannot read \(themeFile.path)")
}
let pattern = try Regex("static let accentHex: UInt32 = 0x([0-9A-Fa-f]{6})")
guard let match = theme.firstMatch(of: pattern), let hex = match.output[1].substring,
    let accent = UInt32(hex, radix: 16)
else {
    fail("accentHex not found in Theme.swift")
}

func components(_ rgb: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let (r, g, b) = components(rgb)
    return CGColor(colorSpace: space, components: [r, g, b, alpha])!
}

// MARK: Icon

let size = 1024
guard
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fail("cannot create bitmap context") }

// Core Graphics' origin is bottom-left; flip so the geometry reads top-down like the SwiftUI mark.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

// Field: neutral, a touch lighter at the top (R = G = B throughout).
let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x262626), color(0x161616)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])

// Measurement grid: faint dots.
context.setFillColor(color(0xFFFFFF, 0.055))
let pitch: CGFloat = 64
var y: CGFloat = pitch
while y < CGFloat(size) {
    var x: CGFloat = pitch
    while x < CGFloat(size) {
        context.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
        x += pitch
    }
    y += pitch
}

// The mark (unit square geometry shared with `AppMark`): three rounded lines and a block caret
// that sits on the last line. Its bounding box is centred on the canvas.
let lineHeight: CGFloat = 0.095
let lines: [(y: CGFloat, width: CGFloat)] = [(0.22, 0.80), (0.43, 0.64), (0.64, 0.38)]
let caretUnit = CGRect(x: 0.44, y: 0.5575, width: 0.12, height: 0.26)
let markBounds = CGRect(x: 0, y: 0.22, width: 0.80, height: caretUnit.maxY - 0.22)
let unit: CGFloat = 620
let origin = CGPoint(
    x: CGFloat(size) / 2 - markBounds.midX * unit, y: CGFloat(size) / 2 - markBounds.midY * unit)
func rect(_ r: CGRect) -> CGRect {
    CGRect(x: origin.x + r.minX * unit, y: origin.y + r.minY * unit, width: r.width * unit, height: r.height * unit)
}
context.setFillColor(color(0xC8C8C8))
for line in lines {
    let r = rect(CGRect(x: 0, y: line.y, width: line.width, height: lineHeight))
    context.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
    context.fillPath()
}
let caret = rect(caretUnit)
context.setFillColor(color(accent))
context.addPath(CGPath(roundedRect: caret, cornerWidth: unit * 0.022, cornerHeight: unit * 0.022, transform: nil))
context.fillPath()

guard let image = context.makeImage() else { fail("cannot render") }

let iconDirectory = assets.appending(path: "AppIcon.appiconset")
let accentDirectory = assets.appending(path: "AccentColor.colorset")
for directory in [iconDirectory, accentDirectory] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

let iconURL = iconDirectory.appending(path: "AppIcon-1024.png")
guard
    let destination = CGImageDestinationCreateWithURL(
        iconURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("cannot write \(iconURL.path)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("PNG encoding failed") }

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: url, options: .atomic)
}

let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], to: assets.appending(path: "Contents.json"))
try writeJSON(
    [
        "images": [
            ["filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]
        ],
        "info": info,
    ], to: iconDirectory.appending(path: "Contents.json"))

let (r, g, b) = components(accent)
func channel(_ value: CGFloat) -> String { String(format: "%.3f", value) }
try writeJSON(
    [
        "colors": [
            [
                "color": [
                    "color-space": "srgb",
                    "components": [
                        "alpha": "1.000", "red": channel(r), "green": channel(g), "blue": channel(b),
                    ],
                ],
                "idiom": "universal",
            ]
        ],
        "info": info,
    ], to: accentDirectory.appending(path: "Contents.json"))

print("accent #\(String(format: "%06X", accent))")
print("wrote \(iconURL.path.replacingOccurrences(of: root.path + "/", with: ""))")
