import AppKit

/// Slice A helpers: color sampling, edge ruler, canvas resize.
/// None of these consume D / S / M / ⇧B — those stay free for slice B.

enum MeasureAxis: Equatable {
    case horizontal
    case vertical
}

enum SliceAHotkeys {
    /// Chrome copy only — stitcher already prepends on up-scroll.
    static let bidirectionalScrollHint =
        "Cuộn lên hoặc xuống — stitcher nối cả hai chiều"

    /// Honey slice B: Backdrop (D), Spotlight (S), Magnifier (M), Pixelate text (⇧B).
    static let reservedForSliceB: Set<String> = ["d", "s", "m"]

    static let editorToolKeys: [String: EditorTool] = [
        "v": .select, "a": .arrow, "l": .line, "r": .rect, "o": .oval,
        "h": .highlight, "p": .pen, "t": .text, "n": .counter, "b": .blur, "c": .crop,
    ]
}

enum PixelColorSampler {
    static func hexString(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)),
                      max(0, min(255, g)), max(0, min(255, b)))
    }

    static func sample(image: CGImage, at pixel: CGPoint) -> NSColor? {
        guard let buf = PixelSamplerCache.buffer(for: image) else { return nil }
        return buf.color(at: pixel)
    }

    /// Darkest pixel in a ~20×20 window (Shottr Shift+Tab: text color).
    /// Pointer completely outside the bitmap (window does not overlap)
    /// returns nil — never builds a closed range with lower > upper.
    static func darkest(
        image: CGImage, around pixel: CGPoint, radius: Int = 10
    ) -> NSColor? {
        guard radius >= 0, let buf = PixelSamplerCache.buffer(for: image) else {
            return nil
        }
        let cx = Int(pixel.x.rounded())
        let cy = Int(pixel.y.rounded())
        let x0 = max(0, cx - radius)
        let x1 = min(buf.width - 1, cx + radius)
        let y0 = max(0, cy - radius)
        let y1 = min(buf.height - 1, cy + radius)
        guard x0 <= x1, y0 <= y1 else { return nil }
        var bestLum = 1000
        var best: NSColor?
        for y in y0...y1 {
            for x in x0...x1 {
                guard let color = buf.color(x: x, y: y) else { continue }
                let lum = buf.luminance(x: x, y: y)
                if lum < bestLum {
                    bestLum = lum
                    best = color
                }
            }
        }
        return best
    }
}

enum EdgeRuler {
    struct Span: Equatable {
        var axis: MeasureAxis
        var start: CGFloat
        var end: CGFloat
        var cross: CGFloat
        var length: CGFloat { abs(end - start) }
    }

    /// Measure the uniform run containing `pixel` along `axis`.
    /// Mouse on a bar → bar width/height. Mouse on a gap → gap size.
    static func measure(
        image: CGImage, from pixel: CGPoint, axis: MeasureAxis
    ) -> Span? {
        guard let buf = PixelSamplerCache.buffer(for: image) else { return nil }
        let x = Int(pixel.x.rounded())
        let y = Int(pixel.y.rounded())
        guard buf.contains(x: x, y: y) else { return nil }
        let threshold = 28
        switch axis {
        case .horizontal:
            var left = x
            let origin = buf.luminance(x: x, y: y)
            while left > 0, abs(buf.luminance(x: left - 1, y: y) - origin) < threshold {
                left -= 1
            }
            var right = x
            while right + 1 < buf.width,
                  abs(buf.luminance(x: right + 1, y: y) - origin) < threshold {
                right += 1
            }
            return Span(
                axis: .horizontal,
                start: CGFloat(left),
                end: CGFloat(right + 1),
                cross: CGFloat(y))
        case .vertical:
            var bottom = y
            let origin = buf.luminance(x: x, y: y)
            while bottom > 0, abs(buf.luminance(x: x, y: bottom - 1) - origin) < threshold {
                bottom -= 1
            }
            var top = y
            while top + 1 < buf.height,
                  abs(buf.luminance(x: x, y: top + 1) - origin) < threshold {
                top += 1
            }
            return Span(
                axis: .vertical,
                start: CGFloat(bottom),
                end: CGFloat(top + 1),
                cross: CGFloat(x))
        }
    }
}

enum ImageResizer {
    /// Fail-closed caps applied as Doubles before any `Int` or CGContext.
    static let maxDimension = 32_768
    static let maxPixelCount = 268_435_456

    /// Scale pixel dimensions by `factor`. Backing `scale` is unchanged so
    /// point size follows pixels. Does **not** read or write `downscaleRetina`.
    static func scale(_ image: CapturedImage, by factor: CGFloat) -> CapturedImage? {
        guard factor > 0, factor.isFinite else { return nil }
        if abs(factor - 1) < 0.0001 { return image }
        let destW = (Double(image.cgImage.width) * Double(factor)).rounded()
        let destH = (Double(image.cgImage.height) * Double(factor)).rounded()
        guard destW.isFinite, destH.isFinite,
              destW >= 1, destH >= 1,
              destW <= Double(maxDimension), destH <= Double(maxDimension),
              destW * destH <= Double(maxPixelCount)
        else { return nil }
        let w = Int(destW)
        let h = Int(destH)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return CapturedImage(cgImage: out, scale: image.scale)
    }
}

/// One RGBA decode per `CGImage` identity. `mouseMoved` / Tab / ruler all
/// share it so a tall scroll shot is not recopied on every event.
enum PixelSamplerCache {
    private static var image: CGImage?
    private static var buffer: PixelBuffer?
    private(set) static var rebuildCount = 0

    static func resetForTesting() {
        image = nil
        buffer = nil
        rebuildCount = 0
    }

    fileprivate static func buffer(for image: CGImage) -> PixelBuffer? {
        if self.image === image, let buffer { return buffer }
        guard let built = PixelBuffer(image: image) else { return nil }
        self.image = image
        self.buffer = built
        rebuildCount += 1
        return built
    }
}

/// RGBA buffer in annotation space (bottom-left origin).
private struct PixelBuffer {
    let bytes: [UInt8]
    let width: Int
    let height: Int

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.bytes = bytes
        self.width = w
        self.height = h
    }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    func luminance(x: Int, y: Int) -> Int {
        let i = (y * width + x) * 4
        let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
        return (r * 54 + g * 183 + b * 19) / 256
    }

    func color(x: Int, y: Int) -> NSColor? {
        guard contains(x: x, y: y) else { return nil }
        let i = (y * width + x) * 4
        return NSColor(
            srgbRed: CGFloat(bytes[i]) / 255,
            green: CGFloat(bytes[i + 1]) / 255,
            blue: CGFloat(bytes[i + 2]) / 255,
            alpha: 1)
    }

    func color(at pixel: CGPoint) -> NSColor? {
        color(x: Int(pixel.x.rounded()), y: Int(pixel.y.rounded()))
    }
}
