import AppKit
import Vision

/// Slice B compositor: redaction, spotlight lighting and magnifier patches.
///
/// Two invariants drive every shape here:
/// 1. A redaction never renders "nothing". Every unknown/incomplete state masks
///    the whole rect; only a non-empty word list narrows the mask, and any
///    failure downgrades TOWARDS more masking.
/// 2. Preview and export derive their pixels from the SAME entry point
///    (`SliceBCompositor.draw`), so the editor and both overlay surfaces
///    cannot drift.

// MARK: - Redaction state

/// The state of one pixelate annotation. `words` is only reachable through
/// `resolvedWords`, which maps an empty list to `fallbackFull` — `[]` must
/// never be spelled "reveal".
enum RedactionState: Equatable {
    /// Classic Shottr-style rectangle pixelate (today's `B`).
    case rect
    /// Text mode, OCR still running.
    case pendingFull
    /// Text mode, OCR failed / found nothing / low confidence / bad range.
    case fallbackFull
    /// Text mode, OCR returned word boxes.
    case words([CGRect])

    /// ALL-OR-NOTHING. Filtering the bad boxes out and keeping the good ones
    /// would leave exactly the words we failed to map readable, so a single
    /// invalid box collapses the whole result to the full mask.
    static func resolvedWords(_ rects: [CGRect]) -> RedactionState {
        guard !rects.isEmpty else { return .fallbackFull }
        for rect in rects where !rect.isValidMaskRect { return .fallbackFull }
        return .words(rects)
    }

    var isTextMode: Bool {
        switch self {
        case .rect: return false
        case .pendingFull, .fallbackFull, .words: return true
        }
    }
}

enum SliceBRedaction {
    /// The single source of clip rects for preview AND export, on all three
    /// surfaces. Never returns an empty array.
    static func maskRects(state: RedactionState, rect: CGRect) -> [CGRect] {
        switch state {
        case .rect, .pendingFull, .fallbackFull:
            return [rect]
        case let .words(words):
            // Same rule as `resolvedWords`: one bad box and everything goes
            // back to the full rect. Never mask "the valid subset". A box that
            // is not entirely inside the annotation is bad too — clipping it
            // would silently uncover whatever hangs outside.
            guard !words.isEmpty,
                  words.allSatisfy({ $0.isValidMaskRect }),
                  // STRICT: a box even a quarter pixel outside the annotation
                  // means the mapping drifted. Fail closed, do not trim.
                  words.allSatisfy({ rect.contains($0) })
            else { return [rect] }
            return words
        }
    }

    /// Async OCR landing. A result from a superseded generation (undo, delete,
    /// move, crop, resize, save-lock, close) is dropped, not applied.
    static func applyWords(
        _ words: [CGRect], to state: RedactionState,
        generation: Int, current: Int
    ) -> RedactionState {
        guard generation == current else { return state }
        return .resolvedWords(words)
    }

    /// Vision boxes hug the ink; anti-aliased edges need a small outset.
    static let wordOutset: CGFloat = 3
}

extension CGRect {
    /// A mask rect we are willing to trust: finite, positive, non-empty.
    var isValidMaskRect: Bool {
        origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite
            && width > 1 && height > 1
    }
}

// MARK: - Regional OCR

/// One word the recognizer claims to have read. A plain value type on purpose:
/// the contract must not depend on Vision's classes, so gates can inject exact
/// confidences and forced errors and still exercise the REAL policy.
struct RecognizedWord: Equatable {
    /// Bottom-left pixel rect inside the patch that was recognized.
    let rect: CGRect
    let confidence: Float

    init(rect: CGRect, confidence: Float) {
        self.rect = rect
        self.confidence = confidence
    }
}

enum SliceBOCR {
    enum RecognizeError: Error {
        case requestFailed
        case unmappableRange
    }

    /// Tests inject a recognizer so a gate can drive the real policy without
    /// depending on Vision's language models or the host OS version.
    nonisolated(unsafe) static var recognizerForTesting:
        ((CGImage) -> Result<[RecognizedWord], Error>)?

    /// At most this many OCR jobs may be in flight; extra requests coalesce.
    static let maxConcurrentJobs = 2
    /// A region bigger than this is refused outright (fail closed to full mask)
    /// rather than handing a 5K x 40K stitch to Vision.
    static let maxRegionPixels = 8_000_000
    /// Vision confidence below this is treated as "could not read it".
    static let minimumConfidence: Float = 0.3

    /// A bounded, materialized patch plus the offset needed to map results
    /// back into image space. Built on the caller's thread BEFORE a job is
    /// enqueued, so background work never holds the full stitch alive.
    struct Patch {
        let image: CGImage
        let origin: CGPoint
        let clip: CGRect
    }

    static func patch(base: CGImage, region: CGRect) -> Patch? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let clipped = region.standardized.integral.intersection(bounds)
        guard clipped.width > 1, clipped.height > 1 else { return nil }
        guard Int(clipped.width * clipped.height) <= maxRegionPixels
        else { return nil }
        // CGImage.cropping is TOP-left; annotation space is bottom-left.
        let topLeft = CGRect(
            x: clipped.minX, y: CGFloat(base.height) - clipped.maxY,
            width: clipped.width, height: clipped.height)
        guard let cropped = base.cropping(to: topLeft)?.materialized()
        else { return nil }
        return Patch(image: cropped, origin: clipped.origin, clip: clipped)
    }

    /// THE policy, shared by production and gates.
    ///
    /// ALL-OR-NOTHING: a recognizer error, an empty result, one word below the
    /// confidence threshold, one non-finite/degenerate box, or one box that is
    /// not entirely inside the recognized region (measured BEFORE the
    /// anti-aliasing outset) discards everything. Keeping "the good ones" would
    /// leave exactly the words we failed to read legible.
    static func resolve(
        _ result: Result<[RecognizedWord], Error>, in patch: Patch
    ) -> [CGRect] {
        guard case let .success(words) = result, !words.isEmpty else {
            return []
        }
        var out: [CGRect] = []
        for word in words {
            guard word.confidence >= minimumConfidence else { return [] }
            let box = word.rect
            guard box.origin.x.isFinite, box.origin.y.isFinite,
                  box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0
            else { return [] }
            let global = CGRect(
                x: patch.origin.x + box.minX, y: patch.origin.y + box.minY,
                width: box.width, height: box.height)
            guard patch.clip.contains(global) else { return [] }
            let padded = global
                .insetBy(
                    dx: -SliceBRedaction.wordOutset,
                    dy: -SliceBRedaction.wordOutset)
                .intersection(patch.clip)
            guard padded.isValidMaskRect else { return [] }
            out.append(padded)
        }
        return out
    }

    /// Pure and thread-safe: holds nothing but the patch.
    static func wordRects(in patch: Patch) -> [CGRect] {
        let result = recognizerForTesting?(patch.image)
            ?? visionWords(in: patch.image)
        return resolve(result, in: patch)
    }

    /// Convenience for one-shot callers and gates.
    static func wordRects(base: CGImage, region: CGRect) -> [CGRect] {
        guard let patch = patch(base: base, region: region) else { return [] }
        return wordRects(in: patch)
    }

    /// Per-word boxes: `VNRecognizedText.boundingBox(for:)` hugs the ink much
    /// more tightly than the line-level observation box, which keeps the
    /// surrounding layout readable. Any range that cannot be mapped is an
    /// error, not a word to skip.
    private static func visionWords(
        in patch: CGImage
    ) -> Result<[RecognizedWord], Error> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let langs = Settings.shared.ocrLanguage.visionLanguages
        if !langs.isEmpty {
            request.recognitionLanguages = langs
        } else {
            request.automaticallyDetectsLanguage = true
        }
        do {
            try VNImageRequestHandler(cgImage: patch, options: [:])
                .perform([request])
        } catch {
            return .failure(error)
        }

        let w = CGFloat(patch.width), h = CGFloat(patch.height)
        var out: [RecognizedWord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else {
                return .failure(RecognizeError.requestFailed)
            }
            let text = candidate.string
            let words = text.split(separator: " ")
            guard !words.isEmpty else {
                return .failure(RecognizeError.unmappableRange)
            }
            // Walk ranges SEQUENTIALLY so a repeated word maps to its own
            // occurrence instead of the first one over and over.
            var cursor = text.startIndex
            for word in words {
                guard let range = text.range(
                        of: String(word), range: cursor..<text.endIndex),
                      let box = try? candidate.boundingBox(for: range)
                else { return .failure(RecognizeError.unmappableRange) }
                cursor = range.upperBound
                let bb = box.boundingBox
                out.append(RecognizedWord(
                    rect: CGRect(
                        x: bb.minX * w, y: bb.minY * h,
                        width: bb.width * w, height: bb.height * h),
                    confidence: candidate.confidence))
            }
        }
        return .success(out)
    }
}

// MARK: - New annotation types

/// Dim everything outside `rect`. v1 is a singleton: darkness never stacks.
/// `baseBounds` is captured at creation so a cropped export dims the same
/// region the preview showed.
final class SpotlightAnnotation: Annotation {
    var rect: CGRect = .zero
    var baseBounds: CGRect = .zero
    /// 0.1 ... 0.9, driven by number keys 1-9.
    var dimFraction: CGFloat = 0.6

    override var bounds: CGRect { rect }

    /// The hole is the object: clicking the lit area selects the spotlight,
    /// clicking the dimmed surround does not.
    override func hitTest(_ p: CGPoint) -> Bool { rect.contains(p) }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        let canvas = baseBounds.isEmpty ? rect : baseBounds
        guard canvas.width > 0, canvas.height > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(
            NSColor.black.withAlphaComponent(
                max(0.1, min(0.9, dimFraction))).cgColor)
        ctx.beginPath()
        ctx.addRect(canvas)
        ctx.addRect(rect)
        ctx.fillPath(using: .evenOdd)
    }

    override func move(by delta: CGPoint) {
        rect.origin.x += delta.x
        rect.origin.y += delta.y
    }

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        rect = rect.applying(CGAffineTransform(scaleX: factor, y: factor))
        baseBounds = baseBounds.applying(
            CGAffineTransform(scaleX: factor, y: factor))
    }

    override func copyAnnotation() -> Annotation {
        let c = SpotlightAnnotation(uiScale: uiScale)
        c.rect = rect
        c.baseBounds = baseBounds
        c.dimFraction = dimFraction
        c.color = color
        return c
    }
}

/// The document's backdrop preset, carried as an annotation.
///
/// The frame is not a mark — it draws nothing here and covers no pixels — but
/// choosing one IS an edit, and the overlay's history is a single array of
/// annotations. Modelling the preset as an entry in that array is what makes
/// mark → preset → mark undo in exactly that order: a parallel stack could
/// record the presets but not where they sat between the marks. The editor
/// keeps its own snapshot-based undo and does not use this.
final class BackdropAnnotation: Annotation {
    let preset: BackdropPreset

    init(preset: BackdropPreset, uiScale: CGFloat) {
        self.preset = preset
        super.init(uiScale: uiScale)
    }

    /// Nothing to hit and nothing to move: Select must never pick this up, and
    /// a crop must not translate it.
    override var bounds: CGRect { .null }
    override func hitTest(_ p: CGPoint) -> Bool { false }
    override func move(by delta: CGPoint) {}
    override func translateForDocumentChange(by delta: CGPoint) {}
    override func scaleCoordinates(by factor: CGFloat) {}
    /// The frame is composed around the finished raster, not drawn into it.
    override func draw(in ctx: CGContext, pixellated: CGImage?) {}

    override func copyAnnotation() -> Annotation {
        BackdropAnnotation(preset: preset, uiScale: uiScale)
    }
}

/// Callout that magnifies a cluster of pixels. The snapshot is taken from the
/// SANITIZED layer (after redactions) and materialized, so dragging the
/// callout can never re-expose pixels a redaction covered.
final class MagnifierAnnotation: Annotation {
    var sourceRect: CGRect = .zero
    var calloutRect: CGRect = .zero
    var snapshot: CGImage?

    override var bounds: CGRect { calloutRect }

    override func hitTest(_ p: CGPoint) -> Bool { calloutRect.contains(p) }

    override func draw(in ctx: CGContext, pixellated: CGImage?) {
        guard let snapshot, calloutRect.width > 1, calloutRect.height > 1
        else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setShadow(
            offset: CGSize(width: 0, height: -2 * uiScale), blur: 6 * uiScale,
            color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.interpolationQuality = .none
        ctx.draw(snapshot, in: calloutRect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(max(1, 2 * uiScale))
        ctx.stroke(calloutRect)
    }

    /// Dragging moves the callout only — it never re-aims the source, so the
    /// sanitized pixels stay the ones the user chose.
    override func move(by delta: CGPoint) {
        calloutRect.origin.x += delta.x
        calloutRect.origin.y += delta.y
    }

    /// A crop moves the whole document under the annotation, so the source
    /// travels with the callout; moving only the callout would leave the
    /// magnifier pointing at different pixels than the user picked.
    override func translateForDocumentChange(by delta: CGPoint) {
        sourceRect.origin.x += delta.x
        sourceRect.origin.y += delta.y
        calloutRect.origin.x += delta.x
        calloutRect.origin.y += delta.y
    }

    override func scaleCoordinates(by factor: CGFloat) {
        super.scaleCoordinates(by: factor)
        sourceRect = sourceRect.applying(
            CGAffineTransform(scaleX: factor, y: factor))
        calloutRect = calloutRect.applying(
            CGAffineTransform(scaleX: factor, y: factor))
    }

    override func copyAnnotation() -> Annotation {
        let c = MagnifierAnnotation(uiScale: uiScale)
        c.sourceRect = sourceRect
        c.calloutRect = calloutRect
        c.snapshot = snapshot
        c.color = color
        return c
    }
}

// MARK: - Compositor

/// Fixed phase order shared by the editor and `AnnotationSurface`:
/// base -> redaction -> spotlight -> foreground/magnifier.
/// Partitioning spotlights to the front of the annotation array is NOT enough:
/// pixelate redraws base pixels and would erase the dim layer.
enum SliceBPhase: Int, Comparable {
    case redaction = 0
    case spotlight = 1
    case foreground = 2

    static func < (a: SliceBPhase, b: SliceBPhase) -> Bool {
        a.rawValue < b.rawValue
    }
}

enum SliceBCompositor {
    static func phase(of annotation: Annotation) -> SliceBPhase {
        if annotation is BlurAnnotation { return .redaction }
        if annotation is SpotlightAnnotation { return .spotlight }
        return .foreground
    }

    /// Stable sort of annotations into phase order.
    static func phaseOrder(_ annotations: [Annotation]) -> [Annotation] {
        annotations.enumerated()
            .sorted {
                let pa = phase(of: $0.element), pb = phase(of: $1.element)
                return pa == pb ? $0.offset < $1.offset : pa < pb
            }
            .map(\.element)
    }

    /// Opaque cover drawn when a redaction cannot be rendered. Fail CLOSED:
    /// the user sees a solid block, never the pixels underneath.
    static func drawFailedRedaction(_ rects: [CGRect], in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        for rect in rects { ctx.fill(rect) }
    }

    /// The one renderer. Returns false when any redaction could not be
    /// pixelated — the covered area is still opaque, but callers must treat the
    /// result as unfit for export.
    @discardableResult
    static func draw(
        _ annotations: [Annotation], in ctx: CGContext, base: CGImage,
        visiblePixels: CGRect, pixelScale: CGFloat = 1
    ) -> Bool {
        let baseBounds = CGRect(
            x: 0, y: 0, width: base.width, height: base.height)
        var renderedAll = true

        for annotation in phaseOrder(annotations) {
            guard let blur = annotation as? BlurAnnotation else {
                annotation.draw(in: ctx, pixellated: nil)
                continue
            }
            // A redaction whose own rect is not finite and positive tells us
            // nothing about WHERE to cover, so cover everything visible rather
            // than skip it and claim success.
            guard blur.rect.isValidMaskRect else {
                renderedAll = false
                drawFailedRedaction(
                    [visiblePixels.intersection(baseBounds)], in: ctx)
                continue
            }
            let masks = SliceBRedaction.maskRects(
                state: blur.redactionState, rect: blur.rect)
            var failed: [CGRect] = []
            for mask in masks {
                let requested = mask.standardized
                    .intersection(visiblePixels)
                    .intersection(baseBounds)
                // No overlap at all is fine; ANY overlap must be covered, even
                // a sliver under a pixel. Skipping a 1px intersection and
                // returning success left clean pixels along the mask edge.
                guard !requested.isNull,
                      requested.width > 0, requested.height > 0
                else { continue }
                let region = requested.integral.intersection(baseBounds)
                guard region.width >= 1, region.height >= 1,
                      let pixelated = AnnotationRenderer.pixellateRegion(
                        base, rect: region, scale: pixelScale)
                else {
                    renderedAll = false
                    failed.append(
                        region.width >= 1 && region.height >= 1
                            ? region : requested)
                    continue
                }
                ctx.saveGState()
                ctx.clip(to: mask)
                ctx.draw(pixelated, in: region)
                ctx.restoreGState()
            }
            if !failed.isEmpty { drawFailedRedaction(failed, in: ctx) }
        }
        return renderedAll
    }

    /// Source pixels for a magnifier callout, taken AFTER redactions so the
    /// callout can never resurrect covered pixels.
    static func magnifierSnapshot(
        base: CGImage, sourceRect: CGRect, redactions: [BlurAnnotation]
    ) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let region = sourceRect.standardized.integral.intersection(bounds)
        guard region.width > 1, region.height > 1 else { return nil }

        // A redaction with undefined geometry cannot be shown NOT to cover the
        // source, so the callout must not sample raw pixels. Fail closed.
        guard redactions.allSatisfy({ $0.rect.isValidMaskRect }) else {
            return nil
        }
        let overlapping = redactions.filter {
            SliceBRedaction.maskRects(state: $0.redactionState, rect: $0.rect)
                .contains { $0.intersects(region) }
        }
        guard !overlapping.isEmpty else {
            // CGImage.cropping is TOP-left; the caller works bottom-left.
            let topLeft = CGRect(
                x: region.minX, y: CGFloat(base.height) - region.maxY,
                width: region.width, height: region.height)
            return base.cropping(to: topLeft)?.materialized()
        }

        let w = Int(region.width), h = Int(region.height)
        // Crop FIRST, allocate second. Ordering the fallible step before the
        // allocation removes a whole class of accounting bug: there can be no
        // "allocated but then failed" state to mis-record.
        let topLeft = CGRect(
            x: region.minX, y: CGFloat(base.height) - region.maxY,
            width: region.width, height: region.height)
        guard let crop = base.cropping(to: topLeft) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        RenderTrace.record(
            kind: "destination", destination: "\(w)x\(h)", rect: region)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Draw the overlapping redactions in the patch's own space.
        ctx.translateBy(x: -region.minX, y: -region.minY)
        guard draw(
            overlapping, in: ctx, base: base, visiblePixels: region)
        else { return nil }
        return ctx.makeImage()
    }

    /// A magnifier patch must be rebuilt when a redaction starts (or stops)
    /// overlapping its source, or the callout would keep showing pixels the
    /// user has just covered.
    static func needsRebuild(
        source: CGRect, redactions: [BlurAnnotation]
    ) -> Bool {
        // Undefined geometry means we cannot prove the patch is still safe, so
        // it must be rebuilt (and the rebuild will fail closed).
        if redactions.contains(where: { !$0.rect.isValidMaskRect }) { return true }
        return redactions.contains { blur in
            SliceBRedaction.maskRects(state: blur.redactionState, rect: blur.rect)
                .contains { $0.intersects(source) }
        }
    }

    /// Spotlight v1 is a singleton: adding a second one replaces the first so
    /// darkness never stacks.
    static func applySpotlight(
        existing: [Annotation], new: SpotlightAnnotation
    ) -> [Annotation] {
        existing.filter { !($0 is SpotlightAnnotation) } + [new]
    }
}

/// Jobs owned by one host, keyed by the annotation they answer. The editor and
/// both overlay surfaces share this so "is the job registered / did it clean
/// itself up" means the same thing everywhere.
@MainActor
final class RedactionJobRegistry: RedactionJobObserver {
    private var jobs: [ObjectIdentifier: SliceBRedactionJob] = [:]

    var count: Int { jobs.count }

    func register(_ job: SliceBRedactionJob, for annotation: Annotation) {
        jobs[ObjectIdentifier(annotation)] = job
        job.setCompletionObserver(self)
    }

    func cancel(for annotation: Annotation) {
        if let job = jobs.removeValue(forKey: ObjectIdentifier(annotation)) {
            job.cancel()
        }
        if let blur = annotation as? BlurAnnotation {
            blur.bumpRedactionGeneration()
        }
    }

    func cancelAll() {
        for (id, job) in jobs {
            job.cancel()
            jobs.removeValue(forKey: id)
        }
    }

    func redactionJobDidFinish(_ job: SliceBRedactionJob) {
        for (id, registered) in jobs where registered === job {
            jobs.removeValue(forKey: id)
        }
    }
}

// MARK: - Fail-closed export

enum SliceBExport {
    /// Editor export must not be fail-open. Returns nil when the destination
    /// cannot be built within `budgetBytes` or when any redaction failed to
    /// render; callers keep the session open and surface the failure.
    static func checkedRender(
        base: CGImage, annotations: [Annotation],
        pixellated: CGImage?, budgetBytes: Int,
        pixelScale: CGFloat = 1
    ) -> CGImage? {
        let w = base.width, h = base.height
        // Same overflow discipline as the outer compose: a huge stitch must
        // fail closed here, not trap or wrap into a small number.
        guard let needed = byteCount(width: w, height: h),
              needed <= budgetBytes else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The destination buffer HAS been allocated at this point, even if the
        // render later fails — the trace must say so.
        RenderTrace.record(
            kind: "destination", destination: "\(w)x\(h)",
            rect: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard SliceBCompositor.draw(
            annotations, in: ctx, base: base,
            visiblePixels: CGRect(x: 0, y: 0, width: w, height: h),
            pixelScale: pixelScale)
        else { return nil }
        return ctx.makeImage()
    }

    /// Bytes an RGBA buffer of these dimensions occupies, or nil when the
    /// product cannot be represented. Pure and allocation-free, so a caller can
    /// check the PEAK of several buffers before it commits to any of them.
    static func byteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pOverflow else { return nil }
        let (bytes, bOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return bOverflow ? nil : bytes
    }

    /// 256 MP * 4 bytes, matching slice A's resize cap.
    ///
    /// Overridable so a gate can drive the REAL peak boundary — production
    /// apply, resize and export all read this — without a gigabyte fixture.
    /// Nothing in production ever sets the override.
    nonisolated(unsafe) private static var budgetStacks: [ObjectIdentifier: [Int]] = [:]
    private static let budgetLock = NSLock()

    static var defaultBudgetBytes: Int {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        return budgetStacks[ObjectIdentifier(Thread.current)]?.last
            ?? 256 * 1_000_000 * 4
    }

    /// Open scopes on this thread. A gate that only checks the value before
    /// and inside a scope cannot see a pop that never happened.
    static var budgetScopeDepthForTesting: Int {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        return budgetStacks[ObjectIdentifier(Thread.current)]?.count ?? 0
    }

    /// Per-thread stack, like `RenderTrace`: a save-and-restore global is
    /// correct only while nothing overlaps, and two scopes on two threads
    /// would clobber each other's restore.
    static func withBudgetForTesting<T>(_ bytes: Int, _ body: () -> T) -> T {
        let key = ObjectIdentifier(Thread.current)
        budgetLock.lock()
        budgetStacks[key, default: []].append(bytes)
        budgetLock.unlock()
        defer {
            budgetLock.lock()
            if var stack = budgetStacks[key], !stack.isEmpty {
                stack.removeLast()
                budgetStacks[key] = stack.isEmpty ? nil : stack
            }
            budgetLock.unlock()
        }
        return body()
    }

    /// Budget arithmetic that cannot wrap: nil means there is nothing left.
    static func budget(_ total: Int, minus reserve: Int) -> Int? {
        guard reserve >= 0, reserve < total else { return nil }
        return total - reserve
    }
}

// MARK: - Toolbar symbols

enum SliceBSymbols {
    /// Never force-unwrap `NSImage(systemSymbolName:)`: a symbol missing on the
    /// deployment target would crash while building the toolbar. Falls back to
    /// a secondary symbol and finally to a drawn placeholder, so a button is
    /// always visible and always labelled.
    static func image(named symbol: String, fallback: String) -> NSImage? {
        if let primary = NSImage(
            systemSymbolName: symbol, accessibilityDescription: symbol) {
            return primary
        }
        if let secondary = NSImage(
            systemSymbolName: fallback, accessibilityDescription: symbol) {
            return secondary
        }
        let size = NSSize(width: 16, height: 16)
        let drawn = NSImage(size: size)
        drawn.lockFocus()
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: 14, height: 14),
            xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.stroke()
        drawn.unlockFocus()
        drawn.accessibilityDescription = symbol
        return drawn
    }
}

// MARK: - Backdrop

/// Drives an OUTER compose failure. The regional seam only fails the inner
/// render, so without this the fail-closed path through `compose` — the one
/// that decides whether a terminal action may proceed — is never exercised.
enum ForcedOuterComposeFailure {
    nonisolated(unsafe) private static var tokens: Set<ObjectIdentifier> = []
    private static let lock = NSLock()

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !tokens.isEmpty
    }

    private final class Token {}

    static func scoped<T>(_ body: () -> T) -> T {
        let token = Token()
        let id = ObjectIdentifier(token)
        lock.lock()
        tokens.insert(id)
        lock.unlock()
        defer {
            lock.lock()
            tokens.remove(id)
            lock.unlock()
            _ = token
        }
        return body()
    }
}

enum BackdropPreset: String, CaseIterable {
    case none, ocean, sunset, mint, graphite
}

/// The ONE description of a framed document's geometry.
///
/// Preview, the scroll document, fit, the size badge and export all read their
/// numbers from here. When each of them derived its own, they disagreed about
/// where the image sat inside the frame — and a click landed on a different
/// pixel than the one under the cursor.
struct BackdropLayout: Equatable {
    let preset: BackdropPreset
    let pixelScale: CGFloat
    /// Padding on every edge, in pixels and in points.
    let padPixels: CGFloat
    let padPoints: CGFloat
    let innerPixelSize: CGSize
    let outerPixelSize: CGSize
    let innerPointSize: CGSize
    let outerPointSize: CGSize

    init(innerPixels: CGSize, pixelScale: CGFloat, preset: BackdropPreset) {
        let scale = max(1, pixelScale)
        let inner = CGSize(
            width: max(0, innerPixels.width), height: max(0, innerPixels.height))
        let pad: CGFloat = preset == .none
            ? 0
            : SliceBBackdrop.padding(
                forLongEdge: max(inner.width, inner.height),
                pixelScale: scale)
        self.preset = preset
        self.pixelScale = scale
        self.padPixels = pad
        self.padPoints = pad / scale
        self.innerPixelSize = inner
        self.outerPixelSize = CGSize(
            width: inner.width + pad * 2, height: inner.height + pad * 2)
        self.innerPointSize = CGSize(
            width: inner.width / scale, height: inner.height / scale)
        self.outerPointSize = CGSize(
            width: (inner.width + pad * 2) / scale,
            height: (inner.height + pad * 2) / scale)
    }

    /// Where the untouched document sits inside the frame, in points. The
    /// canvas keeps its own coordinates: nothing is translated or baked, so a
    /// mark, a crop, a guide and an OCR box all stay source-local.
    var innerPointRect: CGRect {
        CGRect(
            origin: CGPoint(x: padPoints, y: padPoints),
            size: innerPointSize)
    }

    /// `.none` collapses: the frame is not a thin border, it is absent.
    var isCollapsed: Bool { preset == .none || padPixels == 0 }
}

enum SliceBBackdrop {
    static let paddingFraction: CGFloat = 0.06
    static let minPadding: CGFloat = 40
    /// A 40 000 px scrolling capture would otherwise get 2 400 px of padding.
    static let maxPadding: CGFloat = 320

    /// How far the drop shadow reaches beyond the image edge, in PIXELS. The
    /// shadow is a point metric, so at scale 2 it reaches 64 px below the image
    /// while the 40 px floor would clip it — the frame must be at least this
    /// wide on every edge or the shadow is cut off at the outer canvas.
    /// A Gaussian has no hard cutoff, so blur + offset is where the shadow
    /// becomes negligible, not where it stops. The margin keeps the frame wider
    /// than the visible tail instead of trusting that figure as an exact API
    /// contract.
    static let shadowSafetyFactor: CGFloat = 1.25

    static func shadowExtent(pixelScale: CGFloat) -> CGFloat {
        let scale = max(1, pixelScale)
        let nominal = (shadowBlurPt + abs(shadowOffsetPt)) * scale
        return (nominal * shadowSafetyFactor).rounded(.up)
    }

    /// The floor is whichever is larger: the fixed minimum or the shadow's own
    /// reach. The 320 px cap is raised to the floor for the same reason — a cap
    /// that clips the shadow is not a cap, it is a rendering bug.
    static func padding(
        forLongEdge edge: CGFloat, pixelScale: CGFloat = 1
    ) -> CGFloat {
        let floor = max(minPadding, shadowExtent(pixelScale: pixelScale))
        let cap = max(maxPadding, floor)
        return min(cap, max(floor, (edge * paddingFraction).rounded()))
    }

    /// Outer canvas size for an inner image of these dimensions. Preview,
    /// reserve, fingerprint and export all read the frame's size from HERE, so
    /// none of them can disagree about how big the composed result is.
    static func outerDimensions(
        innerWidth: Int, innerHeight: Int, preset: BackdropPreset,
        pixelScale: CGFloat = 1
    ) -> (width: Int, height: Int)? {
        guard innerWidth > 0, innerHeight > 0 else { return nil }
        guard preset != .none else { return (innerWidth, innerHeight) }
        let pad = Int(padding(
            forLongEdge: CGFloat(max(innerWidth, innerHeight)),
            pixelScale: pixelScale))
        let (twice, tOverflow) = pad.multipliedReportingOverflow(by: 2)
        guard !tOverflow else { return nil }
        let (w, wOverflow) = innerWidth.addingReportingOverflow(twice)
        let (h, hOverflow) = innerHeight.addingReportingOverflow(twice)
        guard !wOverflow, !hOverflow else { return nil }
        return (w, h)
    }

    /// Backdrop is an OUTER frame: a click at `padded` must resolve to the
    /// same source pixel it did before the backdrop existed.
    static func sourcePoint(
        fromPadded point: CGPoint, padding: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x - padding, y: point.y - padding)
    }

    /// Bytes the outer frame will occupy for a given inner image. Both buffers
    /// are alive at once during a compose, so the caller must reserve this
    /// before it renders the inner one.
    static func reservedBytes(
        forInnerWidth width: Int, height: Int, preset: BackdropPreset,
        pixelScale: CGFloat = 1
    ) -> Int {
        guard preset != .none else { return 0 }
        guard let outer = outerDimensions(
            innerWidth: width, innerHeight: height, preset: preset,
            pixelScale: pixelScale),
            let bytes = SliceBExport.byteCount(
                width: outer.width, height: outer.height)
        else { return Int.max }
        return bytes
    }

    static func reservedBytes(
        forInner image: CGImage, preset: BackdropPreset,
        pixelScale: CGFloat = 1
    ) -> Int {
        reservedBytes(
            forInnerWidth: image.width, height: image.height, preset: preset,
            pixelScale: pixelScale)
    }

    /// `.none` is byte-identical to the input; anything over budget fails
    /// closed instead of allocating.
    /// Corner radius and shadow are POINT metrics; padding is pixels. On a
    /// Retina document a fixed pixel radius would render at half the intended
    /// size, so the caller passes the document's scale.
    static let cornerRadiusPt: CGFloat = 12
    static let shadowOffsetPt: CGFloat = -8
    static let shadowBlurPt: CGFloat = 24

    /// Draws the frame — gradient, shadow, rounded plate — into `ctx` for a
    /// canvas of `size` PIXELS, leaving `target` for the document itself.
    /// `compose` and the on-screen preview both call this, so what the user
    /// reviews and what is exported cannot drift apart.
    @discardableResult
    static func drawFrame(
        in ctx: CGContext, size: CGSize, target: CGRect,
        preset: BackdropPreset, pixelScale: CGFloat,
        documentPixelsPerUserUnit: CGFloat = 1
    ) -> Bool {
        guard preset != .none else { return true }
        guard drawFill(
            in: ctx, size: size, preset: preset,
            documentPixelsPerUserUnit: documentPixelsPerUserUnit)
        else { return false }
        let scale = max(1, pixelScale)
        ctx.setShadow(
            offset: CGSize(width: 0, height: shadowOffsetPt * scale),
            blur: shadowBlurPt * scale,
            color: NSColor.black.withAlphaComponent(0.35).cgColor)
        let radius = cornerRadiusPt * scale
        let rounded = CGPath(
            roundedRect: target, cornerWidth: radius, cornerHeight: radius,
            transform: nil)
        // The opaque rounded fill exists only to cast the shadow. Leaving it
        // under the image would turn every transparent or translucent source
        // pixel black instead of letting the gradient show through, so the
        // fill is redrawn inside the shape before the image goes on top.
        ctx.addPath(rounded)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        // The SAME fill, in the SAME canvas coordinates: re-running it inside
        // the clip keeps the gradient, the wash and the grain phase continuous
        // across the plate edge instead of restarting at the plate's origin.
        guard drawFill(
            in: ctx, size: size, preset: preset,
            documentPixelsPerUserUnit: documentPixelsPerUserUnit) else {
            ctx.restoreGState()
            return false
        }
        ctx.restoreGState()
        return true
    }

    /// The background, in one place: a four-stop linear ramp, a soft radial
    /// wash from the upper left, and a deterministic grain that breaks up the
    /// banding a smooth ramp shows on an 8-bit display.
    ///
    /// `documentPixelsPerUserUnit` is what keeps the grain the same SIZE in
    /// both draw paths. Compose works in bitmap pixels (1), the preview works
    /// in points (the document's scale), and the tile is specified in document
    /// pixels — mixing the two makes a @2x preview show a grain twice the
    /// period of the exported one.
    @discardableResult
    static func drawFill(
        in ctx: CGContext, size: CGSize, preset: BackdropPreset,
        documentPixelsPerUserUnit: CGFloat = 1
    ) -> Bool {
        guard preset != .none else { return true }
        let stops = gradientStops(for: preset)
        guard let fill = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: stops.map(\.color) as CFArray,
            locations: stops.map(\.location))
        else { return false }
        let axis = gradientAxis(width: size.width, height: size.height)
        ctx.drawLinearGradient(
            fill, start: axis.start, end: axis.end, options: [])

        let wash = radialWash(for: preset)
        guard let washGradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [wash.centre, wash.edge] as CFArray, locations: [0, 1])
        else { return false }
        ctx.drawRadialGradient(
            washGradient,
            startCenter: CGPoint(
                x: 0.22 * size.width, y: 0.78 * size.height),
            startRadius: 0,
            endCenter: CGPoint(
                x: 0.22 * size.width, y: 0.78 * size.height),
            endRadius: hypot(size.width, size.height) * 0.85,
            options: [])

        guard let grain = grainTile(for: preset) else { return false }
        // Tiled from the canvas ORIGIN every time, never from a dirty rect:
        // panning or a partial redraw must not shift the pattern. CGPattern is
        // deliberately not used — its phase follows the CTM.
        let tileSide = CGFloat(Self.grainTileSide)
            / max(0.0001, documentPixelsPerUserUnit)
        ctx.saveGState()
        ctx.setBlendMode(.overlay)
        // ONE call. `byTiling` replicates the image across the current clip in
        // user space, anchored to the rect's origin — which is the canvas
        // origin here, so the phase is exactly the one the spec fixes and a
        // partial redraw lands on the same pattern as a full one. Tiling by
        // hand cost ~900 blits per pass on a 5K frame, twice per event while
        // the user drags, and clipping the loop only trimmed about an eighth
        // of that. This is not CGPattern: no CTM-dependent phase.
        ctx.draw(
            grain,
            in: CGRect(x: 0, y: 0, width: tileSide, height: tileSide),
            byTiling: true)
        countGrainTileBlits(1)
        ctx.restoreGState()
        return true
    }

    /// The 1pt white line that softens the plate's clipped edge. Drawn AFTER
    /// the image and inside the plate's clip, so it sits on top of the
    /// screenshot rather than under it.
    static func drawPlateHairline(
        in ctx: CGContext, rect: CGRect, pixelScale: CGFloat
    ) {
        let scale = max(1, pixelScale)
        let radius = cornerRadiusPt * scale
        // Inset by half the line width so the whole stroke lands INSIDE the
        // plate: a centred stroke would spill half of itself onto the frame.
        let inset = rect.insetBy(dx: 0.5 * scale, dy: 0.5 * scale)
        guard inset.width > 0, inset.height > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1 * scale)
        ctx.setStrokeColor(
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16).cgColor)
        ctx.addPath(CGPath(
            roundedRect: inset,
            cornerWidth: max(0, radius - 0.5 * scale),
            cornerHeight: max(0, radius - 0.5 * scale), transform: nil))
        ctx.strokePath()
    }

    /// Tile side in DOCUMENT pixels.
    static let grainTileSide = 128

    /// How many tiling DRAWS the fills have issued — one per fill pass, so a
    /// backdrop frame costs two, not one per tile. Compose can run off the
    /// main thread, so this is locked rather than a bare global, and it
    /// ACCUMULATES: a counter that reset itself per call would hide the second
    /// pass entirely.
    private nonisolated(unsafe) static var grainTileBlits = 0
    private static let grainTileBlitsLock = NSLock()
    static var grainTileBlitsForTesting: Int {
        grainTileBlitsLock.lock()
        defer { grainTileBlitsLock.unlock() }
        return grainTileBlits
    }
    static func resetGrainTileBlitsForTesting() {
        grainTileBlitsLock.lock()
        grainTileBlits = 0
        grainTileBlitsLock.unlock()
    }
    private static func countGrainTileBlits(_ n: Int) {
        guard n > 0 else { return }
        grainTileBlitsLock.lock()
        grainTileBlits += n
        grainTileBlitsLock.unlock()
    }

    static func grainSeed(for preset: BackdropPreset) -> UInt32 {
        switch preset {
        case .none: return 0
        case .ocean: return 0x0CE4_0001
        case .sunset: return 0x5E70_0002
        case .mint: return 0xA117_0003
        case .graphite: return 0x6A40_0004
        }
    }

    /// Deterministic by construction: same preset, same bytes, every run and
    /// every machine. No `arc4random`, no clock.
    static func grainHash(x: Int, y: Int, seed: UInt32) -> UInt32 {
        var h = seed
        h &+= UInt32(bitPattern: Int32(truncatingIfNeeded: x))
            &* 374_761_393
        h &+= UInt32(bitPattern: Int32(truncatingIfNeeded: y))
            &* 668_265_263
        h ^= h >> 13
        h &*= 1_274_126_177
        h ^= h >> 16
        return h
    }

    private nonisolated(unsafe) static var grainCache: [UInt32: CGImage] = [:]
    private static let grainCacheLock = NSLock()

    static func grainTile(for preset: BackdropPreset) -> CGImage? {
        let seed = grainSeed(for: preset)
        grainCacheLock.lock()
        defer { grainCacheLock.unlock() }
        if let cached = grainCache[seed] { return cached }
        let side = grainTileSide
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = ctx.data
        else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            for x in 0..<side {
                // ±2/255 around mid grey: under `.overlay` that is a ±2 luma
                // nudge, which is what dithers the ramp without being visible
                // as texture.
                let delta = Int(grainHash(x: x, y: y, seed: seed) % 5) - 2
                let grey = UInt8(clamping: 128 + delta)
                let i = (y * side + x) * 4
                bytes[i] = grey
                bytes[i + 1] = grey
                bytes[i + 2] = grey
                bytes[i + 3] = 255
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        grainCache[seed] = image
        return image
    }

    /// The wash laid over the linear ramp: a light source in the upper left,
    /// falling to fully transparent at the edge.
    static func radialWash(
        for preset: BackdropPreset
    ) -> (centre: CGColor, edge: CGColor) {
        func srgb(
            _ r: Int, _ g: Int, _ b: Int, _ a: CGFloat
        ) -> CGColor {
            NSColor(
                srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: a).cgColor
        }
        switch preset {
        case .none: return (srgb(0, 0, 0, 0), srgb(0, 0, 0, 0))
        case .ocean:
            return (srgb(255, 255, 255, 0.20), srgb(255, 255, 255, 0))
        case .sunset:
            return (srgb(255, 232, 192, 0.18), srgb(255, 232, 192, 0))
        case .mint:
            return (srgb(232, 255, 246, 0.16), srgb(232, 255, 246, 0))
        case .graphite:
            return (srgb(139, 155, 184, 0.14), srgb(139, 155, 184, 0))
        }
    }

    /// The preset's four stops, location and colour together. Exposed so a
    /// reference render reads the SAME table production draws from and cannot
    /// drift from it.
    static func gradientStops(
        for preset: BackdropPreset
    ) -> [(location: CGFloat, color: CGColor)] {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
            NSColor(
                srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: 1).cgColor
        }
        switch preset {
        case .none:
            return [(0, rgb(0, 0, 0)), (1, rgb(0, 0, 0))]
        case .ocean:
            return [
                (0.00, rgb(139, 180, 255)), (0.28, rgb(74, 124, 240)),
                (0.62, rgb(46, 61, 184)), (1.00, rgb(26, 24, 104)),
            ]
        case .sunset:
            return [
                (0.00, rgb(255, 208, 138)), (0.28, rgb(255, 126, 74)),
                (0.62, rgb(230, 61, 120)), (1.00, rgb(122, 34, 136)),
            ]
        case .mint:
            return [
                (0.00, rgb(154, 245, 212)), (0.28, rgb(61, 220, 176)),
                (0.62, rgb(26, 154, 138)), (1.00, rgb(10, 69, 80)),
            ]
        case .graphite:
            // Its own locations: the mid tones sit further apart, or the
            // darkest stop swallows most of the frame.
            return [
                (0.00, rgb(90, 98, 112)), (0.32, rgb(52, 58, 70)),
                (0.68, rgb(28, 32, 40)), (1.00, rgb(11, 13, 17)),
            ]
        }
    }

    static func compose(
        image: CGImage, preset: BackdropPreset, budgetBytes: Int,
        pixelScale: CGFloat = 1
    ) -> CGImage? {
        guard preset != .none else { return image }
        guard !ForcedOuterComposeFailure.isActive else { return nil }
        let pad = padding(
            forLongEdge: CGFloat(max(image.width, image.height)),
            pixelScale: pixelScale)
        guard let outer = outerDimensions(
            innerWidth: image.width, innerHeight: image.height, preset: preset,
            pixelScale: pixelScale),
            let bytes = SliceBExport.byteCount(
                width: outer.width, height: outer.height),
            bytes <= budgetBytes
        else { return nil }
        let w = outer.width, h = outer.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0,
            // A FRAMED document is sRGB, deliberately. Every stop, wash and
            // grain value in the spec is written in sRGB; compositing them
            // into a P3 context would render the frame differently from the
            // preview and leave the match ungateable. `.none` never reaches
            // here, so a plain export still keeps its input space byte for
            // byte.
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let target = CGRect(
            x: pad, y: pad,
            width: CGFloat(image.width), height: CGFloat(image.height))
        // The SAME frame the preview draws. A gradient that cannot be built
        // fails the whole compose: carrying on would return a non-nil frame
        // with no background, which terminal callers would treat as success.
        guard drawFrame(
            in: ctx, size: CGSize(width: w, height: h), target: target,
            preset: preset, pixelScale: pixelScale,
            // The context IS the document's pixel grid here, so a grain texel
            // is a document pixel.
            documentPixelsPerUserUnit: 1)
        else { return nil }
        ctx.saveGState()
        let radius = cornerRadiusPt * max(1, pixelScale)
        ctx.addPath(CGPath(
            roundedRect: target, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
        ctx.clip()
        ctx.draw(image, in: target)
        // Inside the same clip and ON TOP of the screenshot: it softens the
        // clipped edge, which is the "jagged frame" the report was about.
        drawPlateHairline(in: ctx, rect: target, pixelScale: pixelScale)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The preset's stop colours, in order. Reads the same table `drawFill`
    /// draws from, so a caller cannot reproduce a background production no
    /// longer paints.
    static func gradientColors(for preset: BackdropPreset) -> [CGColor] {
        gradientStops(for: preset).map(\.color)
    }

    /// Gradient axis for a frame of this size, shared by `compose` and by
    /// anything reproducing the background.
    /// Takes the size as it IS, not truncated to whole units: a 121x81 @2
    /// document frames to 140.5 x 120.5 pt on screen, and rounding that down
    /// tilts the on-screen gradient away from the exported one.
    static func gradientAxis(
        width: CGFloat, height: CGFloat
    ) -> (start: CGPoint, end: CGPoint) {
        (CGPoint(x: 0, y: height), CGPoint(x: width, y: 0))
    }

}

// MARK: - Redaction lifecycle

/// One OCR job for one text-mode redaction.
///
/// The annotation shows a FULL mask the moment the job starts and only ever
/// narrows once a live result lands. A result whose generation no longer
/// matches the annotation (undo, redo, delete, move, crop, resize, save-lock,
/// close) is dropped: it is answering a question nobody is asking any more.
/// The surface (or window) that owns a redaction and repaints when its mask
/// changes. Jobs hold this WEAKLY by construction: there is no way to hand a
/// job a closure that captures the host strongly.
@MainActor
protocol RedactionHost: AnyObject {
    func redactionDidChange()
}

/// Owner notified when a job reaches any terminal state, so its registry entry
/// disappears. A weak protocol reference, not a closure: the type system keeps
/// the invariant instead of every caller having to remember `[weak]`.
@MainActor
protocol RedactionJobObserver: AnyObject {
    func redactionJobDidFinish(_ job: SliceBRedactionJob)
}

@MainActor
final class SliceBRedactionJob {
    private weak var blur: BlurAnnotation?  // cleared on cancel
    /// Immutable identity: the owner map must stay cleanable even after the
    /// weak reference has gone nil, or a dead job would hold the slot forever.
    private let annotationID: ObjectIdentifier
    private let generation: Int
    /// Weak by construction: a finished or cancelled job can never keep its
    /// host (and therefore the whole capture) alive.
    private weak var host: RedactionHost?
    private var delivered = false
    private var cancelled = false
    private var holdsSlot = false
    /// Set by the owning surface so its registry entry disappears the moment
    /// the job finishes, cancelled or not. Weak: a finished job must not keep
    /// its surface alive.
    private weak var completionObserver: RedactionJobObserver?

    func setCompletionObserver(_ observer: RedactionJobObserver?) {
        completionObserver = observer
    }

    private func releaseSlot() {
        guard holdsSlot else { return }
        holdsSlot = false
        Self.inFlight = max(0, Self.inFlight - 1)
    }

    /// Gate visibility: a finished run must leave no owner behind.
    static var ownerCountForTesting: Int { owners.count }

    /// Jobs currently in flight, so a surface can refuse to pile more on.
    private(set) static var inFlight = 0

    private init(
        blur: BlurAnnotation, generation: Int, host: RedactionHost?
    ) {
        self.blur = blur
        self.annotationID = ObjectIdentifier(blur)
        self.generation = generation
        self.host = host
    }

    /// Give up the owner slot, but only if it is still ours. Safe to call when
    /// the annotation itself is already gone.
    private func releaseOwnership() {
        if Self.owners[annotationID] === self {
            Self.owners.removeValue(forKey: annotationID)
        }
    }

    /// Starts a job, or returns nil when the queue is full or the region
    /// cannot be materialized — in which case the annotation stays fully
    /// masked (`fallbackFull`).
    /// One live job per annotation. A second start supersedes the first, and
    /// only the job holding the current token may apply a result.
    private static var owners: [ObjectIdentifier: SliceBRedactionJob] = [:]

    @discardableResult
    static func start(
        blur: BlurAnnotation, base: CGImage, host: RedactionHost?
    ) -> SliceBRedactionJob? {
        // A new request for the same annotation invalidates the old one.
        owners.removeValue(forKey: ObjectIdentifier(blur))?.cancel()
        guard inFlight < SliceBOCR.maxConcurrentJobs,
              // Materialize the bounded patch HERE: the background job must
              // never keep a 5K x 40K stitch alive after the window closes.
              let patch = SliceBOCR.patch(base: base, region: blur.rect)
        else {
            blur.redactionState = .fallbackFull
            host?.redactionDidChange()
            return nil
        }
        blur.redactionState = .pendingFull
        host?.redactionDidChange()
        let job = SliceBRedactionJob(
            blur: blur, generation: blur.redactionGeneration, host: host)
        job.holdsSlot = true
        owners[ObjectIdentifier(blur)] = job
        inFlight += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let words = SliceBOCR.wordRects(in: patch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { job.deliver(words) }
            }
        }
        return job
    }

    /// Owner invalidation: the surface dropped this annotation (undo, delete,
    /// dismiss, save-lock, close). This only marks the RESULT as unwanted —
    /// the slot stays occupied until the worker actually finishes, so a
    /// start/cancel loop cannot open unbounded real work.
    func cancel() {
        guard !delivered, !cancelled else { return }
        cancelled = true
        // A stale job must not evict a newer owner, and must still clean up
        // after itself when its annotation is gone.
        releaseOwnership()
        let changed = blur?.redactionState == .pendingFull
        blur?.normalizePendingRedaction()
        blur = nil
        let observer = completionObserver
        completionObserver = nil
        let notify = host
        host = nil   // drop the host: no late repaint after cancel
        observer?.redactionJobDidFinish(self)
        // Cancel DID change the mask (pending -> full), so this repaint is
        // real work, not a late echo.
        if changed { notify?.redactionDidChange() }
    }

    func deliver(_ words: [CGRect]) {
        guard !delivered else { return }
        delivered = true
        releaseSlot()
        // Ownership and registry cleanup happen on EVERY path, including the
        // one where the annotation has already been deallocated.
        let wasOwner = Self.owners[annotationID] === self
        releaseOwnership()
        let observer = completionObserver
        completionObserver = nil
        let notify = host
        host = nil
        observer?.redactionJobDidFinish(self)

        // A superseded / cancelled / non-owner result is SILENT: it changes
        // nothing, so it must not repaint anything either.
        guard !cancelled, wasOwner, let blur,
              blur.redactionState == .pendingFull
        else { return }
        let resolved = SliceBRedaction.applyWords(
            words, to: blur.redactionState,
            generation: generation, current: blur.redactionGeneration)
        // A superseded result must not leave the annotation pending forever:
        // an orphan `pendingFull` would mask correctly but never resolve.
        blur.redactionState = resolved == .pendingFull ? .fallbackFull : resolved
        notify?.redactionDidChange()
    }

    /// Test seam: a job that has not been enqueued, so a gate can land a
    /// result at an exact moment relative to an edit.
    static func pendingForTesting(
        blur: BlurAnnotation, host: RedactionHost? = nil
    ) -> SliceBRedactionJob {
        blur.redactionState = .pendingFull
        let job = SliceBRedactionJob(
            blur: blur, generation: blur.redactionGeneration, host: host)
        // Same ownership rule as a real job: whoever started last owns the
        // annotation, and only the owner may apply a result.
        owners[ObjectIdentifier(blur)]?.cancel()
        owners[ObjectIdentifier(blur)] = job
        return job

    }
}
