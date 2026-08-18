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
        failed += Check("win-backdrop-presets-match-spec", PresetsMatchSpec());
        failed += Check("win-backdrop-compose-geometry", ComposeGeometry());
        failed += Check("win-backdrop-undo-timeline", UndoTimeline());
        failed += Check("win-backdrop-route-table", RouteTable());
        failed += Check("win-overlay-toolbar-layout", OverlayToolbarLayout());
        Console.WriteLine(failed == 0
            ? "ALL PARITY GATES PASSED"
            : $"{failed} PARITY GATE(S) FAILED");
        return failed == 0 ? 0 : 1;
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

    static List<string> OverlayToolbarLayout() =>
        ["not implemented: OverlayToolbar (lane UI) is not merged yet"];
}
