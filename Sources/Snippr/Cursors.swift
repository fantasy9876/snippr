import AppKit

/// The pointer vocabulary every drawing surface shares.
///
/// A host derives a case from **(tool, hit)** and sets `cursor`; it never
/// reaches for an `NSCursor` in an event handler. Deriving first and setting
/// once is what lets a gate read back the same value production put on
/// screen — the bug this exists to prevent was a tool-agnostic `.openHand`
/// that made a pen, a highlighter and the move tool all look like the move
/// tool while the click did something else entirely.
enum AppCursor: Equatable {
    case arrow
    case crosshair
    case openHand
    case closedHand
    case iBeam
    case pointingHand
    case resize(SelectionHandle)

    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .iBeam: return .iBeam
        case .pointingHand: return .pointingHand
        case .resize(let handle): return handle.cursor
        }
    }

    /// What an ACTIVE drawing tool means over the canvas: text types, every
    /// other tool draws. `.select` is deliberately not answered here — under
    /// it a hit means "grab this", which only the host can decide — so
    /// callers must branch on `.select` before asking.
    static func drawing(_ tool: OverlayAnnotationTool) -> AppCursor {
        tool == .text ? .iBeam : .crosshair
    }
}

/// One rectangle of a surface and what the pointer means over it, in the
/// coordinates of whoever produced it.
typealias CursorRegion = (rect: CGRect, cursor: AppCursor)

/// Chrome that floats ON a drawing surface — a toolbar, a mini popover, the
/// OCR result panel.
///
/// The host sets the cursor on every mouse move from its own hit table, which
/// overrides any `resetCursorRects` a subview installs. So chrome that says
/// nothing inherits the cursor of the CANVAS underneath it: an OCR panel over
/// the crop got `.openHand`, the "drag this crop" cursor, over its text and
/// its buttons alike. Chrome answers for itself here instead.
///
/// House vocabulary, so the same hit means the same thing everywhere:
/// - chrome background, and any DISABLED control → `.arrow`
/// - an enabled control you can click → `.pointingHand`
/// - selectable text → `.iBeam`
/// - the canvas itself is never chrome: it stays `.crosshair` or the tool's
protocol OverlayCursorRegions: NSView {
    /// General to specific: the host appends them in order and scans the
    /// table in reverse, so a later, smaller region wins.
    func cursorRegions() -> [CursorRegion]
}
