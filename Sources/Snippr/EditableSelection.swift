import AppKit

/// The eight resize handles shared by the capture overlay and the editor's
/// post-capture crop tool. Coordinates follow AppKit (bottom-left origin).
enum SelectionHandle: CaseIterable {
    case bottomLeft, bottom, bottomRight
    case left, right
    case topLeft, top, topRight

    private var isLeft: Bool {
        self == .bottomLeft || self == .left || self == .topLeft
    }

    private var isRight: Bool {
        self == .bottomRight || self == .right || self == .topRight
    }

    private var isBottom: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }

    private var isTop: Bool {
        self == .topLeft || self == .top || self == .topRight
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .bottom, .top: return .resizeUpDown
        case .bottomLeft, .bottomRight, .topLeft, .topRight: return .crosshair
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        let x = isLeft ? rect.minX : (isRight ? rect.maxX : rect.midX)
        let y = isBottom ? rect.minY : (isTop ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }
}

/// Pure selection geometry, kept out of the event handlers so the exact same
/// clamping and handle behavior is used before and after a screenshot is made.
enum EditableSelectionGeometry {
    static func clampedPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.maxX, max(bounds.minX, point.x)),
            y: min(bounds.maxY, max(bounds.minY, point.y))
        )
    }

    static func rect(from anchor: CGPoint, to point: CGPoint, within bounds: CGRect) -> CGRect {
        let a = clampedPoint(anchor, to: bounds)
        let b = clampedPoint(point, to: bounds)
        return CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    /// Inset of a corner handle onto the 45° point of a rounded plate:
    /// `d = R × (1 − 1/√2)`. Radius 0 is the geometric corner. Same table
    /// as Windows `OverlayToolbarLayout.HandleRects`.
    static func cornerInset(forRadius radius: CGFloat) -> CGFloat {
        radius > 0 ? radius * (1 - 1 / CGFloat(2).squareRoot()) : 0
    }

    /// The grab/draw centre. Mid-edge handles never move; corners move
    /// inward along the plate arc when `cornerRadius > 0`.
    static func handlePoint(
        _ handle: SelectionHandle, in rect: CGRect, cornerRadius: CGFloat = 0
    ) -> CGPoint {
        let d = cornerInset(forRadius: cornerRadius)
        var point = handle.point(in: rect)
        switch handle {
        case .bottomLeft: point.x += d; point.y += d
        case .topLeft: point.x += d; point.y -= d
        case .bottomRight: point.x -= d; point.y += d
        case .topRight: point.x -= d; point.y -= d
        default: break
        }
        return point
    }

    static func handle(
        at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 9,
        cornerRadius: CGFloat = 0
    ) -> SelectionHandle? {
        // Corners take priority when a selection is small and hit targets overlap.
        let priority: [SelectionHandle] = [
            .bottomLeft, .bottomRight, .topLeft, .topRight,
            .bottom, .top, .left, .right,
        ]
        return priority.first { handle in
            let p = handlePoint(handle, in: rect, cornerRadius: cornerRadius)
            return abs(point.x - p.x) <= tolerance && abs(point.y - p.y) <= tolerance
        }
    }

    static func moved(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        let rect = rect.standardized
        guard rect.width <= bounds.width, rect.height <= bounds.height else { return bounds }
        return CGRect(
            x: min(bounds.maxX - rect.width, max(bounds.minX, rect.minX + delta.x)),
            y: min(bounds.maxY - rect.height, max(bounds.minY, rect.minY + delta.y)),
            width: rect.width,
            height: rect.height
        )
    }

    static func resized(
        _ rect: CGRect,
        using handle: SelectionHandle,
        to point: CGPoint,
        within bounds: CGRect,
        minimumSize: CGFloat = 4
    ) -> CGRect {
        let point = clampedPoint(point, to: bounds)
        var left = rect.minX
        var right = rect.maxX
        var bottom = rect.minY
        var top = rect.maxY

        switch handle {
        case .bottomLeft, .left, .topLeft:
            left = min(point.x, right - minimumSize)
        default: break
        }
        switch handle {
        case .bottomRight, .right, .topRight:
            right = max(point.x, left + minimumSize)
        default: break
        }
        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            bottom = min(point.y, top - minimumSize)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            top = max(point.y, bottom + minimumSize)
        default: break
        }

        left = max(bounds.minX, left)
        right = min(bounds.maxX, right)
        bottom = max(bounds.minY, bottom)
        top = min(bounds.maxY, top)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// Eight crop handles. `cornerRadius` 0 (preset none, or style None)
    /// is bit-identical to the geometric corners. A positive radius moves
    /// only the corner centres onto the 45° point of the plate arc so a
    /// square handle does not sit on the cut and read as a square corner.
    ///
    /// `shrinkToArc` is the drawn corner square only: if half its side
    /// would still cover the geometric corner, that square shrinks to
    /// `2d` (floor 5). Mid-edge squares stay at `size`. Hit-testing keeps
    /// the 18 pt size at the same centres — pass `false` (the default)
    /// there. Overlay toolbar layout does not pass a radius: the rail
    /// still avoids the geometric corners.
    static func handleRects(
        for rect: CGRect, size: CGFloat = 7,
        cornerRadius: CGFloat = 0, shrinkToArc: Bool = false
    ) -> [(SelectionHandle, CGRect)] {
        let d = cornerInset(forRadius: cornerRadius)
        var cornerSize = size
        if shrinkToArc, d > 0, size / 2 > d {
            cornerSize = max(5, 2 * d)
        }
        return SelectionHandle.allCases.map { handle in
            let point = handlePoint(handle, in: rect, cornerRadius: cornerRadius)
            let side: CGFloat
            switch handle {
            case .bottomLeft, .bottomRight, .topLeft, .topRight:
                side = cornerSize
            default:
                side = size
            }
            return (handle, CGRect(
                x: point.x - side / 2, y: point.y - side / 2,
                width: side, height: side
            ))
        }
    }

    /// Converts an AppKit-view crop (bottom-left origin, points) to the pixel
    /// rectangle expected by `CGImage.cropping` (top-left origin).
    static func pixelCropRect(for viewRect: CGRect, in canvasBounds: CGRect, scale: CGFloat) -> CGRect {
        let rect = viewRect.intersection(canvasBounds)
        guard !rect.isNull else { return .null }
        return CGRect(
            x: (rect.minX - canvasBounds.minX) * scale,
            y: (canvasBounds.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    /// Origin of an integral Core Graphics crop expressed in the annotation
    /// model's bottom-left pixel coordinates.
    static func annotationOffset(forPixelCrop crop: CGRect, imageHeight: CGFloat) -> CGPoint {
        CGPoint(x: crop.minX, y: imageHeight - crop.maxY)
    }
}
