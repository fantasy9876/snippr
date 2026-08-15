import Foundation

/// Pure geometry shared by the area-review toolbar and scrolling-result
/// panel.  It deliberately knows nothing about NSView/NSButton so the exact
/// production layout can be exercised by headless self-tests.
enum OverlayToolbarLayout {
    struct Metrics {
        var buttonSize = CGSize(width: 34, height: 30)
        var spacing: CGFloat = 2
        var padding: CGFloat = 6
        /// Clearance from the selection and from the overlay's outer edge.
        /// The resize hit target is 18pt, so 10pt leaves a one-point gap when
        /// a toolbar has to fall back inside a full-frame selection.
        var gap: CGFloat = 10
        /// A tiny selection still exposes a useful compact grid instead of a
        /// pathological one-button-per-row/column strip.
        var minimumPrimaryItems = 3

        static let standard = Metrics()
    }

    enum Flow: Equatable {
        /// Left-to-right, then wrap into additional rows.
        case horizontal
        /// Top-to-bottom, then wrap into additional columns.
        case vertical
    }

    struct Grid {
        let size: CGSize
        /// Frames are local to a container whose origin is (0, 0).
        let buttonFrames: [CGRect]
        let rows: Int
        let columns: Int
    }

    enum ToolPlacement: Equatable {
        case right
        case left
        case insideRight
        case insideLeft
    }

    enum ActionPlacement: Equatable {
        case below
        case above
        case insideBottom
        case insideTop
    }

    private struct ToolCandidate {
        let frame: CGRect
        let placement: ToolPlacement
        let score: Int
        let order: Int
    }

    private struct ActionCandidate {
        let frame: CGRect
        let placement: ActionPlacement
        let score: Int
        let order: Int
    }

    struct Area {
        let toolFrame: CGRect
        let actionFrame: CGRect
        let toolButtonFramesLocal: [CGRect]
        let actionButtonFramesLocal: [CGRect]
        /// Frames converted into the same coordinate space as `bounds` and
        /// `selection`.
        let toolButtonFrames: [CGRect]
        let actionButtonFrames: [CGRect]
        let toolRows: Int
        let toolColumns: Int
        let actionRows: Int
        let actionColumns: Int
        let toolPlacement: ToolPlacement
        let actionPlacement: ActionPlacement
    }

    struct Panel {
        /// The bar is allowed to be wider than the buttons' natural grid so a
        /// fitted image and its toolbar retain one shared content width.
        let size: CGSize
        let buttonFrames: [CGRect]
        let rows: Int
        let columns: Int
    }

    /// Returns the smallest primary-axis span that holds `itemCount` buttons.
    static func primarySpan(
        for flow: Flow,
        itemCount: Int,
        metrics: Metrics = .standard
    ) -> CGFloat {
        let count = max(1, itemCount)
        let item = flow == .horizontal
            ? metrics.buttonSize.width : metrics.buttonSize.height
        return metrics.padding * 2
            + CGFloat(count) * item
            + CGFloat(max(0, count - 1)) * metrics.spacing
    }

    /// Wraps fixed-size buttons without scaling them. Horizontal grids are
    /// row-major; vertical grids are column-major. In both cases index zero is
    /// visually at the top-left (AppKit's bottom-left coordinates are handled
    /// by inverting the row while producing frames).
    static func grid(
        itemCount: Int,
        flow: Flow,
        maxPrimarySpan: CGFloat,
        metrics: Metrics = .standard
    ) -> Grid {
        guard itemCount > 0 else {
            return Grid(size: .zero, buttonFrames: [], rows: 0, columns: 0)
        }

        let primaryItem = flow == .horizontal
            ? metrics.buttonSize.width : metrics.buttonSize.height
        let usable = maxPrimarySpan - metrics.padding * 2 + metrics.spacing
        let fitted = Int(floor(usable / (primaryItem + metrics.spacing)))
        let primarySlots = min(itemCount, max(1, fitted))

        let rows: Int
        let columns: Int
        switch flow {
        case .horizontal:
            columns = primarySlots
            rows = (itemCount + columns - 1) / columns
        case .vertical:
            rows = primarySlots
            columns = (itemCount + rows - 1) / rows
        }

        let width = metrics.padding * 2
            + CGFloat(columns) * metrics.buttonSize.width
            + CGFloat(max(0, columns - 1)) * metrics.spacing
        let height = metrics.padding * 2
            + CGFloat(rows) * metrics.buttonSize.height
            + CGFloat(max(0, rows - 1)) * metrics.spacing

        var frames: [CGRect] = []
        frames.reserveCapacity(itemCount)
        for index in 0..<itemCount {
            let row: Int
            let column: Int
            switch flow {
            case .horizontal:
                row = index / columns
                column = index % columns
            case .vertical:
                row = index % rows
                column = index / rows
            }
            let visualRowFromBottom = rows - 1 - row
            frames.append(CGRect(
                x: metrics.padding
                    + CGFloat(column)
                        * (metrics.buttonSize.width + metrics.spacing),
                y: metrics.padding
                    + CGFloat(visualRowFromBottom)
                        * (metrics.buttonSize.height + metrics.spacing),
                width: metrics.buttonSize.width,
                height: metrics.buttonSize.height))
        }

        return Grid(
            size: CGSize(width: width, height: height),
            buttonFrames: frames, rows: rows, columns: columns)
    }

    /// Area-review layout: annotation controls form a vertical rail and
    /// terminal actions form a horizontal strip. The preferred pair is
    /// outside-right + below; each axis flips independently, then falls back
    /// inside the selection. Returns nil only when the overlay bounds are too
    /// small to hold the fixed-size controls without violating the collision
    /// invariants.
    static func area(
        selection rawSelection: CGRect,
        bounds rawBounds: CGRect,
        toolCount: Int,
        actionCount: Int,
        handleHitSize: CGFloat = 18,
        metrics: Metrics = .standard
    ) -> Area? {
        let bounds = rawBounds.standardized
        let selection = rawSelection.standardized.intersection(bounds)
        guard toolCount > 0, actionCount > 0,
              !selection.isNull, selection.width > 0, selection.height > 0,
              bounds.width > metrics.gap * 2,
              bounds.height > metrics.gap * 2
        else { return nil }

        let safeBounds = bounds.insetBy(dx: metrics.gap, dy: metrics.gap)
        let minimumToolSpan = primarySpan(
            for: .vertical,
            itemCount: min(toolCount, max(1, metrics.minimumPrimaryItems)),
            metrics: metrics)
        let minimumActionSpan = primarySpan(
            for: .horizontal,
            itemCount: min(actionCount, max(1, metrics.minimumPrimaryItems)),
            metrics: metrics)
        let toolPrimarySpan = min(
            safeBounds.height,
            max(selection.height, minimumToolSpan))
        let actionPrimarySpan = min(
            safeBounds.width,
            max(selection.width, minimumActionSpan))

        let toolGrid = grid(
            itemCount: toolCount, flow: .vertical,
            maxPrimarySpan: toolPrimarySpan, metrics: metrics)
        let actionGrid = grid(
            itemCount: actionCount, flow: .horizontal,
            maxPrimarySpan: actionPrimarySpan, metrics: metrics)
        guard toolGrid.size.width <= safeBounds.width,
              toolGrid.size.height <= safeBounds.height,
              actionGrid.size.width <= safeBounds.width,
              actionGrid.size.height <= safeBounds.height
        else { return nil }

        func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            min(high, max(low, value))
        }
        func unique(_ values: [(CGFloat, Int)]) -> [(CGFloat, Int)] {
            var result: [(CGFloat, Int)] = []
            for value in values where !result.contains(where: {
                abs($0.0 - value.0) < 0.001
            }) {
                result.append(value)
            }
            return result
        }

        let toolYLow = safeBounds.minY
        let toolYHigh = safeBounds.maxY - toolGrid.size.height
        let toolYs = unique([
            (clamp(selection.maxY - toolGrid.size.height,
                   low: toolYLow, high: toolYHigh), 0),
            (clamp(selection.minY,
                   low: toolYLow, high: toolYHigh), 1),
            (clamp(selection.midY - toolGrid.size.height / 2,
                   low: toolYLow, high: toolYHigh), 2),
            // Keep both groups local when their preferred outside frames
            // would intersect at a tiny corner: the rail may sit immediately
            // above/below the action strip before either group teleports to
            // the opposite screen edge.
            (clamp(
                selection.maxY + metrics.gap
                    + actionGrid.size.height + metrics.gap,
                low: toolYLow, high: toolYHigh), 5),
            (clamp(
                selection.minY - metrics.gap
                    - actionGrid.size.height - metrics.gap
                    - toolGrid.size.height,
                low: toolYLow, high: toolYHigh), 6),
            // Extreme alignments are last-resort collision escapes for tiny
            // selections in a screen corner. They keep the rail on the chosen
            // horizontal side without forcing it to overlap the action strip.
            (toolYHigh, 100),
            (toolYLow, 101),
        ])
        let toolXs: [(CGFloat, ToolPlacement, Int)] = [
            (selection.maxX + metrics.gap, .right, 0),
            (selection.minX - metrics.gap - toolGrid.size.width, .left, 10),
            (selection.maxX - metrics.gap - toolGrid.size.width,
             .insideRight, 20),
            (selection.minX + metrics.gap, .insideLeft, 30),
        ]
        var toolCandidates: [ToolCandidate] = []
        var candidateOrder = 0
        for (x, placement, sideScore) in toolXs {
            for (y, alignmentScore) in toolYs {
                let frame = CGRect(origin: CGPoint(x: x, y: y),
                                   size: toolGrid.size)
                if safeBounds.contains(frame) {
                    toolCandidates.append(ToolCandidate(
                        frame: frame, placement: placement,
                        score: sideScore + alignmentScore,
                        order: candidateOrder))
                }
                candidateOrder += 1
            }
        }

        let actionXLow = safeBounds.minX
        let actionXHigh = safeBounds.maxX - actionGrid.size.width
        let actionXs = unique([
            (clamp(selection.minX,
                   low: actionXLow, high: actionXHigh), 0),
            (clamp(selection.maxX - actionGrid.size.width,
                   low: actionXLow, high: actionXHigh), 1),
            (clamp(selection.midX - actionGrid.size.width / 2,
                   low: actionXLow, high: actionXHigh), 2),
            // Orthogonal companion to `toolYs`: keep the action strip just
            // beyond a right/left rail when both prefer the same corner.
            (clamp(
                selection.maxX + metrics.gap
                    + toolGrid.size.width + metrics.gap,
                low: actionXLow, high: actionXHigh), 5),
            (clamp(
                selection.minX - metrics.gap
                    - toolGrid.size.width - metrics.gap
                    - actionGrid.size.width,
                low: actionXLow, high: actionXHigh), 6),
            // Same corner fallback as the tool rail, along the orthogonal
            // axis: keep below/above semantics while escaping a collision.
            (actionXLow, 100),
            (actionXHigh, 101),
        ])
        let actionYs: [(CGFloat, ActionPlacement, Int)] = [
            (selection.minY - metrics.gap - actionGrid.size.height,
             .below, 0),
            (selection.maxY + metrics.gap, .above, 10),
            (selection.minY + metrics.gap, .insideBottom, 20),
            (selection.maxY - metrics.gap - actionGrid.size.height,
             .insideTop, 30),
        ]
        var actionCandidates: [ActionCandidate] = []
        candidateOrder = 0
        for (y, placement, sideScore) in actionYs {
            for (x, alignmentScore) in actionXs {
                let frame = CGRect(origin: CGPoint(x: x, y: y),
                                   size: actionGrid.size)
                if safeBounds.contains(frame) {
                    actionCandidates.append(ActionCandidate(
                        frame: frame, placement: placement,
                        score: sideScore + alignmentScore,
                        order: candidateOrder))
                }
                candidateOrder += 1
            }
        }

        let forbidden = EditableSelectionGeometry.handleRects(
            for: selection, size: handleHitSize).map { $0.1 }
        func isClear(_ frame: CGRect) -> Bool {
            !forbidden.contains(where: { frame.intersects($0) })
        }

        var best: (tool: ToolCandidate, action: ActionCandidate,
                   score: Int, order: Int)?
        for tool in toolCandidates where isClear(tool.frame) {
            for action in actionCandidates
                where isClear(action.frame)
                    && !tool.frame.intersects(action.frame) {
                let score = tool.score + action.score
                let order = tool.order * 100 + action.order
                if best == nil || score < best!.score
                    || (score == best!.score && order < best!.order) {
                    best = (tool, action, score, order)
                }
            }
        }
        guard let best else { return nil }

        func offset(_ frames: [CGRect], by origin: CGPoint) -> [CGRect] {
            frames.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        }
        return Area(
            toolFrame: best.tool.frame,
            actionFrame: best.action.frame,
            toolButtonFramesLocal: toolGrid.buttonFrames,
            actionButtonFramesLocal: actionGrid.buttonFrames,
            toolButtonFrames: offset(
                toolGrid.buttonFrames, by: best.tool.frame.origin),
            actionButtonFrames: offset(
                actionGrid.buttonFrames, by: best.action.frame.origin),
            toolRows: toolGrid.rows,
            toolColumns: toolGrid.columns,
            actionRows: actionGrid.rows,
            actionColumns: actionGrid.columns,
            toolPlacement: best.tool.placement,
            actionPlacement: best.action.placement)
    }

    /// Horizontal scrolling-panel toolbar with a dynamic row count/height.
    /// Callers choose the bounded content width first, then subtract this
    /// returned height before fitting the image vertically.
    static func panel(
        buttonCount: Int,
        availableWidth: CGFloat,
        metrics: Metrics = .standard
    ) -> Panel {
        let minimumWidth = primarySpan(
            for: .horizontal, itemCount: 1, metrics: metrics)
        let width = max(minimumWidth, availableWidth)
        let grid = grid(
            itemCount: buttonCount, flow: .horizontal,
            maxPrimarySpan: width, metrics: metrics)
        return Panel(
            size: CGSize(width: max(width, grid.size.width),
                         height: grid.size.height),
            buttonFrames: grid.buttonFrames,
            rows: grid.rows,
            columns: grid.columns)
    }
}
