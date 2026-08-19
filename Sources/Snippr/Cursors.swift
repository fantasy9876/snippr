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
    case resize(SelectionHandle)

    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .iBeam: return .iBeam
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
