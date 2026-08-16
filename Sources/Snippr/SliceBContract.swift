import AppKit

/// Slice B fail-first contract surface (RED commit).
///
/// Everything here is deliberately UNIMPLEMENTED: each entry point returns the
/// empty / fail-closed answer so the `sliceB-*` gates in `SelfTest` stay red
/// until the real compositor lands. No production code path calls this file
/// yet, and no existing behaviour changes because of it.
///
/// Two invariants drive the shapes below:
/// 1. A redaction must never render "nothing". Every unknown/incomplete state
///    masks the whole rect; only a non-empty word list narrows the mask.
/// 2. Preview and export must derive their clip from the SAME function, so the
///    editor and both overlay surfaces cannot drift.

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

    static func resolvedWords(_ rects: [CGRect]) -> RedactionState {
        .pendingFull // RED: real impl returns .words(rects) / .fallbackFull
    }
}

enum SliceBRedaction {
    /// The single source of clip rects for preview AND export, on all three
    /// surfaces. Must never return an empty array.
    static func maskRects(state: RedactionState, rect: CGRect) -> [CGRect] {
        [] // RED
    }

    /// Async OCR landing. A result from a superseded generation (undo, delete,
    /// move, crop, resize, save-lock, close) must be dropped, not applied.
    static func applyWords(
        _ words: [CGRect], to state: RedactionState,
        generation: Int, current: Int
    ) -> RedactionState {
        .pendingFull // RED
    }

    /// Vision boxes hug the ink; anti-aliased edges need a small outset.
    static let wordOutset: CGFloat = 3
}

// MARK: - New annotation types (geometry only — no drawing yet)

/// Dim everything outside `rect`. v1 is a singleton: darkness never stacks.
/// `baseBounds` is captured at creation so a cropped export dims the same
/// region the preview showed.
final class SpotlightAnnotation: Annotation {
    var rect: CGRect = .zero
    var baseBounds: CGRect = .zero
    /// 0.1 ... 0.9, driven by number keys 1-9.
    var dimFraction: CGFloat = 0.6
}

/// Callout that magnifies a cluster of pixels. The snapshot is taken from the
/// SANITIZED layer (after redactions) and materialized, so dragging the
/// callout can never re-expose pixels a pixelate annotation covered.
final class MagnifierAnnotation: Annotation {
    var sourceRect: CGRect = .zero
    var calloutRect: CGRect = .zero
    var snapshot: CGImage?
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
        .foreground // RED
    }

    /// Stable sort of annotations into phase order.
    static func phaseOrder(_ annotations: [Annotation]) -> [Annotation] {
        annotations // RED
    }

    /// Source pixels for a magnifier callout, taken AFTER redactions.
    static func magnifierSnapshot(
        base: CGImage, sourceRect: CGRect, redactions: [BlurAnnotation]
    ) -> CGImage? {
        nil // RED
    }
}

// MARK: - Fail-closed export

enum SliceBExport {
    /// Editor export must stop being fail-open. `AnnotationRenderer.render`
    /// currently ends in `ctx.makeImage() ?? base`, i.e. a failed render hands
    /// back a CLEAN base image and silently drops every redaction.
    ///
    /// Returns nil when the destination cannot be built within `budgetBytes`;
    /// callers must keep the session open and surface the failure.
    static func checkedRender(
        base: CGImage, annotations: [Annotation],
        pixellated: CGImage?, budgetBytes: Int
    ) -> CGImage? {
        nil // RED
    }

    /// 256 MP * 4 bytes, matching slice A's resize cap.
    static let defaultBudgetBytes = 256 * 1_000_000 * 4
}

// MARK: - Backdrop

enum BackdropPreset: String, CaseIterable {
    case none, ocean, sunset, mint, graphite
}

enum SliceBBackdrop {
    static let paddingFraction: CGFloat = 0.06
    static let minPadding: CGFloat = 40
    /// A 40 000 px scrolling capture would otherwise get 2 400 px of padding.
    static let maxPadding: CGFloat = 320

    static func padding(forLongEdge edge: CGFloat) -> CGFloat {
        0 // RED
    }

    /// `.none` must be byte-identical to the input; anything over budget fails
    /// closed instead of allocating.
    static func compose(
        image: CGImage, preset: BackdropPreset, budgetBytes: Int
    ) -> CGImage? {
        nil // RED
    }
}
