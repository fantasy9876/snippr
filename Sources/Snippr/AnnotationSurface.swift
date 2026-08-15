import AppKit

/// Narrow persistence seam for overlay stroke widths. Production delegates
/// to the editor's canonical Settings keys; self-tests inject memory-only
/// closures so they never mutate the user's annotation preferences.
struct OverlayStrokeWidthStore {
    let read: (String) -> CGFloat
    let write: (CGFloat, String) -> Void

    static let live = OverlayStrokeWidthStore(
        read: { Settings.shared.toolWidth(for: $0) },
        write: { Settings.shared.setToolWidth($0, for: $1) })
}

/// V1 in-place annotation tools (plan P1): a deliberate subset of the editor.
enum OverlayAnnotationTool: String, CaseIterable {
    case select
    case pen
    case arrow
    case rect
    case text
    case line
    case oval
    case highlight
    case counter
    case blur

    static let toolbarTagBase = 100
    static let colorToolbarTag = 200
    static let undoToolbarTag = 201

    var toolbarTag: Int {
        Self.toolbarTagBase + Self.allCases.firstIndex(of: self)!
    }

    static func tool(forToolbarTag tag: Int) -> Self? {
        let index = tag - toolbarTagBase
        guard allCases.indices.contains(index) else { return nil }
        return allCases[index]
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .oval: return "circle"
        case .highlight: return "highlighter"
        case .counter: return "1.circle"
        case .blur: return "drop.halffull"
        }
    }

    var tooltip: String {
        switch self {
        case .select: return "Select / Resize frame (V)"
        case .pen: return "Pen (P)"
        case .arrow: return "Arrow (A)"
        case .rect: return "Rectangle (R)"
        case .text: return "Text (T)"
        case .line: return "Line (L)"
        case .oval: return "Oval (O)"
        case .highlight: return "Highlighter (H)"
        case .counter: return "Counter (N)"
        case .blur: return "Pixelate (B)"
        }
    }
}

/// Annotation state + input handling shared by BOTH in-place surfaces (the
/// area-review overlay and the scroll-result panel). Coordinates live in the
/// BASE image's pixel space — absolutely positioned, so a crop move/resize
/// never drags drawings along; flatten clips them against the crop
/// (QA invariant 24). Reuses the editor's `Annotation` model and renderer so
/// the two surfaces cannot drift.
@MainActor
final class AnnotationSurface {
    /// Tests replace this before constructing a surface. Production callers
    /// leave it nil and therefore share the editor's Settings-backed store.
    static var strokeWidthStoreOverrideForTesting: OverlayStrokeWidthStore?

    private(set) var annotations: [Annotation] = []
    var tool: OverlayAnnotationTool = .select
    var color: NSColor = .systemRed
    /// Converts point-based stroke widths to pixels (the base image's scale).
    let pixelScale: CGFloat
    let strokeWidthStore: OverlayStrokeWidthStore

    private var activeShape: ShapeAnnotation?
    private var activePen: PenAnnotation?
    private var activeBlur: BlurAnnotation?
    private var activeBlurAnchor: CGPoint?

    init(
        pixelScale: CGFloat,
        strokeWidthStore: OverlayStrokeWidthStore? = nil
    ) {
        self.pixelScale = max(1, pixelScale)
        self.strokeWidthStore = strokeWidthStore
            ?? Self.strokeWidthStoreOverrideForTesting
            ?? .live
    }

    var isEmpty: Bool { annotations.isEmpty }

    // MARK: drag lifecycle (image-pixel coordinates)

    /// Returns true when the surface consumed the drag start (tool != select).
    func beginDrag(atPixel p: CGPoint) -> Bool {
        switch tool {
        case .select:
            return false
        case .pen:
            let pen = PenAnnotation(uiScale: pixelScale)
            pen.color = color
            pen.points = [p]
            activePen = pen
            annotations.append(pen)
            return true
        case .arrow, .rect, .line, .oval, .highlight:
            let kind: ShapeAnnotation.Kind
            switch tool {
            case .arrow: kind = .arrow
            case .rect: kind = .rect
            case .line: kind = .line
            case .oval: kind = .oval
            case .highlight: kind = .highlight
            default: preconditionFailure("unreachable shape tool")
            }
            let shape = ShapeAnnotation(
                kind: kind,
                start: p, end: p, uiScale: pixelScale)
            shape.color = color
            activeShape = shape
            annotations.append(shape)
            return true
        case .counter:
            let counter = CounterAnnotation(uiScale: pixelScale)
            counter.center = p
            counter.number = (annotations.compactMap {
                ($0 as? CounterAnnotation)?.number
            }.max() ?? 0) + 1
            counter.color = color
            annotations.append(counter)
            return true
        case .blur:
            let blur = BlurAnnotation(uiScale: pixelScale)
            blur.rect = CGRect(origin: p, size: .zero)
            activeBlur = blur
            activeBlurAnchor = p
            annotations.append(blur)
            return true
        case .text:
            // text placement is click-driven; the host creates the field
            return false
        }
    }

    func continueDrag(toPixel p: CGPoint) {
        if let pen = activePen {
            pen.points.append(p)
        } else if let shape = activeShape {
            shape.end = p
        } else if let blur = activeBlur, let anchor = activeBlurAnchor {
            blur.rect = CGRect(
                x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                width: abs(anchor.x - p.x), height: abs(anchor.y - p.y))
        }
    }

    func endDrag() {
        if let blur = activeBlur,
           (blur.rect.width <= 1 || blur.rect.height <= 1),
           annotations.last === blur {
            annotations.removeLast()
        }
        activeShape = nil
        activePen = nil
        activeBlur = nil
        activeBlurAnchor = nil
    }

    func addText(_ string: String, atPixel p: CGPoint) {
        guard !string.isEmpty else { return }
        let annotation = TextAnnotation(uiScale: pixelScale)
        annotation.text = string
        annotation.origin = p
        annotation.color = color
        annotations.append(annotation)
    }

    /// Undo removes the newest annotation (V1 scope: annotation-only stack).
    @discardableResult
    func undo() -> Bool {
        guard !annotations.isEmpty else { return false }
        annotations.removeLast()
        activeShape = nil
        activePen = nil
        activeBlur = nil
        activeBlurAnchor = nil
        return true
    }

    // MARK: rendering

    /// Draws the annotations for on-screen preview into a context whose
    /// transform already maps image pixels to the destination.
    @discardableResult
    func drawForPreview(in ctx: CGContext, base: CGImage) -> Bool {
        drawAnnotations(
            in: ctx, base: base,
            visiblePixels: CGRect(
                x: 0, y: 0, width: base.width, height: base.height))
    }

    /// Shared preview/export renderer. Pixelation asks Core Image only for
    /// the intersecting region; it never materializes a second full stitch.
    private func drawAnnotations(
        in ctx: CGContext, base: CGImage, visiblePixels: CGRect
    ) -> Bool {
        let baseBounds = CGRect(
            x: 0, y: 0, width: base.width, height: base.height)
        var renderedAll = true
        for annotation in annotations {
            guard let blur = annotation as? BlurAnnotation else {
                annotation.draw(in: ctx, pixellated: nil)
                continue
            }
            let requested = blur.rect.standardized
                .intersection(visiblePixels)
                .intersection(baseBounds)
            guard requested.width > 1, requested.height > 1 else { continue }
            let region = requested.integral.intersection(baseBounds)
            guard !forceRegionalPixelateFailureForTesting else {
                renderedAll = false
                continue
            }
            guard let pixelated = AnnotationRenderer.pixellateRegion(
                base, rect: region, scale: pixelScale)
            else {
                renderedAll = false
                continue
            }
            ctx.saveGState()
            ctx.clip(to: blur.rect)
            ctx.draw(pixelated, in: region)
            ctx.restoreGState()
        }
        return renderedAll
    }

    /// Allocation spy for the export path: exactly ONE full-size destination
    /// buffer per flatten, never an intermediate materialized crop.
    nonisolated(unsafe) static var flattenAllocationsForTesting = 0
    /// S2 fail-first hooks: production does not write these until regional
    /// pixelation exists.  Tests use them to reject a hidden full-image cache.
    nonisolated(unsafe) static var regionalPixelateAllocationsForTesting = 0
    nonisolated(unsafe) static var lastRegionalPixelateRectForTesting: CGRect?
    nonisolated(unsafe) static var lastRegionalPixelateBaseSizeForTesting: CGSize?
    /// Test hook: simulates destination-allocation failure.
    var forceRenderFailureForTesting = false
    /// Test hook: regional pixelation must fail closed during export.
    var forceRegionalPixelateFailureForTesting = false

    /// Inserts the editor's existing BlurAnnotation model so the S2 RED gate
    /// can exercise rendering/allocation before the toolbar routes the tool.
    func addBlurForTesting(rect: CGRect) {
        let blur = BlurAnnotation(uiScale: pixelScale)
        blur.rect = rect
        annotations.append(blur)
    }

    /// Flattened export: ONE destination buffer in the base's own colour
    /// space (P3 stays P3); the source crop is drawn straight into it and
    /// the annotations render translated so their ABSOLUTE positions stay
    /// put — anything outside the crop is clipped, never dragged along.
    ///
    /// FAIL-CLOSED: with annotations present, an allocation/render failure
    /// returns nil. Callers must keep their surface open and tell the user —
    /// silently exporting the un-annotated image would lose their drawings.
    func flattened(base: CGImage, cropPixels: CGRect) -> CGImage? {
        let crop = cropPixels.integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        guard !annotations.isEmpty else {
            // no drawings: a plain (shared-storage) crop materialized once
            return base.cropping(to: crop)?.materialized()
        }
        let width = Int(crop.width)
        let height = Int(crop.height)
        let space = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        Self.flattenAllocationsForTesting += 1
        guard !forceRenderFailureForTesting,
              let sourceCrop = base.cropping(to: crop), // descriptor, no copy
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(sourceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Annotation coords are BOTTOM-left-origin image pixels (the editor
        // renderer draws them into an unflipped CGContext); the crop rect is
        // TOP-left (CGImage.cropping). Shift accordingly.
        ctx.translateBy(
            x: -crop.minX,
            y: -(CGFloat(base.height) - crop.maxY))
        let visibleBL = CGRect(
            x: crop.minX,
            y: CGFloat(base.height) - crop.maxY,
            width: crop.width, height: crop.height)
        guard drawAnnotations(
            in: ctx, base: base, visiblePixels: visibleBL)
        else { return nil }
        return ctx.makeImage()
    }
}
