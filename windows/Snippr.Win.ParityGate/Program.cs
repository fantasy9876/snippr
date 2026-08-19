using System.Drawing;
using Snippr;

namespace Snippr.Tests;

/// Headless parity gate: the tables and the arithmetic behind Windows 1.2.10.
///
/// Counterpart on macOS: `Sources/Snippr/SelfTest.swift`
/// `sliceB-backdrop-presets-match-spec` (SHA 602fbc5) and the catalog/geometry
/// gates around it. Every expectation here is a LITERAL written in the gate —
/// asking `BackdropSpec` for the answer would make any table at all correct.
///
/// Runs on any OS on purpose (no GDI+): pixels are the Windows-only raster
/// gate's job, and everything below is numbers.
static class Program
{
    static int Main()
    {
        int failed = 0;
        failed += Check("win-tooltip-catalog-parity", CatalogParity());
        failed += Check("win-overlay-tool-order-matches-mac", OverlayToolOrder());
        failed += Check("win-backdrop-presets-match-spec", PresetsMatchSpec());
        failed += Check("win-backdrop-compose-geometry", ComposeGeometry());
        failed += Check("win-backdrop-undo-timeline", UndoTimeline());
        failed += Check("win-backdrop-route-table", RouteTable());
        failed += Check("win-area-review-crop-authority", CropAuthority());
        failed += Check("win-overlay-toolbar-layout", OverlayToolbarLayoutGate());
        failed += Check("win-area-review-chrome-hit-test", ChromeHitTest());
        failed += Check("win-area-review-crop-drag", CropDrag());
        failed += Check("win-area-review-handle-inset", HandleInset());
        failed += Check("win-area-review-cursor-follows-tool", CursorFollowsTool());
        failed += Check("win-editor-actions-match-catalog", EditorActionsMatchCatalog());
        failed += Check("win-backdrop-corner-radius-table", CornerRadiusTable());
        failed += Check("win-chrome-fits-at-every-dpi", ChromeFitsAtEveryDpi());
        if (pending > 0)
            Console.WriteLine($"{pending} PARITY GATE(S) PENDING — not a pass");
        Console.WriteLine(failed == 0
            ? (pending == 0 ? "ALL PARITY GATES PASSED" : "NO PARITY GATE FAILED, SOME PENDING")
            : $"{failed} PARITY GATE(S) FAILED");
        return failed == 0 ? 0 : 1;
    }

    static int pending;

    /// A gate whose subject does not exist yet. It is NOT a pass: it prints
    /// its reason and is counted, and the summary says so — but it does not
    /// fail the job, because a step that throws here would stop the gates
    /// after it from ever running. Zero pending is a release condition.
    /// The crop the review surface reports is the crop the export makes: one
    /// integral rect, clamped to the capture, never empty. A rect that is
    /// merely "close" puts the border, the toolbar and the frame in one place
    /// and the exported pixels in another.
    ///
    /// The arithmetic lives in `CropGeometry` so it can be checked here; the
    /// session that uses it needs a bitmap, so its own gate is the raster one.
    static List<string> CropAuthority()
    {
        var f = new List<string>();
        var capture = new Size(600, 500);
        var cases = new (Rectangle Proposed, Rectangle Want)[]
        {
            // ordinary
            (new Rectangle(100, 80, 200, 150), new Rectangle(100, 80, 200, 150)),
            // hanging off the right and bottom edges: clamped, not shifted
            (new Rectangle(560, 460, 100, 100), new Rectangle(560, 460, 40, 40)),
            // starting off the left/top edge
            (new Rectangle(-30, -20, 100, 90), new Rectangle(0, 0, 70, 70)),
            // degenerate: never empty, because a zero-wide crop has no export
            (new Rectangle(10, 10, 0, 0), new Rectangle(10, 10, 1, 1)),
            // entirely outside
            (new Rectangle(900, 900, 50, 50), new Rectangle(600, 500, 1, 1)),
        };
        foreach (var (proposed, want) in cases)
        {
            var got = CropGeometry.Canonical(proposed, capture);
            if (got != want) f.Add($"{proposed} -> {got} want {want}");
        }
        // Canonicalizing twice changes nothing: the rect the UI stores is
        // already the one the export uses.
        foreach (var (proposed, _) in cases)
        {
            var once = CropGeometry.Canonical(proposed, capture);
            if (CropGeometry.Canonical(once, capture) != once)
                f.Add($"not idempotent for {proposed}");
        }
        return f;
    }

    /// The toolbar fits, on every screen the plan names, for a selection of
    /// 80×40 as well as a full-screen one — and it does not sit on top of the
    /// selection while there is room beside it. The fixtures come from the UI
    /// lane's own layout code; the counts come from the catalog, so a tool
    /// added to one and not the other is caught here rather than by a user
    /// finding a button missing.
    static List<string> OverlayToolbarLayoutGate()
    {
        var f = new List<string>(
            OverlayToolbarLayout.GateFixtures(
                ToolCatalog.OverlayTools.Count(), ToolCatalog.OverlayActions.Count()));
        // The layout is asked about the catalog's real sizes above; this makes
        // the dependency explicit, so a silent default cannot stand in for it.
        if (ToolCatalog.OverlayTools.Count() != 12) f.Add("overlay tool count moved");
        if (ToolCatalog.OverlayActions.Count() != 11) f.Add("overlay action count moved");
        return f;
    }

    /// The toolbar is a transparent control over the whole screen, so every
    /// click lands on IT — including the ones meant to draw. Only the rail and
    /// the strip are chrome; everything else has to reach the picture, or the
    /// tools would be dead everywhere except inside the panels.
    static List<string> ChromeHitTest()
    {
        var f = new List<string>();
        var screen = new RectangleF(0, 0, 1920, 1080);
        var selection = new RectangleF(700, 400, 400, 300);
        var metrics = OverlayToolbarLayout.Metrics.Standard;
        var area = OverlayToolbarLayout.Compute(
            selection, screen,
            ToolCatalog.OverlayTools.Count(), ToolCatalog.OverlayActions.Count(),
            18f, metrics);
        if (area is not { } placed) { f.Add("no layout for the fixture"); return f; }

        // Inside the panels: chrome.
        foreach (var (name, frame) in new[]
        {
            ("rail", placed.ToolFrame), ("strip", placed.ActionFrame),
        })
        {
            var centre = new Point(
                (int)(frame.Left + frame.Width / 2), (int)(frame.Top + frame.Height / 2));
            if (!AreaReviewHitTest.IsChrome(centre, placed.ToolFrame, placed.ActionFrame))
                f.Add($"{name} centre is not chrome");
            if (AreaReviewHitTest.IsCanvas(
                centre, placed.ToolFrame, placed.ActionFrame,
                chromeVisible: true, dragInProgress: false))
                f.Add($"{name} centre draws");
            // …but a gesture already under way owns the mouse: the pointer
            // crossing the rail must not swallow the events that belong to it.
            if (!AreaReviewHitTest.IsCanvas(
                centre, placed.ToolFrame, placed.ActionFrame,
                chromeVisible: true, dragInProgress: true))
                f.Add($"{name} interrupts a drag");
        }

        // Inside the selection, and in the empty surround: the picture. These
        // are the clicks a swallowed event would lose.
        foreach (var (name, point) in new[]
        {
            ("selection centre", new Point(900, 550)),
            ("selection corner", new Point((int)selection.Left + 3, (int)selection.Top + 3)),
            ("far corner", new Point(5, 5)),
            ("below everything", new Point(960, 1075)),
        })
        {
            if (!AreaReviewHitTest.IsCanvas(
                point, placed.ToolFrame, placed.ActionFrame,
                chromeVisible: true, dragInProgress: false))
                f.Add($"{name} swallowed by the toolbar");
        }

        // With no chrome placed — a selection too small for a toolbar — every
        // point draws, including the ones a stale frame would have claimed.
        if (!AreaReviewHitTest.IsCanvas(
            new Point(900, 550), placed.ToolFrame, placed.ActionFrame,
            chromeVisible: false, dragInProgress: false))
            f.Add("hidden chrome still swallows");
        return f;
    }

    /// Adjusting the crop while reviewing it: every handle moves the edge it
    /// is drawn on, the body moves the whole rect, and dragging an edge past
    /// its opposite gives a normalized rect rather than a negative one.
    static List<string> CropDrag()
    {
        var f = new List<string>();
        var crop = new Rectangle(100, 80, 200, 150);

        // The hit regions come from the same helper that draws the handles, so
        // grabbing what you can see is the property under test.
        var handles = OverlayToolbarLayout.HandleRects(crop, 18f);
        for (int i = 0; i < handles.Length; i++)
        {
            var centre = new Point(
                (int)(handles[i].Left + handles[i].Width / 2),
                (int)(handles[i].Top + handles[i].Height / 2));
            var grip = AreaReviewCrop.GripAt(centre, crop, 18f);
            if (grip != (CropGrip)i) f.Add($"handle {i} grabs {grip}");
        }
        if (AreaReviewCrop.GripAt(new Point(200, 150), crop, 18f) != CropGrip.Inside)
            f.Add("body does not move the crop");
        if (AreaReviewCrop.GripAt(new Point(20, 20), crop, 18f) != CropGrip.None)
            f.Add("the surround grabs something");

        // Each grip moves exactly the edges it names.
        var moves = new (CropGrip Grip, Point From, Point To, Rectangle Want)[]
        {
            (CropGrip.Inside, new Point(200, 150), new Point(230, 170),
                new Rectangle(130, 100, 200, 150)),
            (CropGrip.Left, new Point(100, 150), new Point(140, 150),
                new Rectangle(140, 80, 160, 150)),
            (CropGrip.Right, new Point(300, 150), new Point(340, 155),
                new Rectangle(100, 80, 240, 150)),
            (CropGrip.Top, new Point(200, 80), new Point(200, 100),
                new Rectangle(100, 100, 200, 130)),
            (CropGrip.Bottom, new Point(200, 230), new Point(190, 200),
                new Rectangle(100, 80, 200, 120)),
            (CropGrip.TopLeft, new Point(100, 80), new Point(120, 100),
                new Rectangle(120, 100, 180, 130)),
            (CropGrip.BottomRight, new Point(300, 230), new Point(320, 250),
                new Rectangle(100, 80, 220, 170)),
            (CropGrip.TopRight, new Point(300, 80), new Point(280, 60),
                new Rectangle(100, 60, 180, 170)),
            (CropGrip.BottomLeft, new Point(100, 230), new Point(120, 210),
                new Rectangle(120, 80, 180, 130)),
        };
        foreach (var (grip, from, to, want) in moves)
        {
            var got = AreaReviewCrop.Drag(grip, crop, from, to);
            if (got != want) f.Add($"{grip}: {got} want {want}");
        }

        // Dragging an edge past its opposite normalizes instead of producing a
        // negative rect that every later intersection would silently drop.
        var flipped = AreaReviewCrop.Drag(
            CropGrip.Left, crop, new Point(100, 150), new Point(360, 150));
        if (flipped.Width <= 0 || flipped.Height <= 0 || flipped.Left != 300)
            f.Add($"flip gave {flipped}");

        // A drag reads the rect as it was when the drag STARTED, so the same
        // pointer position always gives the same answer however it got there.
        var once = AreaReviewCrop.Drag(CropGrip.Inside, crop, new Point(0, 0), new Point(40, 30));
        var twice = AreaReviewCrop.Drag(CropGrip.Inside, crop, new Point(0, 0), new Point(40, 30));
        if (once != twice) f.Add("drag is not a pure function of its endpoints");
        return f;
    }

    /// Corner handles sit on the 45° point of the plate arc so the square
    /// does not cover the cut. Radius 0 is the eight centres CropDrag already
    /// uses. Mid-edge handles never move. Hit size stays 18; shrink is the
    /// drawn square only.
    static List<string> HandleInset()
    {
        var f = new List<string>();
        var crop = new Rectangle(100, 80, 200, 150);

        var baseline = OverlayToolbarLayout.HandleRects(crop, 18f);
        var explicitZero = OverlayToolbarLayout.HandleRects(crop, 18f, 0);
        if (baseline.Length != 8) f.Add($"expected 8 handles, got {baseline.Length}");
        for (int i = 0; i < baseline.Length; i++)
            if (baseline[i] != explicitZero[i])
                f.Add($"radius 0 moved handle {i}: {explicitZero[i]} vs {baseline[i]}");

        for (int i = 0; i < baseline.Length; i++)
        {
            var c = Centre(baseline[i]);
            var centre = new Point((int)MathF.Round(c.X), (int)MathF.Round(c.Y));
            if (AreaReviewCrop.GripAt(centre, crop, 18f) != (CropGrip)i)
                f.Add($"radius 0 handle {i} no longer grabs itself");
        }

        const float radius = 37f;
        float d = radius * (1f - 1f / MathF.Sqrt(2f));
        var inset = OverlayToolbarLayout.HandleRects(crop, 18f, radius);
        int[] corners = [0, 2, 5, 7];
        int[] edges = [1, 3, 4, 6];
        foreach (int i in edges)
        {
            if (Dist(Centre(inset[i]), Centre(baseline[i])) > 0.01f)
                f.Add($"mid-edge {i} moved");
            if (Math.Abs(inset[i].Width - 18f) > 0.01f)
                f.Add($"hit handle {i} shrank to {inset[i].Width}");
        }
        (float Dx, float Dy)[] want =
        [
            (d, d), (-d, d), (d, -d), (-d, -d),
        ];
        for (int n = 0; n < corners.Length; n++)
        {
            int i = corners[n];
            var got = Centre(inset[i]);
            var expect = new PointF(
                Centre(baseline[i]).X + want[n].Dx,
                Centre(baseline[i]).Y + want[n].Dy);
            if (Dist(got, expect) > 0.01f)
                f.Add($"corner {i}: {got} want {expect}");
            if (Math.Abs(inset[i].Width - 18f) > 0.01f)
                f.Add($"hit corner {i} shrank to {inset[i].Width}");
            var gripPt = new Point((int)MathF.Round(got.X), (int)MathF.Round(got.Y));
            if (AreaReviewCrop.GripAt(gripPt, crop, 18f, radius) != (CropGrip)i)
                f.Add($"inset corner {i} does not grab itself");
            // The geometric corner is no longer the handle — it is Inside.
            var geometric = Centre(baseline[i]);
            var oldPt = new Point(
                (int)MathF.Round(geometric.X), (int)MathF.Round(geometric.Y));
            var oldGrip = AreaReviewCrop.GripAt(oldPt, crop, 18f, radius);
            if (oldGrip == (CropGrip)i)
                f.Add($"geometric corner {i} still grabs the handle");
        }

        // Drawn 8 px square on a small crop (floor 12 → d ≈ 3.51): shrink
        // so half the side does not cover the cut. Centres stay on the arc.
        const float floorR = 12f;
        float floorD = floorR * (1f - 1f / MathF.Sqrt(2f));
        var drawn = OverlayToolbarLayout.HandleRects(crop, 8f, floorR, shrinkToArc: true);
        float wantSize = MathF.Max(5f, 2f * floorD);
        foreach (int i in corners)
        {
            if (Math.Abs(drawn[i].Width - wantSize) > 0.01f)
                f.Add($"visual corner {i} size {drawn[i].Width} want {wantSize}");
            var expect = new PointF(
                Centre(baseline[i]).X + (i is 0 or 5 ? floorD : -floorD),
                Centre(baseline[i]).Y + (i is 0 or 2 ? floorD : -floorD));
            if (Dist(Centre(drawn[i]), expect) > 0.01f)
                f.Add($"visual corner {i} centre {Centre(drawn[i])} want {expect}");
        }
        foreach (int i in edges)
            if (Math.Abs(drawn[i].Width - 8f) > 0.01f)
                f.Add($"visual mid-edge {i} shrank to {drawn[i].Width}");

        // Owner-sized crop, Medium 37 px: 8/2 < d, so the square stays 8.
        var ownerCrop = new Rectangle(0, 0, 2400, 1523);
        var owner = OverlayToolbarLayout.HandleRects(
            ownerCrop, 8f, radius, shrinkToArc: true);
        foreach (int i in corners)
            if (Math.Abs(owner[i].Width - 8f) > 0.01f)
                f.Add($"owner visual {i} size {owner[i].Width} want 8");

        return f;
    }

    /// Cursor is a function of (tool, hit). Drawing tools are always Cross,
    /// text is IBeam, Select uses the grip table. Reverting SelectTool to
    /// "never set the cursor" is a smoke concern; reverting this table to
    /// "Select is SizeAll for every hit" (or drawing tools inheriting grips)
    /// is what this gate is for.
    static List<string> CursorFollowsTool()
    {
        var f = new List<string>();
        foreach (var entry in ToolCatalog.OverlayTools)
        {
            if (entry.Tool == Tool.Select || entry.Tool == Tool.Text) continue;
            foreach (var grip in Enum.GetValues<CropGrip>())
            {
                var got = AreaReviewCursor.For(entry.Tool, grip);
                if (got != ReviewCursorKind.Cross)
                    f.Add($"{entry.Tool} {grip} -> {got} want Cross");
            }
        }

        if (AreaReviewCursor.For(Tool.Text, CropGrip.Inside) != ReviewCursorKind.IBeam)
            f.Add("text inside is not IBeam");
        if (AreaReviewCursor.For(Tool.Text, CropGrip.TopLeft) != ReviewCursorKind.IBeam)
            f.Add("text handle is not IBeam");
        if (AreaReviewCursor.For(Tool.Text, CropGrip.None) != ReviewCursorKind.IBeam)
            f.Add("text outside is not IBeam");

        var select = new (CropGrip Grip, ReviewCursorKind Want)[]
        {
            (CropGrip.None, ReviewCursorKind.Cross),
            (CropGrip.Inside, ReviewCursorKind.SizeAll),
            (CropGrip.Left, ReviewCursorKind.SizeWE),
            (CropGrip.Right, ReviewCursorKind.SizeWE),
            (CropGrip.Top, ReviewCursorKind.SizeNS),
            (CropGrip.Bottom, ReviewCursorKind.SizeNS),
            (CropGrip.TopLeft, ReviewCursorKind.SizeNWSE),
            (CropGrip.BottomRight, ReviewCursorKind.SizeNWSE),
            (CropGrip.TopRight, ReviewCursorKind.SizeNESW),
            (CropGrip.BottomLeft, ReviewCursorKind.SizeNESW),
        };
        foreach (var (grip, want) in select)
        {
            var got = AreaReviewCursor.For(Tool.Select, grip);
            if (got != want) f.Add($"select {grip} -> {got} want {want}");
        }

        // Drawing tools ignore the hit: a leftover Select grip cannot stick
        // after the switch, whether the pointer is inside the crop or not.
        if (AreaReviewCursor.For(Tool.Magnifier, CropGrip.None) != ReviewCursorKind.Cross)
            f.Add("magnifier after switch is not Cross");
        if (AreaReviewCursor.For(Tool.Pen, CropGrip.Inside) != ReviewCursorKind.Cross)
            f.Add("pen over the crop is not Cross");
        return f;
    }

    static PointF Centre(RectangleF r) =>
        new(r.X + r.Width / 2f, r.Y + r.Height / 2f);

    static float Dist(PointF a, PointF b)
    {
        float dx = a.X - b.X, dy = a.Y - b.Y;
        return MathF.Sqrt(dx * dx + dy * dy);
    }

    /// Everything the catalog offers the editor, the editor does — and
    /// nothing else. The editor advertised a Backdrop button in the table for
    /// a whole release candidate while having none on screen, because the
    /// action row was hand-written and only the tool row came from the table.
    /// This is the gate that would have caught it.
    static List<string> EditorActionsMatchCatalog()
    {
        var f = new List<string>();
        foreach (var entry in ToolCatalog.EditorActions)
            if (!EditorActionRouter.IsHandled(entry.Action))
                f.Add($"{entry.Action}: offered, not handled");
        foreach (OverlayAction action in Enum.GetValues<OverlayAction>())
        {
            var offered = ToolCatalog.EditorActions.Any(a => a.Action == action);
            if (EditorActionRouter.IsHandled(action) && !offered)
                f.Add($"{action}: handled, not offered");
        }
        // Backdrop is the point of the exercise: it must be in the editor, and
        // it must do something there.
        if (!ToolCatalog.EditorActions.Any(a => a.Action == OverlayAction.Backdrop))
            f.Add("the editor lost Backdrop");
        if (!EditorActionRouter.IsHandled(OverlayAction.Backdrop))
            f.Add("Backdrop does nothing in the editor");
        // And the editor cannot open itself.
        if (EditorActionRouter.IsHandled(OverlayAction.OpenEditor))
            f.Add("the editor offers to open an editor");
        return f;
    }

    /// The corner radius, as a table written here rather than read back from
    /// the code it checks.
    ///
    /// The owner's 3671 px capture came back looking square because the radius
    /// was a fixed 12 px — 0.3% of its width. It follows the picture now, so
    /// what this pins is that it follows it by the agreed amounts, that it
    /// never eats a small crop's corner, and that None really is none.
    static List<string> CornerRadiusTable()
    {
        var f = new List<string>();
        // document short edge -> expected radius, per style
        var cases = new (int Short, int Long, float None, float Small, float Medium, float Large)[]
        {
            // the owner's capture: ~1523 short edge. 1.2/2.4/4.0% of it, all
            // still under their caps — where the old fixed 12 px sat, which is
            // why that picture read as square.
            (1523, 3285, 0, 18.276f, 36.552f, 60.92f),
            // a 1080p window
            (1080, 1920, 0, 12.96f, 25.92f, 43.2f),
            // a small crop
            (400, 800, 0, 8, 12, 16),
            // a tiny one: the floors are floors, and half the short edge caps them
            (20, 200, 0, 8, 10, 10),
        };
        foreach (var (shortEdge, longEdge, none, small, medium, large) in cases)
        {
            var document = new Size(longEdge, shortEdge);
            var want = new (BackdropCornerStyle Style, float Radius)[]
            {
                (BackdropCornerStyle.None, none),
                (BackdropCornerStyle.Small, small),
                (BackdropCornerStyle.Medium, medium),
                (BackdropCornerStyle.Large, large),
            };
            foreach (var (style, radius) in want)
            {
                var got = BackdropSpec.CornerRadius(document, style);
                if (Math.Abs(got - radius) > 0.01f)
                    f.Add($"{shortEdge}px {style}: {got} want {radius}");
            }
            // Orientation must not matter: a tall capture and a wide one with
            // the same short edge round the same amount.
            var rotated = BackdropSpec.CornerRadius(
                new Size(shortEdge, longEdge), BackdropCornerStyle.Medium);
            if (Math.Abs(rotated - medium) > 0.01f)
                f.Add($"{shortEdge}px rotated: {rotated} want {medium}");
            // And no radius may exceed half the short edge, or the plate stops
            // being a rectangle at all.
            foreach (var style in Enum.GetValues<BackdropCornerStyle>())
                if (BackdropSpec.CornerRadius(document, style) > shortEdge / 2f + 0.01f)
                    f.Add($"{shortEdge}px {style}: bigger than half the edge");
        }
        // The default is what an owner who never opens settings gets. Asked
        // through the formula rather than as `Default == Medium`: comparing two
        // constants is folded away at compile time, and a check that cannot
        // fail is not a check.
        var reference = new Size(1920, 1080);
        if (Math.Abs(
                BackdropSpec.CornerRadius(reference, BackdropSpec.DefaultCornerStyle)
                    - BackdropSpec.CornerRadius(reference, BackdropCornerStyle.Medium))
            > 0.01f)
            f.Add("the default is not Medium");
        // The old fixed radius is now the FLOOR of Medium, not the radius.
        if (BackdropSpec.CornerRadius(new Size(4000, 4000), BackdropCornerStyle.Medium)
            <= BackdropSpec.CornerRadiusPt)
            f.Add("a 4K capture still rounds like a thumbnail");
        return f;
    }

    /// The chrome fits on the displays people actually have.
    ///
    /// Every chrome constant is written in device-independent units and was
    /// used as pixels: at 150% two 35-unit rows do not fit a 70-pixel strip,
    /// the tool row is left with nothing, and with overflow off its buttons are
    /// not small — they are absent. "Ugly" and "no button works" were one
    /// cause, and no gate could see it because no gate opened a window. This
    /// one checks the arithmetic instead.
    static List<string> ChromeFitsAtEveryDpi()
    {
        var f = new List<string>();
        var actions = ToolCatalog.EditorActions.Count() + 4;
        var tools = ToolCatalog.EditorTools.Count();
        // 100%, 125%, 150%, 200% — the four Windows offers by default.
        foreach (var dpi in new[] { 96, 120, 144, 192 })
        {
            var m = EditorChromeMetrics.For(dpi, actions, tools);
            var tag = $"{dpi}dpi";
            if (m.ButtonHeight <= 0 || m.ButtonWidth <= 0)
                f.Add($"{tag}: button {m.ButtonWidth}x{m.ButtonHeight}");
            // A row must hold its button, and the chrome must hold both rows.
            if (m.RowHeight < m.ButtonHeight)
                f.Add($"{tag}: row {m.RowHeight} < button {m.ButtonHeight}");
            if (m.ChromeHeight < m.RowHeight * 2)
                f.Add($"{tag}: chrome {m.ChromeHeight} < two rows of {m.RowHeight}");
            // Everything grows WITH the display: a chrome that stays 70px on a
            // 192dpi screen is the bug this gate exists for.
            var atBase = EditorChromeMetrics.For(96, actions, tools);
            var ratio = (float)dpi / 96f;
            if (m.ChromeHeight < atBase.ChromeHeight * ratio - 2)
                f.Add($"{tag}: chrome {m.ChromeHeight} did not scale ({atBase.ChromeHeight} at 96)");
            if (m.ButtonWidth < atBase.ButtonWidth * ratio - 2)
                f.Add($"{tag}: button did not scale");
            if (m.IconSize < atBase.IconSize * ratio - 2)
                f.Add($"{tag}: icon did not scale");
            // The window may not be allowed to be narrower than its own
            // toolbar: an item that does not fit is not moved, it is gone.
            if (m.MinimumWindowWidth < m.RequiredWidth)
                f.Add($"{tag}: minimum {m.MinimumWindowWidth} < required {m.RequiredWidth}");
            // …and it still has to fit a screen. The comparison is in PHYSICAL
            // pixels on both sides: scaling the bound by the same DPI as the
            // thing being measured made a check that could never fail, which
            // is worse than no check — it reads as coverage.
            if (m.MinimumWindowWidth > 1920)
                f.Add($"{tag}: minimum {m.MinimumWindowWidth}px wider than a 1920 screen");
        }
        // And the overlay toolbar's own layout survives the same four, for the
        // smallest selection the plan names.
        foreach (var dpi in new[] { 96, 120, 144, 192 })
        {
            var scale = dpi / 96f;
            var metrics = OverlayToolbarLayout.Metrics.Standard.Scaled(scale);
            var screen = new RectangleF(0, 0, 1920, 1080);
            var selection = new RectangleF(920, 520, 80, 40);
            var area = OverlayToolbarLayout.Compute(
                selection, screen, ToolCatalog.OverlayTools.Count(),
                ToolCatalog.OverlayActions.Count(), 18 * scale, metrics);
            if (area is not { } placed) { f.Add($"{dpi}dpi: overlay layout null"); continue; }
            if (placed.ToolButtonFrames.Length != ToolCatalog.OverlayTools.Count()
                || placed.ActionButtonFrames.Length != ToolCatalog.OverlayActions.Count())
                f.Add($"{dpi}dpi: overlay dropped buttons");
            foreach (var b in placed.ToolButtonFrames.Concat(placed.ActionButtonFrames))
                if (b.Width < 1 || b.Height < 1)
                    f.Add($"{dpi}dpi: overlay button collapsed to {b.Size}");
        }
        // What does NOT fit, said out loud rather than left to a bound that
        // never bites: twenty-four buttons at 200% need more width than a
        // 1366-pixel laptop has, and the overflow chevron is what saves it.
        var smallLaptop = EditorChromeMetrics.For(192, actions, tools);
        if (smallLaptop.MinimumWindowWidth <= 1366)
            f.Add(
                "the 200% case now fits 1366px — check that overflow is still " +
                "needed, or tighten this expectation");
        return f;
    }

    static int Pend(string name, string reason)
    {
        Console.WriteLine($"PEND {name} {reason}");
        pending++;
        return 0;
    }

    static int Check(string name, List<string> failures)
    {
        if (failures.Count == 0)
        {
            Console.WriteLine($"PASS {name}");
            return 0;
        }
        Console.WriteLine($"FAIL {name} {string.Join(" | ", failures.Take(6))}");
        return 1;
    }

    // ---------- catalog ----------

    /// The review rail must read left-to-right the same as macOS's
    /// `OverlayAnnotationTool.areaReviewTools`. The owner asked for one
    /// muscle memory across platforms, and "they look the same today" is not
    /// a property any code holds — this sequence is.
    ///
    /// macOS lists `pixelateText` between blur and magnifier. Windows has no
    /// such tool, so it is absent here BY NAME: the day one is added, this
    /// gate is where the order gets decided rather than discovered.
    static List<string> OverlayToolOrder()
    {
        var f = new List<string>();
        string[] mac =
        [
            "select", "pen", "arrow", "rect", "text", "line",
            "oval", "highlight", "counter", "pixelate", "spotlight",
            "magnifier",
        ];
        var win = ToolCatalog.OverlayTools.Select(e => e.IconKey).ToArray();
        if (!win.SequenceEqual(mac))
            f.Add($"order [{string.Join(",", win)}] want [{string.Join(",", mac)}]");

        // The order list and the InOverlay flags are two statements about the
        // same thing; if they disagree a tool either never reaches the rail
        // or is looked up and is not there.
        var flagged = ToolCatalog.Entries.Where(e => e.InOverlay)
            .Select(e => e.Tool).OrderBy(t => t).ToArray();
        var ordered = ToolCatalog.OverlayOrderForTesting.OrderBy(t => t).ToArray();
        if (!flagged.SequenceEqual(ordered))
            f.Add($"order set [{string.Join(",", ordered)}] vs InOverlay [{string.Join(",", flagged)}]");
        if (ToolCatalog.OverlayOrderForTesting.Distinct().Count()
            != ToolCatalog.OverlayOrderForTesting.Count())
            f.Add("duplicate tool in overlay order");
        return f;
    }

    static List<string> CatalogParity()
    {
        var f = new List<string>();
        foreach (var e in ToolCatalog.Entries)
        {
            if (string.IsNullOrWhiteSpace(e.Name)) f.Add($"tool {e.Tool}: no name");
            if (string.IsNullOrWhiteSpace(e.IconKey)) f.Add($"tool {e.Tool}: no icon key");
            if (!e.InEditor && !e.InOverlay) f.Add($"tool {e.Tool}: in no host");
            var want = e.KeyLabel.Length == 0 ? e.Name : $"{e.Name} ({e.KeyLabel})";
            if (e.HintText != want) f.Add($"tool {e.Tool}: hint '{e.HintText}'");
        }
        foreach (var a in ToolCatalog.Actions)
        {
            if (string.IsNullOrWhiteSpace(a.Name)) f.Add($"action {a.Action}: no name");
            if (string.IsNullOrWhiteSpace(a.IconKey)) f.Add($"action {a.Action}: no icon key");
            if (!a.InEditor && !a.InOverlay) f.Add($"action {a.Action}: in no host");
            var want = a.KeyLabel.Length == 0 ? a.Name : $"{a.Name} ({a.KeyLabel})";
            if (a.HintText != want) f.Add($"action {a.Action}: hint '{a.HintText}'");
        }
        // Every tool the enum declares must be in the table: a tool with a
        // button and no catalog row is a button with no hint and no key.
        foreach (Tool tool in Enum.GetValues<Tool>())
            if (ToolCatalog.Entry(tool) is null) f.Add($"tool {tool}: missing row");
        foreach (OverlayAction action in Enum.GetValues<OverlayAction>())
            if (ToolCatalog.Entry(action) is null) f.Add($"action {action}: missing row");

        if (ToolCatalog.Entries.Select(e => e.Tool).Distinct().Count()
            != ToolCatalog.Entries.Count) f.Add("duplicate tool rows");
        if (ToolCatalog.Entries.Select(e => e.IconKey).Distinct().Count()
            != ToolCatalog.Entries.Count) f.Add("duplicate tool icon keys");
        if (ToolCatalog.Actions.Select(a => a.IconKey).Distinct().Count()
            != ToolCatalog.Actions.Count) f.Add("duplicate action icon keys");

        // Counts, as the plan freezes them: the editor keeps Crop, the review
        // surface does not (there the crop IS the selection), and only the
        // review surface can open an editor.
        var editorTools = ToolCatalog.EditorTools.Count();
        var overlayTools = ToolCatalog.OverlayTools.Count();
        var editorActions = ToolCatalog.EditorActions.Count();
        var overlayActions = ToolCatalog.OverlayActions.Count();
        if (editorTools != 13) f.Add($"editor tools {editorTools}");
        if (overlayTools != 12) f.Add($"overlay tools {overlayTools}");
        if (editorActions != 10) f.Add($"editor actions {editorActions}");
        if (overlayActions != 11) f.Add($"overlay actions {overlayActions}");
        if (ToolCatalog.OverlayTools.Any(e => e.Tool == Tool.Crop))
            f.Add("overlay kept Crop");
        if (ToolCatalog.EditorActions.Any(a => a.Action == OverlayAction.OpenEditor))
            f.Add("editor offers Open editor");

        // A key must not mean two things in the same host.
        foreach (var host in new[] { true, false })
        {
            var keys = ToolCatalog.Entries
                .Where(e => host ? e.InOverlay : e.InEditor)
                .Select(e => e.KeyLabel)
                .Where(k => k.Length > 0)
                .ToList();
            if (keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() != keys.Count)
                f.Add(host ? "overlay key collision" : "editor key collision");
        }

        // Routing is host-scoped. Crop's key must do nothing on the review
        // surface, which shows no Crop button — the macOS build shipped a
        // toolbar advertising keys its host ignored, and this is that lesson.
        if (ToolCatalog.ToolForKey("C", inOverlay: false) != Tool.Crop) f.Add("editor lost C");
        if (ToolCatalog.ToolForKey("C", inOverlay: true) is not null) f.Add("overlay routes C");
        if (ToolCatalog.ToolForKey("M", inOverlay: true) != Tool.Magnifier) f.Add("overlay lost M");
        if (ToolCatalog.ToolForKey("S", inOverlay: false) != Tool.Spotlight) f.Add("editor lost S");
        if (ToolCatalog.ToolForKey("v", inOverlay: false) != Tool.Select) f.Add("key not case-insensitive");
        if (ToolCatalog.ToolForKey("Q", inOverlay: false) is not null) f.Add("unknown key routed");
        return f;
    }

    // ---------- backdrop spec ----------

    static List<string> PresetsMatchSpec()
    {
        var f = new List<string>();

        // The macOS spec table, written out here rather than read back from
        // the code under test.
        var stops = new Dictionary<BackdropPreset, (float, int, int, int)[]>
        {
            [BackdropPreset.Ocean] =
            [
                (0.00f, 139, 180, 255), (0.28f, 74, 124, 240),
                (0.62f, 46, 61, 184), (1.00f, 26, 24, 104),
            ],
            [BackdropPreset.Sunset] =
            [
                (0.00f, 255, 208, 138), (0.28f, 255, 126, 74),
                (0.62f, 230, 61, 120), (1.00f, 122, 34, 136),
            ],
            [BackdropPreset.Mint] =
            [
                (0.00f, 154, 245, 212), (0.28f, 61, 220, 176),
                (0.62f, 26, 154, 138), (1.00f, 10, 69, 80),
            ],
            [BackdropPreset.Graphite] =
            [
                (0.00f, 90, 98, 112), (0.32f, 52, 58, 70),
                (0.68f, 28, 32, 40), (1.00f, 11, 13, 17),
            ],
        };
        foreach (var (preset, want) in stops)
        {
            var got = BackdropSpec.GradientStops(preset);
            if (got.Length != 4) { f.Add($"{preset}: {got.Length} stops"); continue; }
            for (int i = 0; i < 4; i++)
            {
                if (Math.Abs(got[i].Location - want[i].Item1) > 0.0001f)
                    f.Add($"{preset}[{i}] location {got[i].Location}");
                if (got[i].Color.R != want[i].Item2 || got[i].Color.G != want[i].Item3
                    || got[i].Color.B != want[i].Item4 || got[i].Color.A != 255)
                    f.Add($"{preset}[{i}] colour {got[i].Color}");
            }
        }

        var wash = new Dictionary<BackdropPreset, (int, int, int, double)>
        {
            [BackdropPreset.Ocean] = (255, 255, 255, 0.20),
            [BackdropPreset.Sunset] = (255, 232, 192, 0.18),
            [BackdropPreset.Mint] = (232, 255, 246, 0.16),
            [BackdropPreset.Graphite] = (139, 155, 184, 0.14),
        };
        foreach (var (preset, want) in wash)
        {
            var (centre, edge) = BackdropSpec.RadialWash(preset);
            if (centre.R != want.Item1 || centre.G != want.Item2 || centre.B != want.Item3)
                f.Add($"{preset} wash colour {centre}");
            var wantAlpha = (int)Math.Round(want.Item4 * 255);
            if (centre.A != wantAlpha) f.Add($"{preset} wash alpha {centre.A} want {wantAlpha}");
            // The rim MUST reach zero, or the wash becomes a flat veil over
            // the whole frame instead of a soft light in one corner.
            if (edge.A != 0) f.Add($"{preset} wash rim {edge.A}");
        }
        if (BackdropSpec.RadialWash(BackdropPreset.None).Centre.A != 0)
            f.Add("none has a wash");

        var seeds = new Dictionary<BackdropPreset, uint>
        {
            [BackdropPreset.Ocean] = 0x0CE40001u,
            [BackdropPreset.Sunset] = 0x5E700002u,
            [BackdropPreset.Mint] = 0xA1170003u,
            [BackdropPreset.Graphite] = 0x6A400004u,
            [BackdropPreset.None] = 0u,
        };
        foreach (var (preset, want) in seeds)
            if (BackdropSpec.GrainSeed(preset) != want)
                f.Add($"{preset} seed {BackdropSpec.GrainSeed(preset):X8}");

        // The hash, recomputed here from the spec's own formula.
        static uint Expected(int x, int y, uint seed)
        {
            unchecked
            {
                uint h = seed;
                h += (uint)x * 374_761_393u;
                h += (uint)y * 668_265_263u;
                h ^= h >> 13;
                h *= 1_274_126_177u;
                h ^= h >> 16;
                return h;
            }
        }
        foreach (var (x, y) in new[] { (0, 0), (1, 0), (0, 1), (63, 64), (127, 127) })
        {
            var seed = BackdropSpec.GrainSeed(BackdropPreset.Ocean);
            if (BackdropSpec.GrainHash(x, y, seed) != Expected(x, y, seed))
                f.Add($"hash@{x},{y}");
        }

        // The tile's actual bytes against that formula, for all four presets —
        // and the grain must not be flat, or it dithers nothing.
        foreach (var preset in new[]
        {
            BackdropPreset.Ocean, BackdropPreset.Sunset,
            BackdropPreset.Mint, BackdropPreset.Graphite,
        })
        {
            var seed = BackdropSpec.GrainSeed(preset);
            var tile = BackdropSpec.GrainTile(seed);
            if (tile.Length != 128 * 128 * 4) { f.Add($"{preset} tile size"); continue; }
            var distinct = new HashSet<byte>();
            for (int y = 0; y < 128; y++)
            {
                for (int x = 0; x < 128; x++)
                {
                    var i = (y * 128 + x) * 4;
                    var want = (byte)Math.Clamp(
                        128 + (int)(Expected(x, y, seed) % 5) - 2, 0, 255);
                    if (tile[i] != want || tile[i + 1] != want || tile[i + 2] != want)
                    {
                        f.Add($"{preset} tile@{x},{y}={tile[i]} want {want}");
                        y = 128; break;
                    }
                    if (tile[i + 3] != 255) { f.Add($"{preset} tile alpha"); y = 128; break; }
                    distinct.Add(tile[i]);
                }
            }
            if (distinct.Count < 3) f.Add($"{preset} tile flat ({distinct.Count} levels)");
        }
        // Two presets must not share a tile, and asking twice must not rebuild
        // a different one.
        if (ReferenceEquals(
            BackdropSpec.GrainTile(BackdropSpec.GrainSeed(BackdropPreset.Ocean)),
            BackdropSpec.GrainTile(BackdropSpec.GrainSeed(BackdropPreset.Mint))))
            f.Add("presets share a tile");
        if (!ReferenceEquals(
            BackdropSpec.GrainTile(0x0CE40001u), BackdropSpec.GrainTile(0x0CE40001u)))
            f.Add("tile not cached");

        // The two coordinate flips this port depends on. CoreGraphics counts y
        // up from the bottom, GDI+ down from the top, so the same visual axis
        // and the same visual wash centre are DIFFERENT numbers here — and
        // getting one wrong mirrors the frame while every constant above still
        // reads correct.
        var (start, end) = BackdropSpec.GradientAxis(400, 300);
        if (start != new PointF(0, 0) || end != new PointF(400, 300))
            f.Add($"axis {start}->{end}");
        var centreWash = BackdropSpec.WashCentre(400, 300);
        if (Math.Abs(centreWash.X - 88f) > 0.01f || Math.Abs(centreWash.Y - 66f) > 0.01f)
            f.Add($"wash centre {centreWash}");
        if (Math.Abs(BackdropSpec.WashRadius(300, 400) - 425f) > 0.5f)
            f.Add($"wash radius {BackdropSpec.WashRadius(300, 400)}");

        // Geometry the spec freezes.
        if (BackdropSpec.CornerRadiusPt != 12 || BackdropSpec.ShadowOffsetPt != -8
            || BackdropSpec.ShadowBlurPt != 24 || BackdropSpec.PaddingFraction != 0.06f
            || BackdropSpec.MinPadding != 40 || BackdropSpec.MaxPadding != 320
            || BackdropSpec.ShadowSafetyFactor != 1.25f
            || Math.Abs(BackdropSpec.ShadowAlpha - 0.35f) > 0.0001f
            || Math.Abs(BackdropSpec.HairlineAlpha - 0.16f) > 0.0001f
            || BackdropSpec.GrainTileSide != 128)
            f.Add("geometry moved");
        return f;
    }

    // ---------- geometry ----------

    static List<string> ComposeGeometry()
    {
        var f = new List<string>();
        // Padding: 6% of the long edge, floored by the shadow's reach and
        // capped so a 40 000 px stitch does not get a 2 400 px frame.
        if (BackdropSpec.ShadowExtent(1) != 40) f.Add($"shadow extent @1 {BackdropSpec.ShadowExtent(1)}");
        if (BackdropSpec.ShadowExtent(2) != 80) f.Add($"shadow extent @2 {BackdropSpec.ShadowExtent(2)}");
        if (BackdropSpec.Padding(100) != 40) f.Add($"pad(100) {BackdropSpec.Padding(100)}");
        if (BackdropSpec.Padding(2000) != 120) f.Add($"pad(2000) {BackdropSpec.Padding(2000)}");
        if (BackdropSpec.Padding(40000) != 320) f.Add($"pad(40000) {BackdropSpec.Padding(40000)}");
        // At scale 2 the shadow reaches 80 px, so the floor moves with it or
        // the frame would cut the shadow off at the outer edge.
        if (BackdropSpec.Padding(100, 2) != 80) f.Add($"pad(100,@2) {BackdropSpec.Padding(100, 2)}");

        var layout = new BackdropLayout(new Size(320, 240), 1, BackdropPreset.Ocean);
        if (layout.Pad != 40) f.Add($"layout pad {layout.Pad}");
        if (layout.OuterSize != new Size(400, 320)) f.Add($"outer {layout.OuterSize}");
        if (layout.InnerRect != new Rectangle(40, 40, 320, 240)) f.Add($"inner {layout.InnerRect}");
        if (layout.IsCollapsed) f.Add("framed layout collapsed");

        var plain = new BackdropLayout(new Size(320, 240), 1, BackdropPreset.None);
        if (plain.OuterSize != new Size(320, 240)) f.Add($"none outer {plain.OuterSize}");
        if (!plain.IsCollapsed) f.Add("none not collapsed");

        // Outer size and layout must agree — they are read by different call
        // sites (the export allocates from one, the preview lays out from the
        // other) and a disagreement is a frame drawn around the wrong rect.
        foreach (var (w, h) in new[] { (320, 240), (1, 1), (1433, 6469), (3000, 40) })
        {
            var dims = BackdropSpec.OuterDimensions(w, h, BackdropPreset.Sunset);
            var l = new BackdropLayout(new Size(w, h), 1, BackdropPreset.Sunset);
            if (dims is not Size s) { f.Add($"no outer for {w}x{h}"); continue; }
            if (s != l.OuterSize) f.Add($"{w}x{h}: dims {s} vs layout {l.OuterSize}");
            if (s.Width != w + 2 * (int)l.Pad || s.Height != h + 2 * (int)l.Pad)
                f.Add($"{w}x{h}: outer != inner + 2*pad");
        }
        if (BackdropSpec.OuterDimensions(0, 10, BackdropPreset.Ocean) is not null)
            f.Add("zero width accepted");
        if (BackdropSpec.OuterDimensions(320, 240, BackdropPreset.None) != new Size(320, 240))
            f.Add("none resized");
        return f;
    }

    // ---------- still RED ----------

    /// The rules the editor's history obeys, exercised on the same `Timeline`
    /// the editor uses. A backdrop preset lives on THIS timeline, not on a
    /// second one — with two stacks, undo after mark, preset, mark walks them
    /// in an order the user never performed.
    ///
    /// The states here are strings so the rules can be read at a glance; that
    /// the editor really pushes its preset through this class is the raster
    /// gate's business, where the editor can be constructed.
    static List<string> UndoTimeline()
    {
        var f = new List<string>();
        var t = new Timeline<string>();
        var discarded = new List<string>();
        t.Discarding = dropped => discarded.AddRange(dropped);

        if (t.CanUndo || t.CanRedo) f.Add("fresh timeline is not empty");

        // mark -> preset -> mark, then undo three times: the preset takes its
        // own turn, in the middle, exactly where the user put it.
        var current = "blank";
        void Edit(string next) { t.Push(current); current = next; }
        Edit("mark1");
        Edit("mark1+ocean");
        Edit("mark1+ocean+mark2");
        foreach (var want in new[] { "mark1+ocean", "mark1", "blank" })
        {
            if (!t.TryUndo(current, out var previous)) { f.Add($"undo ran out before {want}"); break; }
            current = previous;
            if (current != want) f.Add($"undo gave {current} want {want}");
        }
        if (t.CanUndo) f.Add("undo left history behind");

        // and redo walks back up the same three steps
        foreach (var want in new[] { "mark1", "mark1+ocean", "mark1+ocean+mark2" })
        {
            if (!t.TryRedo(current, out var next)) { f.Add($"redo ran out before {want}"); break; }
            current = next;
            if (current != want) f.Add($"redo gave {current} want {want}");
        }

        // A new edit after an undo FORKS: the abandoned future is discarded,
        // once, and is not reachable again.
        t.TryUndo(current, out current);
        discarded.Clear();
        Edit("mark1+ocean+mark3");
        if (t.CanRedo) f.Add("fork kept a redo branch");
        if (discarded.Count != 1 || discarded[0] != "mark1+ocean+mark2")
            f.Add($"fork discarded [{string.Join(",", discarded)}]");

        // Undoing and redoing must not discard anything: those states are
        // moving between the stacks, not leaving.
        discarded.Clear();
        t.TryUndo(current, out current);
        t.TryRedo(current, out current);
        if (discarded.Count != 0) f.Add($"undo/redo discarded {discarded.Count}");

        // Depth is symmetric: what goes down one stack comes up the other.
        var before = t.UndoDepth;
        t.TryUndo(current, out current);
        if (t.UndoDepth != before - 1 || t.RedoDepth != 1)
            f.Add($"depth {t.UndoDepth}/{t.RedoDepth} from {before}");

        // Clearing hands every state back exactly once, so an owner holding
        // unmanaged memory can release it.
        discarded.Clear();
        var total = t.UndoDepth + t.RedoDepth;
        t.Clear();
        if (discarded.Count != total) f.Add($"clear discarded {discarded.Count} of {total}");
        if (t.CanUndo || t.CanRedo) f.Add("clear left history");
        return f;
    }

    /// Which route gets the frame and which gets the document. The pixels
    /// each route actually receives are the raster gate's business; this is
    /// the mapping, and a route that silently fell off the visual list would
    /// hand the user an undecorated picture with no other symptom.
    static List<string> RouteTable()
    {
        var f = new List<string>();
        foreach (var action in RouteDecoration.VisualRoutes)
            if (!RouteDecoration.UsesDecoration(action)) f.Add($"{action} lost its frame");
        foreach (var action in RouteDecoration.SemanticRoutes)
            if (RouteDecoration.UsesDecoration(action)) f.Add($"{action} reads the frame");
        // Every route that produces a picture must be on one list or the
        // other, and on exactly one.
        foreach (var action in new[]
        {
            OverlayAction.Copy, OverlayAction.Save, OverlayAction.Pin,
            OverlayAction.OpenEditor, OverlayAction.Ocr, OverlayAction.Translate,
        })
        {
            var visual = RouteDecoration.VisualRoutes.Contains(action);
            var semantic = RouteDecoration.SemanticRoutes.Contains(action);
            if (visual == semantic) f.Add($"{action} is on {(visual ? "both" : "neither")} list");
        }
        // Choosing a colour or opening the backdrop menu exports nothing.
        foreach (var action in new[]
        {
            OverlayAction.Color, OverlayAction.Undo, OverlayAction.Redo,
            OverlayAction.Backdrop, OverlayAction.Close,
        })
            if (RouteDecoration.UsesDecoration(action)) f.Add($"{action} exports");
        return f;
    }


}
