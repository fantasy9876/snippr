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
    /// Pixel-space scale used by the editor resize badge. Stroke/font sizes
    /// grow with the bitmap so marks keep the same relative weight.
    func scaleCoordinates(by factor: CGFloat) {
        strokeWidthPt *= factor
    }
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

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        start = CGPoint(x: start.x * factor, y: start.y * factor)
        end = CGPoint(x: end.x * factor, y: end.y * factor)
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

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        points = points.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
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

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        origin = CGPoint(x: origin.x * factor, y: origin.y * factor)
        fontSizePt *= factor
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

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        center = CGPoint(x: center.x * factor, y: center.y * factor)
        radiusPt *= factor
    }
}

// MARK: - Blur / pixelate region

final class BlurAnnotation: Annotation {
    var rect: CGRect = .zero

    /// Slice B: rect pixelate today, text-only pixelate once the compositor
    /// lands. `.rect` keeps the existing behaviour.
    var redactionState: RedactionState = .rect

    /// Bumped whenever the annotation is edited, so a late OCR result can tell
    /// it is answering a question nobody is asking any more.
    private(set) var redactionGeneration = 0

    func bumpRedactionGeneration() {
        redactionGeneration += 1
        normalizePendingRedaction()
    }

    /// An edit supersedes any OCR job in flight. Pending must collapse to the
    /// FULL mask rather than linger: an orphan `pendingFull` would keep the
    /// area covered but never resolve, and the user could not tell why.
    func normalizePendingRedaction() {
        if redactionState == .pendingFull { redactionState = .fallbackFull }
    }

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
        // The word boxes are absolute image pixels: leaving them behind would
        // slide the mask off the glyphs it is covering.
        if case let .words(words) = redactionState {
            redactionState = .words(
                words.map { $0.offsetBy(dx: delta.x, dy: delta.y) })
        }
        bumpRedactionGeneration()
    }

    override func copyAnnotation() -> Annotation {
        let c = BlurAnnotation(uiScale: uiScale)
        c.rect = rect
        // The copy owns no OCR job, so a pending mask would never resolve on
        // it. Clone it as the FULL mask instead of an orphan pending.
        c.redactionState = redactionState == .pendingFull
            ? .fallbackFull : redactionState
        return c
    }

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        rect = CGRect(
            x: rect.origin.x * factor, y: rect.origin.y * factor,
            width: rect.width * factor, height: rect.height * factor)
        if case let .words(words) = redactionState {
            redactionState = .words(words.map {
                CGRect(
                    x: $0.origin.x * factor, y: $0.origin.y * factor,
                    width: $0.width * factor, height: $0.height * factor)
            })
        }
        bumpRedactionGeneration()
    }
}

// MARK: - Guide (⌥S vertical / ⌥D horizontal)

final class GuideAnnotation: Annotation {
    var axis: MeasureAxis
    var position: CGFloat
    /// Length along the image's other axis at imprint time. Keeps selection
    /// chrome on the canvas instead of a 2e6-px box.
    var length: CGFloat

    init(axis: MeasureAxis, position: CGFloat, length: CGFloat = 1_000_000,
         uiScale: CGFloat) {
        self.axis = axis
        self.position = position
        self.length = max(1, length)
        super.init(uiScale: uiScale)
        color = NSColor.systemTeal
        strokeWidthPt = 1
    }

    override var bounds: CGRect {
        let pad = 4 * uiScale
        switch axis {
        case .vertical:
            return CGRect(x: position - pad, y: 0,
                          width: pad * 2, height: length)
        case .horizontal:
            return CGRect(x: 0, y: position - pad,
                          width: length, height: pad * 2)
        }
    }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(max(1, uiScale))
        ctx.setLineDash(phase: 0, lengths: [5 * uiScale, 4 * uiScale])
        switch axis {
        case .vertical:
            ctx.move(to: CGPoint(x: position, y: 0))
            ctx.addLine(to: CGPoint(x: position, y: length))
        case .horizontal:
            ctx.move(to: CGPoint(x: 0, y: position))
            ctx.addLine(to: CGPoint(x: length, y: position))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        let pad = 6 * uiScale
        switch axis {
        case .vertical: return abs(p.x - position) <= pad
        case .horizontal: return abs(p.y - position) <= pad
        }
    }

    override func move(by delta: CGPoint) {
        switch axis {
        case .vertical: position += delta.x
        case .horizontal: position += delta.y
        }
    }

    override func copyAnnotation() -> Annotation {
        let c = GuideAnnotation(
            axis: axis, position: position, length: length, uiScale: uiScale)
        c.color = color
        return c
    }

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        position *= factor
        length *= factor
    }
}

// MARK: - Imprinted ruler (arrow keys + click)

final class RulerAnnotation: Annotation {
    var span: EdgeRuler.Span

    init(span: EdgeRuler.Span, uiScale: CGFloat) {
        self.span = span
        super.init(uiScale: uiScale)
        color = NSColor.systemYellow
        strokeWidthPt = 1
    }

    override var bounds: CGRect {
        let pad = 18 * uiScale
        switch span.axis {
        case .horizontal:
            return CGRect(
                x: min(span.start, span.end) - pad,
                y: span.cross - pad,
                width: span.length + pad * 2,
                height: pad * 2)
        case .vertical:
            return CGRect(
                x: span.cross - pad,
                y: min(span.start, span.end) - pad,
                width: pad * 2,
                height: span.length + pad * 2)
        }
    }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        drawRuler(
            span, in: ctx, uiScale: uiScale, color: color, preview: false)
    }

    override func hitTest(_ p: CGPoint) -> Bool { bounds.contains(p) }

    override func move(by delta: CGPoint) {
        switch span.axis {
        case .horizontal:
            span.start += delta.x
            span.end += delta.x
            span.cross += delta.y
        case .vertical:
            span.start += delta.y
            span.end += delta.y
            span.cross += delta.x
        }
    }

    override func copyAnnotation() -> Annotation {
        let c = RulerAnnotation(span: span, uiScale: uiScale)
        c.color = color
        return c
    }

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        span.start *= factor
        span.end *= factor
        span.cross *= factor
    }
}

func drawRuler(
    _ span: EdgeRuler.Span, in ctx: CGContext,
    uiScale: CGFloat, color: NSColor, preview: Bool
) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    let alpha: CGFloat = preview ? 0.85 : 1
    ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
    ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
    ctx.setLineWidth(max(1, uiScale))
    let a: CGPoint
    let b: CGPoint
    switch span.axis {
    case .horizontal:
        a = CGPoint(x: span.start, y: span.cross)
        b = CGPoint(x: span.end, y: span.cross)
    case .vertical:
        a = CGPoint(x: span.cross, y: span.start)
        b = CGPoint(x: span.cross, y: span.end)
    }
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
    let tick: CGFloat = 6 * uiScale
    switch span.axis {
    case .horizontal:
        ctx.move(to: CGPoint(x: a.x, y: a.y - tick))
        ctx.addLine(to: CGPoint(x: a.x, y: a.y + tick))
        ctx.move(to: CGPoint(x: b.x, y: b.y - tick))
        ctx.addLine(to: CGPoint(x: b.x, y: b.y + tick))
    case .vertical:
        ctx.move(to: CGPoint(x: a.x - tick, y: a.y))
        ctx.addLine(to: CGPoint(x: a.x + tick, y: a.y))
        ctx.move(to: CGPoint(x: b.x - tick, y: b.y))
        ctx.addLine(to: CGPoint(x: b.x + tick, y: b.y))
    }
    ctx.strokePath()

    let label = "\(Int(span.length.rounded())) px"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * uiScale, weight: .semibold),
        .foregroundColor: NSColor.white,
        .backgroundColor: color.withAlphaComponent(0.92),
    ]
    let str = NSAttributedString(string: " \(label) ", attributes: attrs)
    let size = str.size()
    let origin = CGPoint(
        x: (a.x + b.x) / 2 - size.width / 2,
        y: (a.y + b.y) / 2 + 6 * uiScale)
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    str.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Rendering

enum AnnotationRenderer {
    /// Flatten base image + annotations into a single CGImage (pixel space).
    /// Preview-grade flatten. Redactions render through the shared compositor
    /// (phases + regional pixelation), so a failure paints an opaque cover
    /// instead of leaving the pixels underneath visible. Export must use
    /// `SliceBExport.checkedRender`, which fails closed.
    static func render(base: CGImage, annotations: [Annotation], pixellated: CGImage?) -> CGImage {
        let w = base.width, h = base.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        SliceBCompositor.draw(
            annotations, in: ctx, base: base,
            visiblePixels: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? base
    }

    /// One CIContext for the process: creating one per pixellate call paid
    /// ~50-150 ms of Metal pipeline setup again after every crop/undo.
    private static let ciContext = CIContext()

    /// Spy for the gates: a full-image pixelate is exactly the allocation the
    /// slice B compositor must never make on a tall stitch.
    nonisolated(unsafe) static var fullImagePixellateCallsForTesting = 0

    /// CIPixellate over the whole image; BlurAnnotation clips regions out of this.
    static func pixellate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        fullImagePixellateCallsForTesting += 1
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
        AnnotationSurface.allRegionalPixelateRectsForTesting.append(region)
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
