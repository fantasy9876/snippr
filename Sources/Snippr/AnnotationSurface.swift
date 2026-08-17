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
    // Appended at the END so the legacy tags 100-109 keep their meaning.
    case spotlight
    case pixelateText
    // Appended after pixelateText so tags 100-111 keep their meaning; this
    // one is 112.
    case magnifier

    /// The tools each host offers. Area Review gained the magnifier; the
    /// scroll panel keeps exactly what it had, so a catalog per host is what
    /// decides the toolbar rather than `allCases`.
    static let areaReviewTools: [Self] = allCases
    static let panelTools: [Self] = allCases.filter { $0 != .magnifier }

    static let toolbarTagBase = 100
    static let colorToolbarTag = 200
    static let undoToolbarTag = 201
    static let redoToolbarTag = 202
    /// Backdrop is a document STYLE, not a drawing tool: it gets a toolbar tag
    /// but deliberately no case in this enum, so choosing it never displaces
    /// the active tool and never becomes a drag.
    static let backdropToolbarTag = 203

    var toolbarTag: Int {
        Self.toolbarTagBase + Self.allCases.firstIndex(of: self)!
    }

    static func tool(forToolbarTag tag: Int) -> Self? {
        let index = tag - toolbarTagBase
        guard allCases.indices.contains(index) else { return nil }
        return allCases[index]
    }

    /// S4 exposes the tools added by S1/S2 through the SAME mapping on both
    /// live surfaces; do not duplicate this switch in either host.
    /// V/P/A/R/T are here because the toolbar has always ADVERTISED them in
    /// its tooltips — a hint that names a key the host does not route is a
    /// promise the app breaks the first time a user believes it.
    static func tool(forShortcutKey key: String) -> Self? {
        switch key.lowercased() {
        case "v": return .select
        case "p": return .pen
        case "a": return .arrow
        case "r": return .rect
        case "t": return .text
        case "l": return .line
        case "o": return .oval
        case "h": return .highlight
        case "n": return .counter
        case "b": return .blur
        case "s": return .spotlight
        case "m": return .magnifier
        default: return nil
        }
    }

    /// The host-filtered lookup, which is the ONLY one a live surface may use.
    /// The map above is catalog-wide, so the panel — which deliberately omits
    /// the magnifier — would otherwise select a tool it shows no button for
    /// and leave the toolbar highlighting nothing.
    static func tool(forShortcutKey key: String, in catalog: [Self]) -> Self? {
        guard let tool = tool(forShortcutKey: key), catalog.contains(tool)
        else { return nil }
        return tool
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
        default: return false  // spotlight/pixelate cover regions, not strokes
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
        case .spotlight: return "rectangle.center.inset.filled"
        case .pixelateText: return "text.redaction"
        case .magnifier: return "plus.magnifyingglass"
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
        case .spotlight: return "Spotlight (S)"
        case .pixelateText:
            return "Pixelate text (⇧B) — best-effort, review before sharing"
        case .magnifier: return "Magnifier (M)"
        }
    }
}

/// The view that owns an `AnnotationSurface` and repaints it when a redaction
/// resolves. Weak by construction on the surface side.
@MainActor
protocol RedactionSurfaceDelegate: AnyObject {
    func surfaceNeedsRedactionRepaint()
}

/// Annotation state + input handling shared by BOTH in-place surfaces (the
/// area-review overlay and the scroll-result panel). Coordinates live in the
/// BASE image's pixel space — absolutely positioned, so a crop move/resize
/// never drags drawings along; flatten clips them against the crop
/// (QA invariant 24). Reuses the editor's `Annotation` model and renderer so
/// the two surfaces cannot drift.
@MainActor
final class AnnotationSurface: RedactionHost, RedactionJobObserver {
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
    private var activeSpotlight: SpotlightAnnotation?
    private var activeSpotlightAnchor: CGPoint?
    private var activeMagnifier: MagnifierAnnotation?
    private var activeMagnifierAnchor: CGPoint?
    /// True between `beginDrag` and `endDrag`. A draft is already IN the
    /// document at this point and the transaction that will finalize it is
    /// half-built, so every route that mutates history, tools or the document
    /// has to stand aside until the drag resolves.
    var isDragging: Bool {
        activeShape != nil || activePen != nil || activeBlur != nil
            || activeSpotlight != nil || activeMagnifier != nil
    }

    /// The spotlight a drag is about to replace, held so a click can put it
    /// back and so undo can restore it.
    private var replacedSpotlight: (spot: SpotlightAnnotation, index: Int)?
    /// Replacement records hold STRONG references and are matched with `===`.
    /// An ObjectIdentifier key alone can be reused by a later allocation, so a
    /// new spotlight could inherit a stale prior. Records are pruned whenever
    /// the redo branch is dropped.
    private struct SpotlightReplacement {
        let new: SpotlightAnnotation
        let prior: SpotlightAnnotation
        let priorIndex: Int
    }
    private var spotlightReplacements: [SpotlightReplacement] = []
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
    var redoAnnotationsForTesting: [Annotation] { redoAnnotations }

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
        activeSpotlight = nil
        activeSpotlightAnchor = nil
        activeMagnifier = nil
        activeMagnifierAnchor = nil
    }

    /// A real new annotation forks history. Redo itself deliberately does
    /// not use this helper because it must preserve the remaining redo stack.
    private func appendNewAnnotation(_ annotation: Annotation) {
        redoAnnotations.removeAll()
        // Forking the branch with ANY mark abandons the redo spotlights, so
        // their replacement records must go too or they keep strong references
        // to history nobody can reach.
        pruneSpotlightReplacements()
        annotations.append(annotation)
        historyDidChange?()
    }

    // MARK: drag lifecycle (image-pixel coordinates)

    /// Returns true when the surface consumed the drag start (tool != select).
    func beginDrag(atPixel p: CGPoint) -> Bool {
        switch tool {
        case .select:
            return false
        case .spotlight:
            let spot = SpotlightAnnotation(uiScale: pixelScale)
            spot.rect = CGRect(origin: p, size: .zero)
            spot.baseBounds = redactionBaseBounds
            activeSpotlight = spot
            activeSpotlightAnchor = p
            // v1 is a singleton, so the preview must show ONE candidate: take
            // the existing spotlight out for the duration of the drag and put
            // it back if the drag turns out to be a click.
            if let existing = annotations.compactMap({
                $0 as? SpotlightAnnotation
            }).last,
               let index = annotations.firstIndex(where: { $0 === existing }) {
                // Keep the ORIGINAL position: removing and appending would
                // reorder it after marks drawn later and break chronological
                // undo.
                replacedSpotlight = (existing, index)
                annotations.remove(at: index)
            }
            annotations.append(spot)
            historyDidChange?()
            return true
        case .magnifier:
            // The callout is placed by the same drag that picks the source, so
            // the draft carries both from the first pixel. The snapshot is
            // taken at the release, once the source rect is final — and it is
            // taken from the REDACTED document, never the raw base.
            let magnifier = MagnifierAnnotation(uiScale: pixelScale)
            magnifier.sourceRect = CGRect(origin: p, size: .zero)
            magnifier.calloutRect = CGRect(origin: p, size: .zero)
            activeMagnifier = magnifier
            activeMagnifierAnchor = p
            annotations.append(magnifier)
            historyDidChange?()
            return true
        case .pixelateText:
            // Text mode starts as a FULL mask and only ever narrows once a
            // live OCR result lands, so the preview covers from the first
            // pixel of the drag.
            let blur = BlurAnnotation(uiScale: pixelScale)
            blur.rect = CGRect(origin: p, size: .zero)
            blur.redactionState = .pendingFull
            activeBlur = blur
            activeBlurAnchor = p
            clearAllMagnifierSnapshots()
            annotations.append(blur)
            historyDidChange?()
            return true
        case .pen:
            let pen = PenAnnotation(uiScale: pixelScale)
            pen.color = color
            pen.strokeWidthPt = storedStrokeWidth(for: tool)
            pen.points = [p]
            activePen = pen
            // Appended WITHOUT forking history yet, like the blur and the
            // spotlight: a drag that is abandoned — Esc, or a terminal action
            // freezing the document — must leave the redo branch exactly as it
            // found it. endDrag forks once the stroke is real.
            annotations.append(pen)
            historyDidChange?()
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
            annotations.append(shape)
            historyDidChange?()
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
            clearAllMagnifierSnapshots()
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
            clearMagnifierSnapshots(overlapping: blur.rect)
        } else if let spot = activeSpotlight, let anchor = activeSpotlightAnchor {
            spot.rect = CGRect(
                x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                width: abs(anchor.x - p.x), height: abs(anchor.y - p.y))
        } else if let magnifier = activeMagnifier,
                  let anchor = activeMagnifierAnchor {
            let source = CGRect(
                x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                width: abs(anchor.x - p.x), height: abs(anchor.y - p.y))
            magnifier.sourceRect = source
            // The callout sits beside the source at the editor's default
            // magnification, so a drag produces something visible without a
            // second gesture.
            magnifier.calloutRect = CGRect(
                x: source.maxX + 16, y: source.minY,
                width: source.width * 2, height: source.height * 2)
        }
    }

    /// Drops an in-progress draft and restores whatever it displaced, without
    /// touching history. Used when a terminal action has already frozen the
    /// document underneath a live drag: finalizing then would add a mark the
    /// export never saw.
    func abandonDrag() {
        let touchedRedactions = activeBlur != nil
        if let shape = activeShape, annotations.last === shape {
            annotations.removeLast()
        }
        if let pen = activePen, annotations.last === pen {
            annotations.removeLast()
        }
        if let blur = activeBlur, annotations.last === blur {
            annotations.removeLast()
        }
        if let magnifier = activeMagnifier, annotations.last === magnifier {
            annotations.removeLast()
        }
        if let spot = activeSpotlight, annotations.last === spot {
            annotations.removeLast()
            if let previous = replacedSpotlight {
                let index = min(previous.index, annotations.count)
                annotations.insert(previous.spot, at: index)
            }
        }
        activeShape = nil
        activePen = nil
        activeBlur = nil
        activeBlurAnchor = nil
        activeSpotlight = nil
        activeSpotlightAnchor = nil
        activeMagnifier = nil
        activeMagnifierAnchor = nil
        replacedSpotlight = nil
        // A pixelation dropped mid-drag may have blanked a magnifier patch on
        // the way; rebuild against what is left so nothing stays empty.
        if touchedRedactions { refreshMagnifierSnapshots() }
        // The document changed shape even though history did not, so the Undo
        // and Redo buttons have to be re-evaluated.
        historyDidChange?()
    }

    /// Below this the pointer did not move; it exists for floating-point
    /// noise, not as a minimum visible size.
    static let motionTolerance: CGFloat = 0.01

    static func hasMotion(_ points: [CGPoint]) -> Bool {
        guard let first = points.first else { return false }
        return points.contains {
            abs($0.x - first.x) > motionTolerance
                || abs($0.y - first.y) > motionTolerance
        }
    }

    func endDrag() {
        // Whether this drag could have changed what the magnifiers see. Read
        // BEFORE the branches, because `clearActiveDraft` erases the evidence.
        let touchedRedactions = activeBlur != nil
        // A magnifier is finished like the other region tools: a drag that
        // never moved leaves nothing behind and keeps the redo branch. The
        // snapshot is left to the host, which owns the base image and can take
        // it from the REDACTED document — the surface must never hand back raw
        // pixels a redaction was meant to cover.
        if let magnifier = activeMagnifier, annotations.last === magnifier {
            if magnifier.sourceRect.width <= 1
                || magnifier.sourceRect.height <= 1 {
                annotations.removeLast()
            } else {
                redoAnnotations.removeAll()
                pruneSpotlightReplacements()
                pendingMagnifier = magnifier
            }
            historyDidChange?()
        }
        // A completed pen stroke or shape forks history HERE, not at
        // mouseDown — and only if it is a real mark. A press-and-release with
        // no movement leaves a single-point stroke or a zero-size shape that
        // draws nothing; keeping it would put an invisible annotation in the
        // document and take the user's redo branch with it.
        if let pen = activePen, annotations.last === pen {
            // MOTION, not sample count: a press that delivers the same point
            // twice has two samples and no extent. The rule is the input
            // policy — did the pointer move at all — with a tolerance that
            // exists for floating-point noise, not as a minimum visible size.
            if Self.hasMotion(pen.points) {
                redoAnnotations.removeAll()
                pruneSpotlightReplacements()
            } else {
                annotations.removeLast()
            }
            historyDidChange?()
        }
        if let shape = activeShape, annotations.last === shape {
            let dx = abs(shape.end.x - shape.start.x)
            let dy = abs(shape.end.y - shape.start.y)
            // INPUT policy first: a press that never moved creates no mark.
            // (Not a rendering claim — a zero-length arrow would still draw a
            // head, because drawArrow floors its length at 1.)
            //
            // On top of that, one rendering fact: the highlighter FILLS its
            // bounds, so a drag along a single axis has zero area and paints
            // nothing at all. The stroked kinds do paint from single-axis
            // motion — a flat rectangle strokes as a line — so for them any
            // motion is enough.
            let isReal: Bool
            switch shape.kind {
            case .highlight:
                isReal = dx > Self.motionTolerance && dy > Self.motionTolerance
            case .line, .arrow, .rect, .oval:
                isReal = max(dx, dy) > Self.motionTolerance
            }
            if isReal {
                redoAnnotations.removeAll()
                pruneSpotlightReplacements()
            } else {
                annotations.removeLast()
            }
            historyDidChange?()
        }
        if let blur = activeBlur, annotations.last === blur {
            if blur.rect.width <= 1 || blur.rect.height <= 1 {
                annotations.removeLast()
            } else {
                redoAnnotations.removeAll()
                pruneSpotlightReplacements()
                // Exactly one enqueue per completed text redaction; the host
                // starts it because only the host holds the base image.
                if blur.redactionState == .pendingFull {
                    pendingTextRedaction = blur
                }
            }
            historyDidChange?()
        }
        if let spot = activeSpotlight, annotations.last === spot {
            if spot.rect.width <= 1 || spot.rect.height <= 1 {
                // A click is not a mutation: put the previous spotlight back
                // and leave the redo branch alone.
                annotations.removeLast()
                if let previous = replacedSpotlight {
                    let index = min(previous.index, annotations.count)
                    annotations.insert(previous.spot, at: index)
                }
            } else {
                // ONE transaction: undo pops this spotlight and restores the
                // one it replaced, rather than leaving none behind.
                // Drop any stale record for this object first, then record the
                // replacement only when there really was one.
                spotlightReplacements.removeAll { $0.new === spot }
                if let replaced = replacedSpotlight {
                    spotlightReplacements.append(SpotlightReplacement(
                        new: spot, prior: replaced.spot,
                        priorIndex: replaced.index))
                }
                redoAnnotations.removeAll()
                pruneSpotlightReplacements()
            }
            replacedSpotlight = nil
            historyDidChange?()
        }
        clearActiveDraft()
        // A pixelation that was committed — or one that was discarded after
        // sweeping across a source mid-drag — both leave the patches needing a
        // resample against the set that actually survived.
        if touchedRedactions { redactionDidChange() }
    }

    /// Adjusting darkness is a REPLACEMENT, not an in-place mutation: it goes
    /// through the same prior+index machinery as drawing a new spotlight, so
    /// undo restores the previous darkness and position exactly once.
    /// Returns false when there is nothing to change.
    @discardableResult
    func setSpotlightDim(_ fraction: CGFloat) -> Bool {
        // Not during a drag. The draft spotlight is the last one in the array,
        // so this would clone the DRAFT and replace it while `activeSpotlight`
        // still points at the object just detached — `endDrag` would then find
        // its identity check failing and skip finalization entirely, losing
        // the spotlight this was meant to adjust and stranding the prior one.
        guard !isDragging else { return false }
        let clamped = max(0.1, min(0.9, fraction))
        guard let current = annotations.compactMap({
            $0 as? SpotlightAnnotation
        }).last,
              let index = annotations.firstIndex(where: { $0 === current })
        else { return false }
        guard abs(current.dimFraction - clamped) > 0.0001 else { return false }
        guard let clone = current.copyAnnotation() as? SpotlightAnnotation
        else { return false }
        clone.dimFraction = clamped
        annotations.remove(at: index)
        annotations.append(clone)
        spotlightReplacements.removeAll { $0.new === clone }
        spotlightReplacements.append(SpotlightReplacement(
            new: clone, prior: current, priorIndex: index))
        redoAnnotations.removeAll()
        pruneSpotlightReplacements()
        historyDidChange?()
        redactionDidChange()
        return true
    }

    /// A record is only meaningful while its spotlight can still be reached by
    /// undo or redo; anything else is abandoned history.
    private func pruneSpotlightReplacements() {
        // Keep the whole TRANSITIVE chain. With S0 -> S1 -> S2, the record for
        // S1 -> S0 must survive even though S1 is now only a prior: dropping it
        // makes the second undo delete the spotlight instead of restoring S0.
        var reachable: [SpotlightAnnotation] = (annotations + redoAnnotations)
            .compactMap { $0 as? SpotlightAnnotation }
        var kept: [SpotlightReplacement] = []
        var changed = true
        while changed {
            changed = false
            for record in spotlightReplacements
            where !kept.contains(where: { $0.new === record.new })
                && reachable.contains(where: { $0 === record.new }) {
                kept.append(record)
                if !reachable.contains(where: { $0 === record.prior }) {
                    reachable.append(record.prior)
                }
                changed = true
            }
        }
        spotlightReplacements = kept
    }

    /// Full SOURCE pixel bounds; hosts set this so a spotlight dims the whole
    /// image, not just the selection or the view.
    var redactionBaseBounds: CGRect = .zero

    /// The frame the document currently wears: the LAST preset chosen, read
    /// straight out of history so undo and redo need no separate bookkeeping.
    var backdropPreset: BackdropPreset {
        annotations.compactMap { ($0 as? BackdropAnnotation)?.preset }.last
            ?? .none
    }

    /// Choosing a preset is an edit and joins the same timeline as the marks.
    /// Choosing the one already on is not an edit and must not touch history.
    /// Returns false when nothing changed.
    @discardableResult
    func applyBackdrop(_ preset: BackdropPreset) -> Bool {
        guard !isDragging else { return false }
        guard preset != backdropPreset else { return false }
        appendNewAnnotation(BackdropAnnotation(
            preset: preset, uiScale: pixelScale))
        return true
    }

    /// The image the surface samples from. Hosts set it beside
    /// `redactionBaseBounds`: a magnifier patch is sanitized ONCE, when the
    /// callout is made, so every later change to the redaction set has to
    /// resample it — and only this reference makes that possible without the
    /// host being present at the moment of the change (an OCR job resolving
    /// asynchronously is exactly such a moment).
    var redactionBaseImage: CGImage?

    /// Set by `endDrag` when a magnifier finished; the host fills its snapshot
    /// because only the host has the base image — and it must sample the
    /// document AFTER redactions so the callout cannot reveal what a
    /// pixelation covers.
    private(set) var pendingMagnifier: MagnifierAnnotation?

    @discardableResult
    func fillPendingMagnifier(base: CGImage) -> Bool {
        guard let magnifier = pendingMagnifier else { return false }
        pendingMagnifier = nil
        if redactionBaseImage == nil { redactionBaseImage = base }
        magnifier.snapshot = SliceBCompositor.magnifierSnapshot(
            base: base, sourceRect: magnifier.sourceRect,
            redactions: liveRedactions)
        redactionDidChange()
        return true
    }

    /// Every redaction currently covering pixels, INCLUDING the one being
    /// drawn right now: a rebuild that saw only committed marks would restore
    /// raw pixels underneath an active pixelation.
    private var liveRedactions: [BlurAnnotation] {
        var result = annotations.compactMap { $0 as? BlurAnnotation }
        if let draft = activeBlur, !result.contains(where: { $0 === draft }) {
            result.append(draft)
        }
        return result
    }

    /// Resample every magnifier from the CURRENT redactions.
    ///
    /// The patch is sanitized once, at creation. Anything that changes the
    /// redaction set afterwards — a pixelation drawn over the source, an undo
    /// that removes one, a redo that brings one back, or a text-redaction job
    /// resolving off the main thread — leaves the callout showing pixels the
    /// document itself no longer shows. That is a privacy leak, not a stale
    /// pixel: the user covered something and the magnifier still displays it.
    /// With no base image to resample from, the patch is CLEARED — a blank
    /// callout is a defect, a stale one is a disclosure.
    @discardableResult
    func refreshMagnifierSnapshots() -> Bool {
        let magnifiers = annotations.compactMap { $0 as? MagnifierAnnotation }
        guard !magnifiers.isEmpty else { return false }
        let redactions = liveRedactions
        for magnifier in magnifiers {
            guard let base = redactionBaseImage else {
                magnifier.snapshot = nil
                continue
            }
            magnifier.snapshot = SliceBCompositor.magnifierSnapshot(
                base: base, sourceRect: magnifier.sourceRect,
                redactions: redactions)
        }
        return true
    }

    /// EVERY patch goes blank the moment a redaction drag starts, wherever it
    /// started.
    ///
    /// Not just the one under the press: a zero-size draft is not a valid mask
    /// rect, and both fail-closed paths react to that globally — the document
    /// renderer covers the whole visible area rather than guess where to mask
    /// (`SliceBCompositor.draw`), and `magnifierSnapshot` refuses to sample at
    /// all while any redaction rect is undefined. So between mouse-down and
    /// the first dragged event the document is fully masked while a callout
    /// anywhere on it would still be painting its old pixels on top. Blank
    /// them all; `endDrag`/`abandonDrag` rebuild.
    private func clearAllMagnifierSnapshots() {
        for magnifier in annotations.compactMap({ $0 as? MagnifierAnnotation }) {
            magnifier.snapshot = nil
        }
    }

    /// Mid-drag fail-closed: the instant a pixelation being drawn touches a
    /// magnifier's source, drop that patch. Resampling on every mouse-moved
    /// event would be far too expensive, and showing the old pixels WHILE the
    /// user is covering them is precisely the leak this exists to prevent.
    /// `endDrag`/`abandonDrag` rebuild, so the callout is never left blank.
    private func clearMagnifierSnapshots(overlapping rect: CGRect) {
        for magnifier in annotations.compactMap({ $0 as? MagnifierAnnotation })
        where magnifier.snapshot != nil
            && magnifier.sourceRect.intersects(rect) {
            magnifier.snapshot = nil
        }
    }

    /// Set by `endDrag` when a text redaction finished; the host starts the
    /// bounded OCR because only the host has the base image.
    private(set) var pendingTextRedaction: BlurAnnotation?

    @discardableResult
    func startPendingTextRedaction(base: CGImage) -> Bool {
        guard let blur = pendingTextRedaction else { return false }
        pendingTextRedaction = nil
        // start() already sets the full mask and notifies when it refuses, so
        // repeating it here would repaint twice.
        guard let job = SliceBRedactionJob.start(
            blur: blur, base: base, host: self)
        else { return false }
        registerRedactionJob(job, for: blur)
        return true
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
    /// The view hosting this surface. Weak delegate rather than a closure so
    /// no caller can accidentally retain the host through a repaint callback.
    weak var redactionDelegate: RedactionSurfaceDelegate?

    /// The single funnel for "the redaction set is not what it was". Every
    /// magnifier is resampled BEFORE the repaint, so no frame can ever be
    /// drawn from a patch that predates the change.
    func redactionDidChange() {
        refreshMagnifierSnapshots()
        redactionDelegate?.surfaceNeedsRedactionRepaint()
    }

    /// A job reached a terminal state: drop its registry entry.
    func redactionJobDidFinish(_ job: SliceBRedactionJob) {
        for (id, registered) in redactionJobs where registered === job {
            redactionJobs.removeValue(forKey: id)
        }
    }

    /// Gate visibility: a finished run must leave the registry empty.
    var redactionJobCountForTesting: Int { redactionJobs.count }

    /// Jobs owned by this surface, keyed by the annotation they answer.
    private var redactionJobs: [ObjectIdentifier: SliceBRedactionJob] = [:]

    func registerRedactionJob(
        _ job: SliceBRedactionJob, for annotation: Annotation
    ) {
        redactionJobs[ObjectIdentifier(annotation)] = job
        // Completion removes the entry itself: a finished job must not sit in
        // the map holding this surface alive.
        job.setCompletionObserver(self)
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
        // A spotlight that replaced another undoes to that other one, so the
        // single action reverses as a single action.
        if let spot = annotation as? SpotlightAnnotation,
           let replaced = spotlightReplacements.last(where: { $0.new === spot }) {
            annotations.insert(
                replaced.prior, at: min(replaced.priorIndex, annotations.count))
        }
        redoAnnotations.append(annotation)
        clearActiveDraft()
        // Undoing a pixelation UNCOVERS pixels a magnifier sampled while they
        // were covered, and undoing anything else can still change which
        // redactions apply. Resample before the repaint either way.
        refreshMagnifierSnapshots()
        historyDidChange?()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let annotation = redoAnnotations.popLast() else { return false }
        // Redo restores a NORMALIZED state: never an orphan pending mask.
        cancelRedactionJob(for: annotation)
        if let spot = annotation as? SpotlightAnnotation,
           let replaced = spotlightReplacements.last(where: { $0.new === spot }) {
            annotations.removeAll { $0 === replaced.prior }
        }
        annotations.append(annotation)
        clearActiveDraft()
        // Redo brings a pixelation BACK: a callout sampled while it was undone
        // is showing exactly the pixels it now covers.
        refreshMagnifierSnapshots()
        historyDidChange?()
        return true
    }

    // MARK: rendering

    /// Draws the annotations for on-screen preview into a context whose
    /// transform already maps image pixels to the destination.
    @discardableResult
    /// `visiblePixels` is what the export will actually contain. The host
    /// passes its live crop so the preview answers the same question the
    /// export does — most importantly for the magnifier, whose source must be
    /// wholly inside the crop to be drawn at all.
    func drawForPreview(
        in ctx: CGContext, base: CGImage, visiblePixels: CGRect? = nil
    ) -> Bool {
        drawAnnotations(
            in: ctx, base: base,
            visiblePixels: visiblePixels ?? CGRect(
                x: 0, y: 0, width: base.width, height: base.height))
    }

    /// Shared preview/export renderer. Pixelation asks Core Image only for
    /// the intersecting region; it never materializes a second full stitch.
    private func drawAnnotations(
        in ctx: CGContext, base: CGImage, visiblePixels: CGRect,
        extra: [Annotation] = []
    ) -> Bool {
        // One renderer for every surface: phases, regional pixelation and the
        // opaque fail-closed cover all live in SliceBCompositor.
        return SliceBCompositor.draw(
            annotations + extra, in: ctx, base: base,
            visiblePixels: visiblePixels, pixelScale: pixelScale)
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
    /// Test hook kept for the S2 gates: it now drives the SHARED low-level
    /// seam, so preview and export take the same fail-closed path production
    /// would take if Core Image really failed.
    /// Read-only view of the shared token-owned scope. There is deliberately
    /// no setter: gates enter the scope with
    /// `AnnotationRenderer.withForcedRegionalFailure { }`.
    var forceRegionalPixelateFailureForTesting: Bool {
        AnnotationRenderer.forceRegionalPixelateFailureForTesting
    }

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
    /// One crop, materialized straight into the destination space — the same
    /// single allocation the plain path makes, not an extra pass.
    ///
    /// It allocates a destination and can fail, so it books itself exactly
    /// like `flattened` does: counted before the attempt, honouring the forced
    /// failure, recorded in the trace. Otherwise a route that produces a real
    /// buffer would be invisible to the allocation budget and immune to the
    /// fail-closed gates — the accounting would say "no destination" while a
    /// full-size one was being built.
    private func convertedCrop(
        base: CGImage, crop: CGRect, space: CGColorSpace
    ) -> CGImage? {
        let width = Int(crop.width), height = Int(crop.height)
        Self.flattenAllocationsForTesting += 1
        guard !forceRenderFailureForTesting,
              let sourceCrop = base.cropping(to: crop),
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(sourceCrop, in: CGRect(
            x: 0, y: 0, width: width, height: height))
        RenderTrace.record(
            kind: "destination", destination: "\(width)x\(height)", rect: crop)
        return ctx.makeImage()
    }

    /// `extra` renders as if it were appended to the document WITHOUT being
    /// appended: a terminal action flattens the text still being typed before
    /// deciding whether the export succeeded, so a failure leaves the field
    /// exactly as the user left it.
    func flattened(
        base: CGImage, cropPixels: CGRect, extra: [Annotation] = [],
        destinationSpace: CGColorSpace? = nil
    ) -> CGImage? {
        let crop = cropPixels.integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        guard !annotations.isEmpty || !extra.isEmpty else {
            // No drawings. Normally a plain (shared-storage) crop materialized
            // once — but when a destination space is demanded the pixels have
            // to be converted INTO it here, or the frame would be composed in
            // sRGB around an inner image that never left P3.
            guard let space = destinationSpace else {
                return base.cropping(to: crop)?.materialized()
            }
            return convertedCrop(base: base, crop: crop, space: space)
        }
        let width = Int(crop.width)
        let height = Int(crop.height)
        let space = destinationSpace
            ?? base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
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
        RenderTrace.record(
            kind: "destination", destination: "\(width)x\(height)", rect: crop)
        guard drawAnnotations(
            in: ctx, base: base, visiblePixels: visibleBL, extra: extra)
        else { return nil }
        return ctx.makeImage()
    }
}
