// Renders the two Rich Presence art assets to upload to the Discord application:
//   logo   – fallback cover when a track has no Apple Music catalogue match
//   paused – small badge shown on the cover while paused (if "keep showing" is on)
// Usage: swift scripts/make-discord-assets.swift Assets/discord
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = 1024

func render(_ name: String, _ draw: (CGContext, CGFloat) -> Void) throws {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, s)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = outDir.appendingPathComponent("\(name).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", url.path)
}

try render("logo") { ctx, s in
    // Rounded square with a pink→red gradient.
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil))
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.98, green: 0.36, blue: 0.47, alpha: 1), CGColor(srgbRed: 0.96, green: 0.18, blue: 0.27, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Beamed eighth notes: two heads, two stems, one beam.
    ctx.setFillColor(.white)
    let head = CGSize(width: s * 0.20, height: s * 0.15)
    for (x, y) in [(0.27, 0.24), (0.57, 0.31)] {
        ctx.saveGState()
        ctx.translateBy(x: s * x + head.width / 2, y: s * y + head.height / 2)
        ctx.rotate(by: 0.35)
        ctx.fillEllipse(in: CGRect(x: -head.width / 2, y: -head.height / 2, width: head.width, height: head.height))
        ctx.restoreGState()
    }
    let stem = s * 0.045
    ctx.fill(CGRect(x: s * 0.27 + head.width - stem, y: s * 0.30, width: stem, height: s * 0.48))
    ctx.fill(CGRect(x: s * 0.57 + head.width - stem, y: s * 0.37, width: stem, height: s * 0.48))
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: s * 0.27 + head.width - stem, y: s * 0.78))
    beam.addLine(to: CGPoint(x: s * 0.57 + head.width, y: s * 0.85))
    beam.addLine(to: CGPoint(x: s * 0.57 + head.width, y: s * 0.75))
    beam.addLine(to: CGPoint(x: s * 0.27 + head.width - stem, y: s * 0.68))
    beam.closeSubpath()
    ctx.addPath(beam)
    ctx.fillPath()
}

try render("paused") { ctx, s in
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setFillColor(.white)
    let barWidth = s * 0.13, barHeight = s * 0.42, gap = s * 0.11
    for x in [s / 2 - gap / 2 - barWidth, s / 2 + gap / 2] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: (s - barHeight) / 2, width: barWidth, height: barHeight),
                           cornerWidth: barWidth * 0.3, cornerHeight: barWidth * 0.3, transform: nil))
    }
    ctx.fillPath()
}
