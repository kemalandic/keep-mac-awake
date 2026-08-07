import AppKit
import CoreGraphics
import Foundation

// Turns a square artwork PNG into a macOS-style app icon master:
//   1. finds the drawn rounded-rect inside the source (the art has opaque
//      black outside it, which would render as a black square in the Dock)
//   2. crops to it, clips to a rounded rect so the corners become transparent
//   3. draws it at 824x824 centred on a 1024x1024 transparent canvas, which is
//      the proportion Apple's own app icons use

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: makeicon <in.png> <out.png>\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: inputURL),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("could not read source image\n".utf8))
    exit(1)
}

let width = sourceCG.width
let height = sourceCG.height

// Read raw pixels so we can locate the artwork's own rounded rect.
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
guard let readContext = CGContext(
    data: &pixels,
    width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
readContext.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

/// Brightness of a pixel, 0-255.
func luma(_ x: Int, _ y: Int) -> Int {
    let offset = y * bytesPerRow + x * 4
    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
    return (r * 299 + g * 587 + b * 114) / 1000
}

// The art sits on near-black; its rim is brighter. Scan the middle row/column.
let threshold = 24
let midY = height / 2
let midX = width / 2

var left = 0
while left < midX, luma(left, midY) <= threshold { left += 1 }
var right = width - 1
while right > midX, luma(right, midY) <= threshold { right -= 1 }
var top = 0
while top < midY, luma(midX, top) <= threshold { top += 1 }
var bottom = height - 1
while bottom > midY, luma(midX, bottom) <= threshold { bottom -= 1 }

// Use the tightest common inset so the crop stays square and centred.
let inset = max(0, min(min(left, width - 1 - right), min(top, height - 1 - bottom)))
let cropSize = min(width, height) - inset * 2
let cropRect = CGRect(x: inset, y: inset, width: cropSize, height: cropSize)

print("detected inset: \(inset)px  (left \(left), right \(width - 1 - right), top \(top), bottom \(height - 1 - bottom))")
print("crop: \(cropSize)x\(cropSize)")

guard let cropped = sourceCG.cropping(to: cropRect) else { exit(1) }

// Compose the final 1024 master.
let canvas = 1024
let artSize = 824.0
let origin = (Double(canvas) - artSize) / 2.0
let cornerRadius = artSize * 0.2237   // Apple's app-icon corner proportion

guard let outContext = CGContext(
    data: nil,
    width: canvas, height: canvas,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

outContext.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let artRect = CGRect(x: origin, y: origin, width: artSize, height: artSize)
let path = CGPath(roundedRect: artRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
outContext.addPath(path)
outContext.clip()
outContext.interpolationQuality = .high
outContext.draw(cropped, in: artRect)

guard let result = outContext.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: result)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: outputURL)

print("wrote \(outputURL.path) — \(canvas)x\(canvas), transparent corners")
