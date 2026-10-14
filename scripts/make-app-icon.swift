// Builds AppIcon.appiconset from a source image that has the icon drawn on a dark canvas.
//   1. finds the icon's bright border (bounding box of pixels brighter than the background),
//   2. measures its corner radius from where the top edge starts,
//   3. masks everything outside that rounded rect to transparent,
//   4. places it on Apple's macOS grid (824 px tile centred in 1024 px), then writes all sizes.
// Usage: swift scripts/make-app-icon.swift Assets/app-icon-source.png AppleMusicPresence/Assets.xcassets/AppIcon.appiconset
import AppKit

let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Read pixels into RGBA8.
let w = source.width, h = source.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let readCtx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
readCtx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
func luminance(_ x: Int, _ y: Int) -> Int { // y counted from the top of the image
    let i = ((h - 1 - y) * w + x) * 4
    return (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
}

let threshold = 70
var minX = w, maxX = 0, minY = h, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) where luminance(x, y) > threshold {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let side = max(maxX - minX, maxY - minY)
let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
let crop = CGRect(x: midX - side / 2, y: midY - side / 2, width: side, height: side)

// Corner radius ≈ distance from the box's left edge to where the top border starts.
var topRunStart = minX
for x in minX...maxX where luminance(x, minY + 2) > threshold { topRunStart = x; break }
let radiusFraction = max(0.12, min(0.3, Double(topRunStart - minX) / Double(side)))
print("icon box \(crop.integral), corner radius ≈ \(Int(radiusFraction * 100))% of side")

// 1024 master on the macOS grid.
let canvas = 1024.0, tile = 824.0, inset = (canvas - tile) / 2
let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)
ctx.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 1, dy: 1), cornerWidth: tile * radiusFraction, cornerHeight: tile * radiusFraction, transform: nil))
ctx.clip()
let cgCrop = CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height) // CGImage crop uses top-left origin
ctx.draw(source.cropping(to: cgCrop)!, in: tileRect)
let master = ctx.makeImage()!

func write(_ pixelSize: Int, _ name: String) throws {
    let c = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(master, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    let data = NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent(name))
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(points * scale, name)
        images.append(#"    { "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)", "filename" : "\#(name)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) sizes to \(outDir.path)")
