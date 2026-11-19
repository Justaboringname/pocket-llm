// Re-encodes PNG files in place as opaque RGB (no alpha channel). App Store Connect rejects
// screenshots that have an alpha channel, and `simctl io screenshot` writes RGBA.
//
// Usage: swift scripts/strip-alpha.swift <file.png> [<file.png> …]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var failures = 0
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        FileHandle.standardError.write(Data("strip-alpha: cannot read \(path)\n".utf8))
        failures += 1
        continue
    }
    let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
        FileHandle.standardError.write(Data("strip-alpha: no context for \(path)\n".utf8))
        failures += 1
        continue
    }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    // Screenshots are fully opaque already; composite over black just in case.
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)
    guard let opaque = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
    else {
        failures += 1
        continue
    }
    CGImageDestinationAddImage(destination, opaque, nil)
    if !CGImageDestinationFinalize(destination) {
        FileHandle.standardError.write(Data("strip-alpha: cannot write \(path)\n".utf8))
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
