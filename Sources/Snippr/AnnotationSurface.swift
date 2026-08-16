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
    static let redoToolbarTag = 202

    var toolbarTag: Int {
        Self.toolbarTagBase + Self.allCases.firstIndex(of: self)!
    }

    static func tool(forToolbarTag tag: Int) -> Self? {
        let index = tag - toolbarTagBase
        guard allCases.indices.contains(index) else { return nil }
        return allCases[index]
    }

    /// S4 exposes the tools added by S1/S2 through the SAME mapping on both
    /// live surfaces. Pre-existing V/P/A/R/T tooltip shortcuts remain outside
    /// this slice; do not duplicate this switch in either host.
    static func tool(forShortcutKey key: String) -> Self? {
        switch key.lowercased() {
        case "l": return .line
        case "o": return .oval
        case "h": return .highlight
        case "n": return .counter
        case "b": return .blur
        default: return nil
        }
    }

    /// The editor's exact persisted raw value. Keep this explicit instead of
    /// deriving it from toolbar order/tooltip so both surfaces always share
    /// the canonical `toolWidth_<EditorTool.rawValue>` preference.
    var strokeWidthSettingsKey: String? {
        switch self {
        case .pen: return EditorTool.pen.rawValue
        case .arrow: return EditorTool.arrow.rawValue
        case .line: return EditorTool.line.rawValue
        case .rect: return EditorTool.rect.rawValue
        case .oval: return EditorTool.oval.rawValue
        case .highlight: return EditorTool.highlight.rawValue
        default: return nil
        }
    }

    /// Mirrors EditorCanvasView.isStrokeTool exactly: Highlighter is a filled
    /// region and therefore does not consume the width wheel gesture.
    var adjustsStrokeWidth: Bool {
        switch self {
        case .pen, .arrow, .line, .rect, .oval: return true
        default: return false
        }
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
final class AnnotationSurface: RedactionHost {
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
    private var strokeTrackpadAccum: CGFloat = 0
    private var redoAnnotations: [Annotation] = []
    /// Hosts install weak-owner callbacks so Undo/Redo enabled state follows
    /// real mutations regardless of whether they came from mouse or text.
    var historyDidChange: (() -> Void)?

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
    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !redoAnnotations.isEmpty }

    var adjustsStrokeWidth: Bool { tool.adjustsStrokeWidth }

    private func storedStrokeWidth(for tool: OverlayAnnotationTool) -> CGFloat {
        guard let key = tool.strokeWidthSettingsKey else { return 3 }
        return min(20, max(1, strokeWidthStore.read(key)))
    }

    /// Shared by both real hosts. A stroke tool consumes the gesture even
    /// while a precise trackpad delta is still below the editor's threshold,
    /// preventing the scroll panel from panning under a width adjustment.
    func adjustStrokeWidthForScroll(
        deltaY: CGFloat, precise: Bool
    ) -> (width: CGFloat, color: NSColor)? {
        guard tool.adjustsStrokeWidth,
              let key = tool.strokeWidthSettingsKey,
              deltaY != 0
        else {
            strokeTrackpadAccum = 0
            return nil
        }
        let step: CGFloat
        if precise {
            strokeTrackpadAccum += deltaY
            guard abs(strokeTrackpadAccum) >= 18 else { return nil }
            step = strokeTrackpadAccum > 0 ? 0.5 : -0.5
            strokeTrackpadAccum = 0
        } else {
            step = deltaY > 0 ? 0.5 : -0.5
        }
        let width = min(20, max(1, strokeWidthStore.read(key) + step))
        strokeWidthStore.write(width, key)
        return (width, color)
    }

    func resetStrokeScrollAccumulator() {
        strokeTrackpadAccum = 0
    }

    private func clearActiveDraft() {
        activeShape = nil
        activePen = nil
        activeBlur = nil
        activeBlurAnchor = nil
    }

    /// A real new annotation forks history. Redo itself deliberately does
    /// not use this helper because it must preserve the remaining redo stack.
    private func appendNewAnnotation(_ annotation: Annotation) {
        redoAnnotations.removeAll()
        annotations.append(annotation)
        historyDidChange?()
    }

    // MARK: drag lifecycle (image-pixel coordinates)

    /// Returns true when the surface consumed the drag start (tool != select).
    func beginDrag(atPixel p: CGPoint) -> Bool {
        switch tool {
        case .select:
            return false
        case .pen:
            let pen = PenAnnotation(uiScale: pixelScale)
            pen.color = color
            pen.strokeWidthPt = storedStrokeWidth(for: tool)
            pen.points = [p]
            activePen = pen
            appendNewAnnotation(pen)
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
            shape.strokeWidthPt = storedStrokeWidth(for: tool)
            activeShape = shape
            appendNewAnnotation(shape)
            return true
        case .counter:
            let counter = CounterAnnotation(uiScale: pixelScale)
            counter.center = p
            counter.number = (annotations.compactMap {
                ($0 as? CounterAnnotation)?.number
            }.max() ?? 0) + 1
            counter.color = color
            appendNewAnnotation(counter)
            return true
        case .blur:
            let blur = BlurAnnotation(uiScale: pixelScale)
            blur.rect = CGRect(origin: p, size: .zero)
            activeBlur = blur
            activeBlurAnchor = p
            // Pixelate needs a live preview while dragging, but a click-only
            // zero-area draft is not a mutation and must preserve redo. Clear
            // the redo branch only when endDrag confirms a real region.
            annotations.append(blur)
            historyDidChange?()
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
        if let blur = activeBlur, annotations.last === blur {
            if blur.rect.width <= 1 || blur.rect.height <= 1 {
                annotations.removeLast()
            } else {
                redoAnnotations.removeAll()
            }
            historyDidChange?()
        }
        clearActiveDraft()
    }

    func addText(_ string: String, atPixel p: CGPoint) {
        guard !string.isEmpty else { return }
        let annotation = TextAnnotation(uiScale: pixelScale)
        annotation.text = string
        annotation.origin = p
        annotation.color = color
        appendNewAnnotation(annotation)
    }

    /// Annotation-only two-stack history. The exact model object moves between
    /// stacks; no clone is needed because overlays do not edit old marks.
    /// Hosts install this so a finished OCR job repaints the right surface.
    var redactionDidChangeHandler: (() -> Void)?

    func redactionDidChange() { redactionDidChangeHandler?() }

    /// Gate visibility: a finished run must leave the registry empty.
    var redactionJobCountForTesting: Int { redactionJobs.count }

    /// Jobs owned by this surface, keyed by the annotation they answer.
    private var redactionJobs: [ObjectIdentifier: SliceBRedactionJob] = [:]

    func registerRedactionJob(
        _ job: SliceBRedactionJob, for annotation: Annotation
    ) {
        let id = ObjectIdentifier(annotation)
        redactionJobs[id] = job
        // Completion removes the entry itself: a finished job must not sit in
        // the map holding this surface alive.
        job.onComplete = { [weak self] finished in
            guard let self else { return }
            if self.redactionJobs[id] === finished {
                self.redactionJobs.removeValue(forKey: id)
            }
        }
    }

    /// Drop entries whose annotation has gone (undo stack cleared, surface
    /// dismissed) so the map cannot grow without bound.
    func sweepFinishedRedactionJobs() {
        let live = Set(
            (annotations + redoAnnotations).map { ObjectIdentifier($0) })
        for (id, job) in redactionJobs where !live.contains(id) {
            job.cancel()
            redactionJobs.removeValue(forKey: id)
        }
    }

    /// Undo/redo/dismiss/save-lock all supersede work in flight. Cancel the
    /// job AND invalidate the annotation, so a late result can neither mutate
    /// an object sitting on the redo stack nor leave it pending forever.
    func cancelRedactionJob(for annotation: Annotation) {
        if let job = redactionJobs.removeValue(forKey: ObjectIdentifier(annotation)) {
            job.cancel()
        }
        if let blur = annotation as? BlurAnnotation {
            blur.bumpRedactionGeneration()
        }
    }

    func cancelAllRedactionJobs() {
        for annotation in annotations + redoAnnotations {
            cancelRedactionJob(for: annotation)
        }
        sweepFinishedRedactionJobs()
        for (id, job) in redactionJobs {
            job.cancel()
            redactionJobs.removeValue(forKey: id)
        }
    }

    @discardableResult
    func undo() -> Bool {
        guard let annotation = annotations.popLast() else { return false }
        cancelRedactionJob(for: annotation)
        redoAnnotations.append(annotation)
        clearActiveDraft()
        historyDidChange?()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let annotation = redoAnnotations.popLast() else { return false }
        // Redo restores a NORMALIZED state: never an orphan pending mask.
        cancelRedactionJob(for: annotation)
        annotations.append(annotation)
        clearActiveDraft()
        historyDidChange?()
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
        // One renderer for every surface: phases, regional pixelation and the
        // opaque fail-closed cover all live in SliceBCompositor.
        guard !forceRegionalPixelateFailureForTesting else {
            let baseBounds = CGRect(
                x: 0, y: 0, width: base.width, height: base.height)
            for annotation in SliceBCompositor.phaseOrder(annotations) {
                guard let blur = annotation as? BlurAnnotation else {
                    annotation.draw(in: ctx, pixellated: nil)
                    continue
                }
                let masks = SliceBRedaction.maskRects(
                    state: blur.redactionState, rect: blur.rect)
                    .map {
                        $0.standardized.intersection(visiblePixels)
                            .intersection(baseBounds)
                    }
                    .filter { $0.width > 1 && $0.height > 1 }
                SliceBCompositor.drawFailedRedaction(masks, in: ctx)
            }
            return false
        }
        return SliceBCompositor.draw(
            annotations, in: ctx, base: base, visiblePixels: visiblePixels,
            pixelScale: pixelScale)
    }

    /// Allocation spy for the export path: exactly ONE full-size destination
    /// buffer per flatten, never an intermediate materialized crop.
    nonisolated(unsafe) static var flattenAllocationsForTesting = 0
    /// S2 fail-first hooks: production does not write these until regional
    /// pixelation exists.  Tests use them to reject a hidden full-image cache.
    nonisolated(unsafe) static var regionalPixelateAllocationsForTesting = 0
    nonisolated(unsafe) static var lastRegionalPixelateRectForTesting: CGRect?
    /// Every region Core Image was actually asked to materialize, so a gate can
    /// prove no allocation strayed outside the mask.
    nonisolated(unsafe) static var allRegionalPixelateRectsForTesting: [CGRect] = []
    nonisolated(unsafe) static var lastRegionalPixelateBaseSizeForTesting: CGSize?
    /// Test hook: simulates destination-allocation failure.
    var forceRenderFailureForTesting = false
    /// Test hook: regional pixelation must fail closed during export.
    var forceRegionalPixelateFailureForTesting = false

    /// Slice B seam: lets a gate seed any annotation model (a text-mode
    /// redaction, a spotlight) through the real history path before the
    /// toolbar routes the tool.
    func addAnnotationForTesting(_ annotation: Annotation) {
        appendNewAnnotation(annotation)
    }

    /// Inserts the editor's existing BlurAnnotation model so the S2 RED gate
    /// can exercise rendering/allocation before the toolbar routes the tool.
    func addBlurForTesting(rect: CGRect) {
        let blur = BlurAnnotation(uiScale: pixelScale)
        blur.rect = rect
        appendNewAnnotation(blur)
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
