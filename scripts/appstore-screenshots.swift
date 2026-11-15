#!/usr/bin/env swift
// Turns window captures into Mac App Store screenshots.
//
//   swift scripts/appstore-screenshots.swift [options] capture1.png capture2.png ...
//
// Each capture is centred on a solid background at an accepted Mac App Store
// size (2880×1800 by default), scaled to fit, with an optional caption above
// it. The window's transparent corners and shadow are composited onto the
// background, and the output has no alpha channel, which App Store Connect
// requires. Files are written to AppStore/screenshots/ as 01.png, 02.png, …
// in the order given.
//
// Options:
//   --size WxH          2880x1800 (default), 2560x1600, 1440x900 or 1280x800
//   --background HEX    background colour, default 1C2433
//   --captions FILE     text file with one caption per line, in the same
//                       order as the captures; an empty line means no caption
//   --out DIR           output folder, default AppStore/screenshots
//
// Needs only Xcode's command line tools (it uses AppKit).

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let accepted: Set<String> = ["2880x1800", "2560x1600", "1440x900", "1280x800"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func color(hex: String) -> NSColor {
    let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard clean.count == 6, let value = UInt32(clean, radix: 16) else { fail("--background wants a colour like 1C2433") }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                   green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255,
                   alpha: 1)
}

// --- Arguments ---------------------------------------------------------------
var size = "2880x1800"
var background = color(hex: "1C2433")
var captionsPath: String?
var outDir = "AppStore/screenshots"
var inputs: [String] = []

var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
func value(for option: String) -> String {
    guard let next = args.next() else { fail("\(option) needs a value") }
    return next
}
while let arg = args.next() {
    switch arg {
    case "--size": size = value(for: arg)
    case "--background": background = color(hex: value(for: arg))
    case "--captions": captionsPath = value(for: arg)
    case "--out": outDir = value(for: arg)
    case "-h", "--help":
        print("usage: swift scripts/appstore-screenshots.swift [--size 2880x1800] [--background 1C2433] [--captions captions.txt] [--out DIR] capture.png ...")
        exit(0)
    default:
        if arg.hasPrefix("--") { fail("unknown option \(arg)") }
        inputs.append(arg)
    }
}
guard !inputs.isEmpty else { fail("give at least one capture (PNG or JPEG)") }
guard inputs.count <= 10 else { fail("App Store Connect takes at most 10 screenshots") }
guard accepted.contains(size) else { fail("--size must be one of \(accepted.sorted().joined(separator: ", "))") }
let parts = size.split(separator: "x").compactMap { Int($0) }
let width = parts[0], height = parts[1]

var captions: [String] = []
if let captionsPath {
    guard let text = try? String(contentsOfFile: captionsPath, encoding: .utf8) else { fail("can't read \(captionsPath)") }
    captions = text.components(separatedBy: .newlines)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// --- Layout (in output pixels; scaled from the 2880×1800 design) ---------------
let unit = CGFloat(width) / 2880
let margin = 110 * unit
let captionFont = NSFont.systemFont(ofSize: 92 * unit, weight: .semibold)
let captionHeight = 200 * unit

for (index, path) in inputs.enumerated() {
    // Read pixels directly, so a Retina capture keeps its full resolution.
    guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cgSource = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        fail("can't read the image \(path)")
    }
    let caption = index < captions.count ? captions[index].trimmingCharacters(in: .whitespaces) : ""

    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("can't make a \(size) canvas")
    }
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(background.cgColor)
    context.fill(canvas)

    // Area for the window: everything inside the margins, below the caption.
    var area = canvas.insetBy(dx: margin, dy: margin)
    if !caption.isEmpty { area.size.height -= captionHeight }

    let sourceWidth = CGFloat(cgSource.width), sourceHeight = CGFloat(cgSource.height)
    let scale = min(area.width / sourceWidth, area.height / sourceHeight)
    if scale > 1.05 {
        print("note: \(path) is \(cgSource.width)×\(cgSource.height) and is enlarged \(String(format: "%.1f", scale))×; capture on a Retina display for a sharper result")
    }
    let drawn = CGRect(x: area.midX - sourceWidth * scale / 2,
                       y: area.midY - sourceHeight * scale / 2,
                       width: sourceWidth * scale, height: sourceHeight * scale)
    context.interpolationQuality = .high
    context.draw(cgSource, in: drawn)

    if !caption.isEmpty {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: caption, attributes: attributes)
        let textHeight = text.boundingRect(with: CGSize(width: canvas.width - 2 * margin, height: captionHeight),
                                           options: [.usesLineFragmentOrigin]).height
        let top = canvas.height - margin * 0.8
        text.draw(with: CGRect(x: margin, y: top - captionHeight / 2 - textHeight / 2,
                               width: canvas.width - 2 * margin, height: textHeight),
                  options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    guard let image = context.makeImage() else { fail("can't render \(path)") }
    let outURL = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "%02d.png", index + 1))
    guard let destination = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(outURL.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(outURL.path)") }
    print("\(outURL.path)  \(width)×\(height)  \(caption.isEmpty ? "(no caption)" : caption)")
}
