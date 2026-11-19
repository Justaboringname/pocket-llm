#!/usr/bin/env swift
// Flags tinted greys in screenshots: pixels that are nearly grey (low chroma) but not neutral,
// i.e. the blue-black / warm-black drift the design rules out. Saturated pixels (the accent,
// status colors) are ignored.
//
//   swift scripts/check-neutral-greys.swift .build/screenshots/*.png
//
// Prints, per image, the share of "tinted grey" pixels and the most common offender.

import CoreGraphics
import Foundation
import ImageIO

var failed = false
for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { continue }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var tinted = 0
    var counts: [UInt32: Int] = [:]
    let total = width * height
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
        let chroma = max(r, g, b) - min(r, g, b)
        // 3…14: a grey with a cast. ≤ 2 is rounding; above 14 is an intentional color.
        if chroma >= 3, chroma <= 14 {
            tinted += 1
            counts[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), default: 0] += 1
        }
    }
    let share = Double(tinted) / Double(total) * 100
    let top = counts.max { $0.value < $1.value }
    let topText = top.map { String(format: "#%06X ×%d", $0.key, $0.value) } ?? "-"
    let verdict = share < 1.0 ? "ok" : "CHECK"
    if share >= 1.0 { failed = true }
    print(String(format: "%@  %5.2f%% tinted greys  (most common %@)  %@", verdict, share, topText,
                 (path as NSString).lastPathComponent))
}
exit(failed ? 1 : 0)
