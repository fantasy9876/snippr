import AppKit

/// V1 in-place annotation tools (plan P1): a deliberate subset of the editor.
enum OverlayAnnotationTool: CaseIterable {
    case select
    case pen
    case arrow
    case rect
    case text
    case line
    case oval
    case highlight
    case counter

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
    private(set) var annotations: [Annotation] = []
    var tool: OverlayAnnotationTool = .select
    var color: NSColor = .systemRed
    /// Converts point-based stroke widths to pixels (the base image's scale).
    let pixelScale: CGFloat

    private var activeShape: ShapeAnnotation?
    private var activePen: PenAnnotation?

    init(pixelScale: CGFloat) {
        self.pixelScale = max(1, pixelScale)
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
        }
    }

    func endDrag() {
        activeShape = nil
        activePen = nil
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
        return true
    }

    // MARK: rendering

    /// Draws the annotations for on-screen preview into a context whose
    /// transform already maps image pixels to the destination.
    func drawForPreview(in ctx: CGContext) {
        for annotation in annotations {
            annotation.draw(in: ctx, pixellated: nil)
        }
    }

    /// Allocation spy for the export path: exactly ONE full-size destination
    /// buffer per flatten, never an intermediate materialized crop.
    nonisolated(unsafe) static var flattenAllocationsForTesting = 0
    /// Test hook: simulates destination-allocation failure.
    var forceRenderFailureForTesting = false

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
        for annotation in annotations {
            annotation.draw(in: ctx, pixellated: nil)
        }
        return ctx.makeImage()
    }
}
