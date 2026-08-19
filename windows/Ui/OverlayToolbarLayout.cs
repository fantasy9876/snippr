using System.Drawing;

namespace Snippr;

/// Pure geometry for the overlay rail + strip. Port of
/// <c>Sources/Snippr/OverlayToolbarLayout.swift</c> into GDI+ Y-down.
/// No WinForms types — Honey's ParityGate can compile this file as-is.
static class OverlayToolbarLayout
{
    public readonly record struct Metrics(
        float ButtonWidth,
        float ButtonHeight,
        float Spacing,
        float Padding,
        float Gap,
        int MinimumPrimaryItems)
    {
        public static Metrics Standard { get; } = new(34, 30, 2, 6, 10, 3);

        public SizeF ButtonSize => new(ButtonWidth, ButtonHeight);

        public Metrics Scaled(float scale) => new(
            MathF.Round(ButtonWidth * scale),
            MathF.Round(ButtonHeight * scale),
            MathF.Round(Spacing * scale),
            MathF.Round(Padding * scale),
            MathF.Round(Gap * scale),
            MinimumPrimaryItems);
    }

    public enum Flow { Horizontal, Vertical }

    public enum ToolPlacement { Right, Left, InsideRight, InsideLeft }

    public enum ActionPlacement { Below, Above, InsideBottom, InsideTop }

    public readonly record struct Grid(
        SizeF Size,
        RectangleF[] ButtonFrames,
        int Rows,
        int Columns);

    public readonly record struct Area(
        RectangleF ToolFrame,
        RectangleF ActionFrame,
        RectangleF[] ToolButtonFramesLocal,
        RectangleF[] ActionButtonFramesLocal,
        RectangleF[] ToolButtonFrames,
        RectangleF[] ActionButtonFrames,
        int ToolRows,
        int ToolColumns,
        int ActionRows,
        int ActionColumns,
        ToolPlacement ToolPlacement,
        ActionPlacement ActionPlacement);

    public static float PrimarySpan(Flow flow, int itemCount, Metrics metrics)
    {
        int count = Math.Max(1, itemCount);
        float item = flow == Flow.Horizontal ? metrics.ButtonWidth : metrics.ButtonHeight;
        return metrics.Padding * 2
            + count * item
            + Math.Max(0, count - 1) * metrics.Spacing;
    }

    public static Grid ComputeGrid(int itemCount, Flow flow, float maxPrimarySpan, Metrics metrics)
    {
        if (itemCount <= 0)
            return new Grid(SizeF.Empty, [], 0, 0);

        float primaryItem = flow == Flow.Horizontal ? metrics.ButtonWidth : metrics.ButtonHeight;
        float usable = maxPrimarySpan - metrics.Padding * 2 + metrics.Spacing;
        int fitted = (int)MathF.Floor(usable / (primaryItem + metrics.Spacing));
        int primarySlots = Math.Min(itemCount, Math.Max(1, fitted));

        int rows, columns;
        if (flow == Flow.Horizontal)
        {
            columns = primarySlots;
            rows = (itemCount + columns - 1) / columns;
        }
        else
        {
            rows = primarySlots;
            columns = (itemCount + rows - 1) / rows;
        }

        float width = metrics.Padding * 2
            + columns * metrics.ButtonWidth
            + Math.Max(0, columns - 1) * metrics.Spacing;
        float height = metrics.Padding * 2
            + rows * metrics.ButtonHeight
            + Math.Max(0, rows - 1) * metrics.Spacing;

        var frames = new RectangleF[itemCount];
        for (int i = 0; i < itemCount; i++)
        {
            int row, column;
            if (flow == Flow.Horizontal)
            {
                row = i / columns;
                column = i % columns;
            }
            else
            {
                row = i % rows;
                column = i / rows;
            }
            // Y-down: row 0 is the visual top. The Swift port inverts the row
            // because AppKit's origin is bottom-left.
            frames[i] = new RectangleF(
                metrics.Padding + column * (metrics.ButtonWidth + metrics.Spacing),
                metrics.Padding + row * (metrics.ButtonHeight + metrics.Spacing),
                metrics.ButtonWidth,
                metrics.ButtonHeight);
        }

        return new Grid(new SizeF(width, height), frames, rows, columns);
    }

    public static Area? Compute(
        RectangleF selection,
        RectangleF bounds,
        int toolCount,
        int actionCount,
        float handleHitSize = 18,
        Metrics? metrics = null)
    {
        var m = metrics ?? Metrics.Standard;
        bounds = Norm(bounds);
        selection = RectangleF.Intersect(Norm(selection), bounds);
        if (toolCount <= 0 || actionCount <= 0
            || selection.Width <= 0 || selection.Height <= 0
            || bounds.Width <= m.Gap * 2 || bounds.Height <= m.Gap * 2)
            return null;

        var safe = Inset(bounds, m.Gap);
        float minToolSpan = PrimarySpan(
            Flow.Vertical,
            Math.Min(toolCount, Math.Max(1, m.MinimumPrimaryItems)),
            m);
        float minActionSpan = PrimarySpan(
            Flow.Horizontal,
            Math.Min(actionCount, Math.Max(1, m.MinimumPrimaryItems)),
            m);
        float toolPrimary = Math.Min(safe.Height, Math.Max(selection.Height, minToolSpan));
        float actionPrimary = Math.Min(safe.Width, Math.Max(selection.Width, minActionSpan));

        var toolGrid = ComputeGrid(toolCount, Flow.Vertical, toolPrimary, m);
        var actionGrid = ComputeGrid(actionCount, Flow.Horizontal, actionPrimary, m);
        if (toolGrid.Size.Width > safe.Width || toolGrid.Size.Height > safe.Height
            || actionGrid.Size.Width > safe.Width || actionGrid.Size.Height > safe.Height)
            return null;

        float toolYLow = safe.Top;
        float toolYHigh = safe.Bottom - toolGrid.Size.Height;
        var toolYs = Unique(
        [
            (Clamp(selection.Top, toolYLow, toolYHigh), 0),
            (Clamp(selection.Bottom - toolGrid.Size.Height, toolYLow, toolYHigh), 1),
            (Clamp(selection.Top + selection.Height / 2f - toolGrid.Size.Height / 2f,
                toolYLow, toolYHigh), 2),
            (Clamp(
                selection.Top - m.Gap - actionGrid.Size.Height - m.Gap - toolGrid.Size.Height,
                toolYLow, toolYHigh), 5),
            (Clamp(
                selection.Bottom + m.Gap + actionGrid.Size.Height + m.Gap,
                toolYLow, toolYHigh), 6),
            (toolYHigh, 100),
            (toolYLow, 101),
        ]);

        (float X, ToolPlacement Place, int Score)[] toolXs =
        [
            (selection.Right + m.Gap, ToolPlacement.Right, 0),
            (selection.Left - m.Gap - toolGrid.Size.Width, ToolPlacement.Left, 10),
            (selection.Right - m.Gap - toolGrid.Size.Width, ToolPlacement.InsideRight, 20),
            (selection.Left + m.Gap, ToolPlacement.InsideLeft, 30),
        ];

        var toolCandidates = new List<(RectangleF Frame, ToolPlacement Place, int Score, int Order)>();
        int order = 0;
        foreach (var (x, place, side) in toolXs)
        {
            foreach (var (y, align) in toolYs)
            {
                var frame = new RectangleF(x, y, toolGrid.Size.Width, toolGrid.Size.Height);
                if (Contains(safe, frame))
                    toolCandidates.Add((frame, place, side + align, order));
                order++;
            }
        }

        float actionXLow = safe.Left;
        float actionXHigh = safe.Right - actionGrid.Size.Width;
        var actionXs = Unique(
        [
            (Clamp(selection.Left, actionXLow, actionXHigh), 0),
            (Clamp(selection.Right - actionGrid.Size.Width, actionXLow, actionXHigh), 1),
            (Clamp(selection.Left + selection.Width / 2f - actionGrid.Size.Width / 2f,
                actionXLow, actionXHigh), 2),
            (Clamp(
                selection.Right + m.Gap + toolGrid.Size.Width + m.Gap,
                actionXLow, actionXHigh), 5),
            (Clamp(
                selection.Left - m.Gap - toolGrid.Size.Width - m.Gap - actionGrid.Size.Width,
                actionXLow, actionXHigh), 6),
            (actionXLow, 100),
            (actionXHigh, 101),
        ]);

        (float Y, ActionPlacement Place, int Score)[] actionYs =
        [
            (selection.Bottom + m.Gap, ActionPlacement.Below, 0),
            (selection.Top - m.Gap - actionGrid.Size.Height, ActionPlacement.Above, 10),
            (selection.Bottom - m.Gap - actionGrid.Size.Height, ActionPlacement.InsideBottom, 20),
            (selection.Top + m.Gap, ActionPlacement.InsideTop, 30),
        ];

        var actionCandidates = new List<(RectangleF Frame, ActionPlacement Place, int Score, int Order)>();
        order = 0;
        foreach (var (y, place, side) in actionYs)
        {
            foreach (var (x, align) in actionXs)
            {
                var frame = new RectangleF(x, y, actionGrid.Size.Width, actionGrid.Size.Height);
                if (Contains(safe, frame))
                    actionCandidates.Add((frame, place, side + align, order));
                order++;
            }
        }

        var forbidden = HandleRects(selection, handleHitSize);
        bool Clear(RectangleF frame)
        {
            foreach (var h in forbidden)
                if (Overlaps(frame, h)) return false;
            return true;
        }

        (RectangleF Frame, ToolPlacement Place, int Score, int Order)? bestTool = null;
        (RectangleF Frame, ActionPlacement Place, int Score, int Order)? bestAction = null;
        int bestScore = int.MaxValue;
        int bestOrder = int.MaxValue;
        foreach (var tool in toolCandidates)
        {
            if (!Clear(tool.Frame)) continue;
            foreach (var action in actionCandidates)
            {
                if (!Clear(action.Frame) || Overlaps(tool.Frame, action.Frame)) continue;
                int score = tool.Score + action.Score;
                int pairOrder = tool.Order * 100 + action.Order;
                if (score < bestScore || (score == bestScore && pairOrder < bestOrder))
                {
                    bestTool = tool;
                    bestAction = action;
                    bestScore = score;
                    bestOrder = pairOrder;
                }
            }
        }

        if (bestTool is null || bestAction is null) return null;

        var toolOrigin = bestTool.Value.Frame.Location;
        var actionOrigin = bestAction.Value.Frame.Location;
        return new Area(
            bestTool.Value.Frame,
            bestAction.Value.Frame,
            toolGrid.ButtonFrames,
            actionGrid.ButtonFrames,
            Offset(toolGrid.ButtonFrames, toolOrigin),
            Offset(actionGrid.ButtonFrames, actionOrigin),
            toolGrid.Rows,
            toolGrid.Columns,
            actionGrid.Rows,
            actionGrid.Columns,
            bestTool.Value.Place,
            bestAction.Value.Place);
    }

    /// Assertions for `win-overlay-toolbar-layout`. Honey includes this file
    /// in ParityGate and returns the list — empty means PASS.
    public static List<string> GateFixtures(int toolCount = 12, int actionCount = 11)
    {
        var failures = new List<string>();
        (float W, float H)[] screens = [(1920, 1080), (2560, 1440)];
        float[] scales = [1f, 1.25f];
        foreach (var (sw, sh) in screens)
        foreach (var scale in scales)
        {
            var metrics = Metrics.Standard.Scaled(scale);
            float handle = MathF.Round(18 * scale);
            var screen = new RectangleF(0, 0, sw, sh);
            RectangleF[] selections =
            [
                new((sw - 80) / 2f, (sh - 40) / 2f, 80, 40),
                new((sw - 300) / 2f, (sh - 200) / 2f, 300, 200),
                screen,
            ];
            foreach (var sel in selections)
            {
                string tag = $"{sw}x{sh}@{scale:0.##} sel={sel.Width}x{sel.Height}";
                var area = Compute(sel, screen, toolCount, actionCount, handle, metrics);
                if (area is null)
                {
                    failures.Add($"{tag}: layout null");
                    continue;
                }
                if (!Contains(screen, area.Value.ToolFrame)
                    || !Contains(screen, area.Value.ActionFrame))
                    failures.Add($"{tag}: panel outside screen");
                if (area.Value.ToolButtonFrames.Length != toolCount
                    || area.Value.ActionButtonFrames.Length != actionCount)
                    failures.Add($"{tag}: missing buttons");
                foreach (var b in area.Value.ToolButtonFrames)
                    if (!Contains(screen, b))
                        failures.Add($"{tag}: tool button {b} outside screen");
                foreach (var b in area.Value.ActionButtonFrames)
                    if (!Contains(screen, b))
                        failures.Add($"{tag}: action button {b} outside screen");
                if (Overlaps(area.Value.ToolFrame, area.Value.ActionFrame))
                    failures.Add($"{tag}: rail overlaps strip");
                bool full = Math.Abs(sel.Width - screen.Width) < 0.5f
                    && Math.Abs(sel.Height - screen.Height) < 0.5f;
                if (!full
                    && (Overlaps(area.Value.ToolFrame, sel)
                        || Overlaps(area.Value.ActionFrame, sel)))
                    failures.Add($"{tag}: overlapped selection with room outside");
            }
        }
        return failures;
    }

    /// Eight crop handles: four corners, four edge midpoints, same order as
    /// <c>CropGrip</c>. <paramref name="cornerRadius"/> 0 (preset none, or
    /// style None) is bit-identical to the geometric corners. A positive
    /// radius moves only the corner centres onto the 45° point of the plate
    /// arc — <c>d = R × (1 − 1/√2)</c> — so a square handle does not sit on
    /// the cut and read as a square corner. Mid-edge handles stay put.
    ///
    /// <paramref name="shrinkToArc"/> is the drawn corner square only: if
    /// half its side would still cover the geometric corner, that square
    /// shrinks to <c>2d</c> (floor 5). Mid-edge squares stay at
    /// <paramref name="size"/>. Hit-testing keeps the 18 DIP size at the
    /// same centres — pass <c>false</c> (the default) there. Overlay
    /// <see cref="Compute"/> does not pass a radius: the rail still avoids
    /// the geometric corners.
    public static RectangleF[] HandleRects(
        RectangleF selection, float size, float cornerRadius = 0, bool shrinkToArc = false)
    {
        float d = cornerRadius > 0
            ? cornerRadius * (1f - 1f / MathF.Sqrt(2f))
            : 0f;
        float cornerSize = size;
        if (shrinkToArc && d > 0 && size / 2f > d)
            cornerSize = MathF.Max(5f, 2f * d);
        (float X, float Y, float Size)[] pts =
        [
            (selection.Left + d, selection.Top + d, cornerSize),
            (selection.Left + selection.Width / 2f, selection.Top, size),
            (selection.Right - d, selection.Top + d, cornerSize),
            (selection.Left, selection.Top + selection.Height / 2f, size),
            (selection.Right, selection.Top + selection.Height / 2f, size),
            (selection.Left + d, selection.Bottom - d, cornerSize),
            (selection.Left + selection.Width / 2f, selection.Bottom, size),
            (selection.Right - d, selection.Bottom - d, cornerSize),
        ];
        var rects = new RectangleF[pts.Length];
        for (int i = 0; i < pts.Length; i++)
        {
            float s = pts[i].Size;
            float hx = s / 2f;
            rects[i] = new RectangleF(pts[i].X - hx, pts[i].Y - hx, s, s);
        }
        return rects;
    }

    static RectangleF[] Offset(RectangleF[] frames, PointF origin)
    {
        var copy = new RectangleF[frames.Length];
        for (int i = 0; i < frames.Length; i++)
        {
            var f = frames[i];
            copy[i] = new RectangleF(f.X + origin.X, f.Y + origin.Y, f.Width, f.Height);
        }
        return copy;
    }

    static RectangleF Norm(RectangleF r)
    {
        if (r.Width < 0) { r.X += r.Width; r.Width = -r.Width; }
        if (r.Height < 0) { r.Y += r.Height; r.Height = -r.Height; }
        return r;
    }

    static RectangleF Inset(RectangleF r, float gap) =>
        new(r.X + gap, r.Y + gap, r.Width - gap * 2, r.Height - gap * 2);

    static bool Contains(RectangleF outer, RectangleF inner) =>
        inner.Left >= outer.Left - 0.001f
        && inner.Top >= outer.Top - 0.001f
        && inner.Right <= outer.Right + 0.001f
        && inner.Bottom <= outer.Bottom + 0.001f;

    /// Touching edges do not count — matches CGRectIntersectsRect.
    static bool Overlaps(RectangleF a, RectangleF b) =>
        a.Left < b.Right && a.Right > b.Left && a.Top < b.Bottom && a.Bottom > b.Top;

    static float Clamp(float v, float lo, float hi) => Math.Min(hi, Math.Max(lo, v));

    static List<(float V, int Score)> Unique((float V, int Score)[] values)
    {
        var result = new List<(float, int)>();
        foreach (var value in values)
        {
            bool seen = false;
            foreach (var existing in result)
            {
                if (Math.Abs(existing.Item1 - value.V) < 0.001f) { seen = true; break; }
            }
            if (!seen) result.Add(value);
        }
        return result;
    }
}
