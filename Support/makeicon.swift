// Renders the Snippr app icon: `swift Support/makeicon.swift <out.png>`
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024

let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let s = CGFloat(size)
// macOS-style rounded square with margin
let margin = s * 0.098
let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
let path = CGPath(roundedRect: rect, cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil)

ctx.addPath(path)
ctx.clip()

let colors = [
    CGColor(srgbRed: 0.13, green: 0.14, blue: 0.20, alpha: 1),
    CGColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// dashed selection frame
let frame = rect.insetBy(dx: s * 0.16, dy: s * 0.16)
ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1))
ctx.setLineWidth(s * 0.030)
ctx.setLineDash(phase: 0, lengths: [s * 0.075, s * 0.045])
ctx.stroke(frame)
ctx.setLineDash(phase: 0, lengths: [])

// corner brackets
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(s * 0.042)
ctx.setLineCap(.round)
let bl = s * 0.10
for (cx, cy, dx, dy) in [
    (frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
    (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0),
] {
    ctx.move(to: CGPoint(x: cx + CGFloat(dx) * bl, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy + CGFloat(dy) * bl))
    ctx.strokePath()
}

// "S" glyph
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: s * 0.42, weight: .heavy),
    .foregroundColor: NSColor.white,
]
let str = NSAttributedString(string: "S", attributes: attrs)
let strSize = str.size()
str.draw(at: CGPoint(x: (s - strSize.width) / 2, y: (s - strSize.height) / 2))
NSGraphicsContext.restoreGraphicsState()

ctx.resetClip()
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
