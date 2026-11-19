#!/usr/bin/env swift
// Puts three screenshots side by side with A/B/C labels (accent comparison for design review).
//
//   swift scripts/compose-accent-compare.swift OUT.png "A  #F5691F" a.png "B  #5AA5FF" b.png "C  #EDEDED" c.png
//
// Uses only CoreGraphics / CoreText / ImageIO.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, (arguments.count - 1) % 2 == 0 else {
    FileHandle.standardError.write(Data("usage: OUT.png LABEL IMAGE [LABEL IMAGE …]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[0])
var panels: [(label: String, image: CGImage)] = []
for index in stride(from: 1, to: arguments.count, by: 2) {
    let url = URL(fileURLWithPath: arguments[index + 1]) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        FileHandle.standardError.write(Data("cannot read \(arguments[index + 1])\n".utf8))
        exit(1)
    }
    panels.append((arguments[index], image))
}

let gap = 48
let margin = 64
let header = 150
let width = panels.reduce(0) { $0 + $1.image.width } + gap * (panels.count - 1) + margin * 2
let height = (panels.map(\.image.height).max() ?? 0) + header + margin
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { exit(1) }

context.setFillColor(CGColor(colorSpace: space, components: [0.07, 0.07, 0.07, 1])!)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

let font = CTFontCreateWithName("SFMono-Semibold" as CFString, 56, nil)
var x = margin
for panel in panels {
    let imageRect = CGRect(x: x, y: margin, width: panel.image.width, height: panel.image.height)
    context.draw(panel.image, in: imageRect)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(colorSpace: space, components: [0.93, 0.93, 0.93, 1])!,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: panel.label, attributes: attributes))
    context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(margin + panel.image.height + 52))
    CTLineDraw(line, context)
    x += panel.image.width + gap
}

guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("wrote \(output.path) (\(width)×\(height))")
