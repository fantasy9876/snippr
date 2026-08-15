import AppKit

enum EditorTool: String, CaseIterable {
    case select, arrow, line, rect, oval, highlight, pen, text, counter, blur, crop

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .highlight: return "highlighter"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "drop.halffull"
        case .crop: return "crop"
        }
    }

    var tooltip: String {
        switch self {
        case .select: return "Select / Move (V)"
        case .arrow: return "Arrow (A)"
        case .line: return "Line (L)"
        case .rect: return "Rectangle (R)"
        case .oval: return "Oval (O)"
        case .highlight: return "Highlighter (H)"
        case .pen: return "Pen (P)"
        case .text: return "Text (T)"
        case .counter: return "Counter (N)"
        case .blur: return "Pixelate (B)"
        case .crop: return "Crop (C)"
        }
    }
}

// MARK: - Annotation base

/// All coordinates are in image PIXEL space. `uiScale` converts point-based
/// stroke widths/fonts to pixels so they match the image density.
class Annotation {
    var color: NSColor = .systemRed
    var strokeWidthPt: CGFloat = 3
    let uiScale: CGFloat

    init(uiScale: CGFloat) { self.uiScale = uiScale }

    var strokeWidth: CGFloat { strokeWidthPt * uiScale }
    var bounds: CGRect { .zero }

    func draw(in ctx: CGContext, pixellated: CGImage?) {}
    func hitTest(_ p: CGPoint) -> Bool { bounds.insetBy(dx: -8 * uiScale, dy: -8 * uiScale).contains(p) }
    func move(by delta: CGPoint) {}
    func copyAnnotation() -> Annotation { self }
}

// MARK: - Shapes (arrow / line / rect / oval / highlight)

final class ShapeAnnotation: Annotation {
    enum Kind { case arrow, line, rect, oval, highlight }
    let kind: Kind
    var start: CGPoint
    var end: CGPoint

    init(kind: Kind, start: CGPoint, end: CGPoint, uiScale: CGFloat) {
        self.kind = kind
        self.start = start
        self.end = end
        super.init(uiScale: uiScale)
    }

    override var bounds: CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(start.x - end.x), height: abs(start.y - end.y)
        )
    }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch kind {
        case .line:
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        case .arrow:
            drawArrow(in: ctx)
        case .rect:
            ctx.stroke(bounds)
        case .oval:
            ctx.strokeEllipse(in: bounds)
        case .highlight:
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
            ctx.fill(bounds)
        }
    }

    private func drawArrow(in ctx: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let len = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)
        let headLen = min(len * 0.35, 14 * uiScale + strokeWidth * 2.2)
        let headWidth = headLen * 0.62

        let tip = end
        let base = CGPoint(x: end.x - cos(angle) * headLen, y: end.y - sin(angle) * headLen)
        let perp = CGPoint(x: -sin(angle), y: cos(angle))
        let p1 = CGPoint(x: base.x + perp.x * headWidth / 2, y: base.y + perp.y * headWidth / 2)
        let p2 = CGPoint(x: base.x - perp.x * headWidth / 2, y: base.y - perp.y * headWidth / 2)

        ctx.move(to: start)
        ctx.addLine(to: base)
        ctx.strokePath()

        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        let pad = 8 * uiScale
        switch kind {
        case .line, .arrow:
            return distanceToSegment(p, start, end) < pad + strokeWidth
        case .rect, .oval, .highlight:
            if kind == .highlight { return bounds.contains(p) }
            let outer = bounds.insetBy(dx: -pad, dy: -pad)
            let inner = bounds.insetBy(dx: pad, dy: pad)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        }
    }

    override func move(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
    }

    override func copyAnnotation() -> Annotation {
        let c = ShapeAnnotation(kind: kind, start: start, end: end, uiScale: uiScale)
        c.color = color
        c.strokeWidthPt = strokeWidthPt
        return c
    }
}

// MARK: - Pen (freehand)

final class PenAnnotation: Annotation {
    var points: [CGPoint] = []

    override var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: points[0])
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: points[i])
        }
        ctx.addLine(to: points[points.count - 1])
        ctx.strokePath()
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        let pad = 8 * uiScale + strokeWidth
        for i in 0..<max(0, points.count - 1) {
            if distanceToSegment(p, points[i], points[i + 1]) < pad { return true }
        }
        return false
    }

    override func move(by delta: CGPoint) {
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    override func copyAnnotation() -> Annotation {
        let c = PenAnnotation(uiScale: uiScale)
        c.points = points
        c.color = color
        c.strokeWidthPt = strokeWidthPt
        return c
    }
}

// MARK: - Text

final class TextAnnotation: Annotation {
    var text: String = ""
    var origin: CGPoint = .zero // BOTTOM-left of the text's bounding box, image px (unflipped ctx)
    var fontSizePt: CGFloat = 18

    var font: NSFont { .boldSystemFont(ofSize: fontSizePt * uiScale) }

    private var textSize: CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attrs)
        return CGSize(width: max(size.width, 10), height: max(size.height, 10))
    }

    override var bounds: CGRect {
        CGRect(origin: origin, size: textSize)
    }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        guard !text.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        // CGContext for images is unflipped (origin bottom-left); NSString.draw needs NSGraphicsContext
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * uiScale), blur: 2 * uiScale,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        (text as NSString).draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func move(by delta: CGPoint) {
        origin.x += delta.x
        origin.y += delta.y
    }

    override func copyAnnotation() -> Annotation {
        let c = TextAnnotation(uiScale: uiScale)
        c.text = text
        c.origin = origin
        c.fontSizePt = fontSizePt
        c.color = color
        return c
    }
}

// MARK: - Counter badge

final class CounterAnnotation: Annotation {
    var center: CGPoint = .zero
    var number: Int = 1
    var radiusPt: CGFloat = 14

    var radius: CGFloat { radiusPt * uiScale }

    override var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * uiScale), blur: 3 * uiScale,
                      color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: bounds)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: radiusPt * 1.05 * uiScale),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: "\(number)", attributes: attrs)
        let size = str.size()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        str.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        hypot(p.x - center.x, p.y - center.y) <= radius + 6 * uiScale
    }

    override func move(by delta: CGPoint) {
        center.x += delta.x
        center.y += delta.y
    }

    override func copyAnnotation() -> Annotation {
        let c = CounterAnnotation(uiScale: uiScale)
        c.center = center
        c.number = number
        c.radiusPt = radiusPt
        c.color = color
        return c
    }
}

// MARK: - Blur / pixelate region

final class BlurAnnotation: Annotation {
    var rect: CGRect = .zero

    override var bounds: CGRect { rect }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        guard let pixellated, rect.width > 1, rect.height > 1 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        ctx.draw(pixellated, in: CGRect(x: 0, y: 0, width: pixellated.width, height: pixellated.height))
    }

    override func hitTest(_ p: CGPoint) -> Bool { rect.contains(p) }

    override func move(by delta: CGPoint) {
        rect.origin.x += delta.x
        rect.origin.y += delta.y
    }

    override func copyAnnotation() -> Annotation {
        let c = BlurAnnotation(uiScale: uiScale)
        c.rect = rect
        return c
    }
}

// MARK: - Rendering

enum AnnotationRenderer {
    /// Flatten base image + annotations into a single CGImage (pixel space).
    static func render(base: CGImage, annotations: [Annotation], pixellated: CGImage?) -> CGImage {
        let w = base.width, h = base.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        for a in annotations {
            a.draw(in: ctx, pixellated: pixellated)
        }
        return ctx.makeImage() ?? base
    }

    /// One CIContext for the process: creating one per pixellate call paid
    /// ~50-150 ms of Metal pipeline setup again after every crop/undo.
    private static let ciContext = CIContext()

    /// CIPixellate over the whole image; BlurAnnotation clips regions out of this.
    static func pixellate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard let out = pixelatedCIImage(image, scale: scale) else { return nil }
        return ciContext.createCGImage(
            out, from: CGRect(
                x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Regional output for in-place overlays. Core Image remains lazy over
    /// the base descriptor and materializes only `rect`, preserving the
    /// original image-space pixel grid without a 5K×40K RGBA cache.
    static func pixellateRegion(
        _ image: CGImage, rect: CGRect, scale: CGFloat
    ) -> CGImage? {
        let bounds = CGRect(
            x: 0, y: 0, width: image.width, height: image.height)
        let region = rect.standardized.integral.intersection(bounds)
        guard region.width > 1, region.height > 1,
              let out = pixelatedCIImage(image, scale: scale)
        else { return nil }
        // Record the exact extent passed to Core Image, not merely the blur's
        // requested bounds. This keeps the allocation gate coupled to the
        // actual output materialization call.
        AnnotationSurface.regionalPixelateAllocationsForTesting += 1
        AnnotationSurface.lastRegionalPixelateRectForTesting = region
        AnnotationSurface.lastRegionalPixelateBaseSizeForTesting = CGSize(
            width: image.width, height: image.height)
        return ciContext.createCGImage(out, from: region)
    }

    private static func pixelatedCIImage(
        _ image: CGImage, scale: CGFloat
    ) -> CIImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(max(8, 8 * scale), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        return filter.outputImage
    }
}

// MARK: - Geometry helpers

func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x, aby = b.y - a.y
    let lenSq = abx * abx + aby * aby
    if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq
    t = max(0, min(1, t))
    let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
    return hypot(p.x - proj.x, p.y - proj.y)
}
