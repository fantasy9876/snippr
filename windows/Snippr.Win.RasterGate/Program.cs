using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using Snippr;

namespace Snippr.Tests;

/// The pixel half of the Windows parity gate: GDI+, therefore windows-latest
/// only. Its counterparts on macOS are
/// `sliceB-backdrop-fill-never-paints-outside-canvas`,
/// `sliceB-magnifier-crop-privacy` and the compose gates around them
/// (SHA f2fd279).
static class Program
{
    static int Main()
    {
        int failed = 0;
        failed += Check("win-backdrop-fill-never-paints-outside-canvas", FillStaysInside());
        failed += Check("win-backdrop-compose-pixels", ComposePixels());
        failed += Check("win-backdrop-grain-deterministic", GrainDeterministic());
        failed += Check("win-magnifier-crop-privacy", MagnifierPrivacy());
        failed += Check("win-magnifier-drag-frame", MagnifierDragFrame());
        failed += Check("win-magnifier-source-frame", MagnifierSourceFrame());
        failed += Check("win-spotlight-dim", SpotlightDim());
        failed += Check("win-backdrop-export-routes", ExportRoutes());
        failed += Check("win-area-review-payloads", AreaReviewPayloads());
        failed += Check("win-backdrop-preview-matches-export", PreviewMatchesExport());
        failed += Check("win-backdrop-corner-radius-pixels", CornerRadiusPixels());
        failed += Check("win-area-review-preview-shows-document", ReviewPreviewShowsDocument());
        failed += Check("win-hover-hint-clamped", HoverHintClamped());
        failed += Check("win-overlay-chrome-paints-its-own-colours", OverlayChromePixels());
        failed += Check("win-pixelate-matches-reference", PixelateMatchesReference());
        if (pending > 0)
            Console.WriteLine($"{pending} RASTER GATE(S) PENDING — not a pass");
        Console.WriteLine(failed == 0
            ? (pending == 0 ? "ALL RASTER GATES PASSED" : "NO RASTER GATE FAILED, SOME PENDING")
            : $"{failed} RASTER GATE(S) FAILED");
        return failed == 0 ? 0 : 1;
    }

    static int pending;

    /// A gate whose subject does not exist yet. It is NOT a pass: it prints
    /// its reason and is counted, and the summary says so — but it does not
    /// fail the job, because a step that throws here would stop the gates
    /// after it from ever running. Zero pending is a release condition.
    static int Pend(string name, string reason)
    {
        Console.WriteLine($"PEND {name} {reason}");
        pending++;
        return 0;
    }

    static int Check(string name, List<string> failures)
    {
        if (failures.Count == 0) { Console.WriteLine($"PASS {name}"); return 0; }
        Console.WriteLine($"FAIL {name} {string.Join(" | ", failures.Take(6))}");
        return 1;
    }

    static Color At(Bitmap b, int x, int y) => b.GetPixel(x, y);

    static bool Near(Color a, Color b, int tol) =>
        Math.Abs(a.R - b.R) <= tol && Math.Abs(a.G - b.G) <= tol
            && Math.Abs(a.B - b.B) <= tol;

    // ---------- the fill stays inside its canvas ----------

    static List<string> FillStaysInside()
    {
        var f = new List<string>();
        var sentinel = Color.FromArgb(255, 77, 77, 77);
        var canvas = new SizeF(120, 90);

        // Three times the canvas, with the canvas placed in the middle: a fill
        // that clipped in device space rather than user space would pass a
        // centred test and still bleed.
        void Bled(string label, Action<Graphics, SizeF> body)
        {
            using var bmp = new Bitmap(360, 270, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                using var fill = new SolidBrush(sentinel);
                g.FillRectangle(fill, 0, 0, 360, 270);
                var state = g.Save();
                g.TranslateTransform(canvas.Width, canvas.Height);
                body(g, canvas);
                g.Restore(state);
            }
            var inside = new Rectangle(120, 90, 120, 90);
            int strays = 0;
            string first = "";
            for (int y = 0; y < 270; y++)
                for (int x = 0; x < 360; x++)
                {
                    if (inside.Contains(x, y)) continue;
                    var c = At(bmp, x, y);
                    if (c.R == sentinel.R && c.G == sentinel.G && c.B == sentinel.B) continue;
                    strays++;
                    if (first.Length == 0) first = $"@{x},{y}={c.R},{c.G},{c.B}";
                }
            if (strays > 0) f.Add($"{label}:{strays}px {first}");
            // Positive premise: the canvas itself HAS been painted, so a fill
            // that drew nothing cannot pass.
            var centre = At(bmp, 180, 135);
            if (Near(centre, sentinel, 0)) f.Add($"{label}:painted-nothing");
        }

        foreach (var preset in new[]
        {
            BackdropPreset.Ocean, BackdropPreset.Sunset,
            BackdropPreset.Mint, BackdropPreset.Graphite,
        })
        {
            Bled($"fill-{preset}", (g, size) => BackdropRender.DrawFill(g, size, preset));
            Bled($"frame-{preset}", (g, size) => BackdropRender.DrawFrame(
                g, size, new RectangleF(20, 20, size.Width - 40, size.Height - 40),
                preset, 1));
        }
        return f;
    }

    // ---------- compose ----------

    static Bitmap Document(int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        using var brush = new SolidBrush(Color.FromArgb(255, 20, 200, 90));
        g.FillRectangle(brush, 0, 0, w, h);
        return bmp;
    }

    /// A document with DETAIL in it.
    ///
    /// Pixelating a flat colour gives that same flat colour back, so a gate
    /// that redacts a solid fixture and then looks for a change finds none and
    /// blames the pipeline — which is exactly what the first CI run reported.
    /// A two-pixel check pattern averages to something visibly different, so
    /// "the redaction is in this image" is a question the pixels can answer.
    static Bitmap CheckeredDocument(int w, int h, Color a, Color b)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                bmp.SetPixel(x, y, ((x / 2) + (y / 2)) % 2 == 0 ? a : b);
        return bmp;
    }

    static List<string> ComposePixels()
    {
        var f = new List<string>();
        using var doc = Document(320, 240);

        var plain = BackdropRender.Compose(doc, BackdropPreset.None);
        if (!ReferenceEquals(plain, doc)) f.Add("none did not hand the input back");

        using var framed = BackdropRender.Compose(doc, BackdropPreset.Ocean)!;
        var layout = new BackdropLayout(new Size(320, 240), 1, BackdropPreset.Ocean);
        if (framed.Width != layout.OuterSize.Width || framed.Height != layout.OuterSize.Height)
            f.Add($"outer {framed.Width}x{framed.Height} want {layout.OuterSize}");

        var pad = (int)layout.Pad;
        // The document lands whole, at the padding offset.
        if (!Near(At(framed, pad + 160, pad + 120), Color.FromArgb(20, 200, 90), 2))
            f.Add($"document centre {At(framed, pad + 160, pad + 120)}");
        // The frame is around it, and it is not the document's colour.
        if (Near(At(framed, 4, 4), Color.FromArgb(20, 200, 90), 40))
            f.Add("frame shows the document");
        // The plate's corner is ROUNDED: the pixel just inside the document's
        // square corner belongs to the frame, not to the document.
        if (Near(At(framed, pad + 1, pad + 1), Color.FromArgb(20, 200, 90), 20))
            f.Add("plate corner is square");
        // …while a point a radius in is document.
        if (!Near(At(framed, pad + 20, pad + 20), Color.FromArgb(20, 200, 90), 6))
            f.Add($"plate over-clipped {At(framed, pad + 20, pad + 20)}");
        // EVERY pixel is opaque — not a sample of them. An exported picture
        // with a translucent edge prints as a dark fringe wherever it lands,
        // and the first CI run found exactly that along all four sides.
        int sheer = 0;
        var firstSheer = "";
        for (int y = 0; y < framed.Height; y++)
            for (int x = 0; x < framed.Width; x++)
                if (At(framed, x, y).A != 255)
                {
                    sheer++;
                    if (firstSheer.Length == 0)
                        firstSheer = $"@{x},{y}=A{At(framed, x, y).A}";
                }
        if (sheer > 0) f.Add($"frame not opaque: {sheer}px {firstSheer}");
        return f;
    }

    static List<string> GrainDeterministic()
    {
        var f = new List<string>();
        static Bitmap Fill(BackdropPreset preset)
        {
            var bmp = new Bitmap(256, 256, PixelFormat.Format32bppArgb);
            using var g = Graphics.FromImage(bmp);
            BackdropRender.DrawFill(g, new SizeF(256, 256), preset);
            return bmp;
        }
        using var once = Fill(BackdropPreset.Sunset);
        using var twice = Fill(BackdropPreset.Sunset);
        for (int y = 0; y < 256; y += 7)
            for (int x = 0; x < 256; x += 7)
                if (At(once, x, y) != At(twice, x, y))
                { f.Add($"not deterministic @{x},{y}"); y = 256; break; }

        // The grain must actually vary, or it dithers nothing — and it must
        // stay a dither: a run of neighbouring pixels in a smooth part of the
        // ramp may differ by a couple of levels, never by a block.
        var levels = new HashSet<int>();
        int worst = 0;
        for (int x = 40; x < 200; x++)
        {
            levels.Add(At(once, x, 128).R);
            worst = Math.Max(worst, Math.Abs(At(once, x, 128).R - At(once, x + 1, 128).R));
        }
        if (levels.Count < 3) f.Add($"grain flat ({levels.Count} levels)");
        if (worst > 8) f.Add($"grain is not a dither (jump {worst})");

        // The tiles are CACHED now — built once per preset instead of once per
        // paint, which was costing a 64 KB byte[], a Bitmap and 16384 hashed
        // pixels on every frame of every drag over a backdrop. A cache has one
        // new way to be wrong that painting afresh did not: handing back the
        // wrong preset's tile. So interleave. Ocean either side of Sunset must
        // still be Ocean, and must still not be Sunset.
        using var oceanFirst = Fill(BackdropPreset.Ocean);
        using var sunset = Fill(BackdropPreset.Sunset);
        using var oceanAgain = Fill(BackdropPreset.Ocean);
        int drifted = 0;
        bool distinct = false;
        for (int y = 0; y < 256; y += 3)
            for (int x = 0; x < 256; x += 3)
            {
                if (At(oceanFirst, x, y) != At(oceanAgain, x, y)) drifted++;
                if (At(oceanFirst, x, y) != At(sunset, x, y)) distinct = true;
            }
        if (drifted > 0)
            f.Add($"{drifted}px of Ocean changed after Sunset was drawn between");
        if (!distinct) f.Add("Ocean and Sunset render identically — one tile for both");
        return f;
    }

    // ---------- magnifier drag / source frames ----------

    static int Lum(Bitmap b, int x, int y)
    {
        var c = At(b, x, y);
        return (c.R + c.G + c.B) / 3;
    }

    /// While the drag is live (no snapshot) the source has a 1 px white inner
    /// hairline and a 1 px dark outer, the interior is untouched, and the
    /// would-be callout is a dashed outline — not a 1:1 box on the source.
    static List<string> MagnifierDragFrame()
    {
        var f = new List<string>();
        const int gray = 140;
        using var bmp = new Bitmap(200, 200, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        using (var fill = new SolidBrush(Color.FromArgb(255, gray, gray, gray)))
            g.FillRectangle(fill, 0, 0, 200, 200);

        var source = new Rectangle(20, 20, 40, 30);
        var bounds = new Rectangle(0, 0, 200, 200);
        var callout = MagnifierAnnotation.PlaceCallout(source, bounds);
        var mag = new MagnifierAnnotation
        {
            SourceRect = source, CalloutRect = callout, Snapshot = null,
        };
        using (var g = Graphics.FromImage(bmp))
            AnnotationCompositor.Draw([mag], g, bmp, bounds, null);

        if (Lum(bmp, 20, 35) < 200) f.Add($"left edge not white {Lum(bmp, 20, 35)}");
        if (Lum(bmp, 19, 35) > gray - 30) f.Add($"left outer not dark {Lum(bmp, 19, 35)}");
        if (Lum(bmp, 40, 20) < 200) f.Add($"top edge not white {Lum(bmp, 40, 20)}");
        if (Math.Abs(Lum(bmp, 40, 35) - gray) > 2)
            f.Add($"interior touched {Lum(bmp, 40, 35)}");

        // 40×30 @ 2.5× → 100×75. Right still holds full zoom, so the callout
        // sits to the right, bottoms-aligned then clamped (y=0), not the old
        // independent-axis park at (76, 66).
        if (callout != new Rectangle(76, 0, 100, 75))
            f.Add($"callout {callout} want 76,0,100x75");
        else
        {
            int inked = 0;
            for (int y = callout.Y + 1; y < callout.Bottom - 1; y++)
                if (Math.Abs(Lum(bmp, callout.X, y) - gray) > 40) inked++;
            if (inked < 20) f.Add($"callout outline inked {inked}");
        }

        // Near the right edge the callout must flip left, stay inside, and
        // not cover the source — the last is what the old clamp missed.
        var rightSrc = new Rectangle(150, 20, 40, 30);
        var flipped = MagnifierAnnotation.PlaceCallout(rightSrc, bounds);
        if (flipped.Right > 200 || flipped.X < 0)
            f.Add($"right-edge unclamped {flipped}");
        if (flipped.X >= 150) f.Add($"did not flip left {flipped}");
        if (flipped.IntersectsWith(rightSrc))
            f.Add($"right-edge covered {flipped}");
        return f;
    }

    /// After release the source frame stays, and the callout is the solid
    /// ring it always was. Drawing a frame with no snapshot is the drag path
    /// above; this one is the committed annotation.
    static List<string> MagnifierSourceFrame()
    {
        var f = new List<string>();
        const int gray = 140;
        using var bmp = new Bitmap(200, 200, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        using (var fill = new SolidBrush(Color.FromArgb(255, gray, gray, gray)))
            g.FillRectangle(fill, 0, 0, 200, 200);

        var source = new Rectangle(20, 20, 40, 30);
        var bounds = new Rectangle(0, 0, 200, 200);
        var callout = MagnifierAnnotation.PlaceCallout(source, bounds);
        using var snapshot = AnnotationCompositor.MagnifierSnapshot(bmp, source, []);
        if (snapshot == null) { f.Add("no snapshot"); return f; }
        var mag = new MagnifierAnnotation
        {
            SourceRect = source, CalloutRect = callout, Snapshot = snapshot,
        };
        using (var g = Graphics.FromImage(bmp))
            AnnotationCompositor.Draw([mag], g, bmp, bounds, null);

        if (Lum(bmp, 20, 35) < 200)
            f.Add($"source frame missing {Lum(bmp, 20, 35)}");
        if (Lum(bmp, 19, 35) > gray - 30)
            f.Add($"source outer missing {Lum(bmp, 19, 35)}");
        if (Math.Abs(Lum(bmp, 40, 35) - gray) > 2)
            f.Add($"interior touched after fill {Lum(bmp, 40, 35)}");
        var ring = Lum(bmp, callout.X, callout.Y + callout.Height / 2);
        if (ring < 200) f.Add($"callout ring {ring}");
        return f;
    }

    // ---------- magnifier privacy ----------

    static List<string> MagnifierPrivacy()
    {
        var f = new List<string>();
        var secret = new Rectangle(20, 20, 40, 40);
        var callout = new Rectangle(180, 180, 80, 80);

        // The secret is a fine check pattern, not a flat colour: pixelating a
        // flat colour returns it unchanged, so "the callout shows raw pixels"
        // and "the callout shows the redaction" would look identical — the
        // first CI run failed on exactly that fixture, not on the code.
        Bitmap Source()
        {
            var bmp = new Bitmap(320, 300, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            using (var grey = new SolidBrush(Color.FromArgb(255, 140, 140, 140)))
                g.FillRectangle(grey, 0, 0, 320, 300);
            for (int y = secret.Top; y < secret.Bottom; y++)
                for (int x = secret.Left; x < secret.Right; x++)
                    bmp.SetPixel(x, y, ((x / 2) + (y / 2)) % 2 == 0
                        ? Color.FromArgb(255, 255, 0, 0)
                        : Color.FromArgb(255, 255, 255, 255));
            return bmp;
        }
        // Raw, as in "these bytes came straight off the source": pure red only
        // survives where nothing averaged it.
        static bool IsRaw(Color c) => c.R > 240 && c.G < 60 && c.B < 60;

        using var baseImage = Source();
        Bitmap Shot(Rectangle visible, bool withMagnifier, IEnumerable<BlurAnnotation>? redactions = null)
        {
            var marks = new List<Annotation>();
            if (redactions != null) marks.AddRange(redactions);
            if (withMagnifier)
                marks.Add(new MagnifierAnnotation
                {
                    SourceRect = secret,
                    CalloutRect = callout,
                    Snapshot = AnnotationCompositor.MagnifierSnapshot(
                        baseImage, secret, redactions ?? []),
                });
            var bmp = new Bitmap(320, 300, PixelFormat.Format32bppArgb);
            using var g = Graphics.FromImage(bmp);
            g.DrawImageUnscaled(baseImage, 0, 0);
            using var pixelated = AnnotationRenderer.Pixelate(baseImage);
            AnnotationCompositor.Draw(marks, g, baseImage, visible, pixelated);
            return bmp;
        }

        // Is anything at all drawn where the callout would be? Compared against
        // the same scene without it, so the answer does not depend on what
        // colour a loupe happens to show.
        int DiffersFromBaseline(Bitmap shot, Bitmap baseline)
        {
            int n = 0;
            for (int y = callout.Top + 4; y < callout.Bottom - 4; y++)
                for (int x = callout.Left + 4; x < callout.Right - 4; x++)
                    if (!Near(At(shot, x, y), At(baseline, x, y), 2)) n++;
            return n;
        }
        int RawPixels(Bitmap shot)
        {
            int n = 0;
            for (int y = callout.Top + 4; y < callout.Bottom - 4; y++)
                for (int x = callout.Left + 4; x < callout.Right - 4; x++)
                    if (IsRaw(At(shot, x, y))) n++;
            return n;
        }

        using var plain = Shot(new Rectangle(0, 0, 320, 300), withMagnifier: false);

        // Premise: with the source wholly inside the crop the callout IS drawn,
        // and it really does carry the source's own pixels.
        using (var inside = Shot(new Rectangle(0, 0, 320, 300), true))
        {
            if (DiffersFromBaseline(inside, plain) == 0) f.Add("inside-crop:not-drawn");
            if (RawPixels(inside) == 0) f.Add("inside-crop:probe-blind");
        }
        // Wholly outside the crop: nothing at all, not even a frame.
        using (var outside = Shot(new Rectangle(150, 150, 170, 150), true))
            if (DiffersFromBaseline(outside, plain) != 0) f.Add("outside-crop:leaked");
        // Only PARTLY outside is still a leak of the part that is out, so the
        // test is `contains`, not `intersects`.
        using (var partial = Shot(new Rectangle(40, 40, 280, 260), true))
            if (DiffersFromBaseline(partial, plain) != 0) f.Add("partial-crop:leaked");

        // And the patch is sampled AFTER the redactions: over a pixelated area
        // the callout must carry the pixelation, with no raw pixel left in it,
        // while still being drawn.
        var blur = new BlurAnnotation { Rect = secret };
        using (var covered = Shot(new Rectangle(0, 0, 320, 300), true, [blur]))
        using (var coveredPlain = Shot(new Rectangle(0, 0, 320, 300), false, [blur]))
        {
            if (DiffersFromBaseline(covered, coveredPlain) == 0)
                f.Add("redacted-source:callout-vanished");
            // The real invariant, stated as itself: what the loupe shows IS
            // the redacted document, enlarged. Asking merely "is any raw colour
            // left" made the gate depend on how the pixelation happens to
            // average, which is not what the callout promises.
            int mismatched = 0, probed = 0;
            string firstMismatch = "";
            for (int cy = callout.Top + 6; cy < callout.Bottom - 6; cy++)
            {
                for (int cx = callout.Left + 6; cx < callout.Right - 6; cx++)
                {
                    var sx = (cx - callout.X) * secret.Width / callout.Width;
                    var sy = (cy - callout.Y) * secret.Height / callout.Height;
                    var got = At(covered, cx, cy);
                    probed++;
                    var matched = false;
                    // A one-pixel rounding difference in the magnification is
                    // not a leak, so the neighbours count as a match too.
                    for (int dy = -1; dy <= 1 && !matched; dy++)
                        for (int dx = -1; dx <= 1 && !matched; dx++)
                        {
                            var px = Math.Clamp(secret.X + sx + dx, secret.Left, secret.Right - 1);
                            var py = Math.Clamp(secret.Y + sy + dy, secret.Top, secret.Bottom - 1);
                            if (Near(got, At(coveredPlain, px, py), 4)) matched = true;
                        }
                    if (!matched)
                    {
                        mismatched++;
                        if (firstMismatch.Length == 0)
                            firstMismatch = $"@{cx},{cy}={got.R},{got.G},{got.B}";
                    }
                }
            }
            if (mismatched * 100 > probed)
                f.Add($"callout is not the redacted document ({mismatched}/{probed}) {firstMismatch}");
            // And with the pixelation averaging as it must, no source colour
            // survives it untouched.
            var raw = RawPixels(covered);
            if (raw > 0) f.Add($"callout resurrected raw pixels ({raw}px)");
        }
        return f;
    }

    // ---------- spotlight ----------

    static List<string> SpotlightDim()
    {
        var f = new List<string>();
        var canvas = new Rectangle(0, 0, 200, 160);
        var lit = new Rectangle(60, 50, 80, 60);
        using var bmp = new Bitmap(canvas.Width, canvas.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            using var white = new SolidBrush(Color.White);
            g.FillRectangle(white, canvas);
            var spot = new SpotlightAnnotation
            {
                Rect = lit, BaseBounds = canvas, DimFraction = 0.6f,
            };
            AnnotationCompositor.Draw([spot], g, bmp, canvas, null);
        }
        // Inside is untouched; outside is dimmed by the spec's fraction.
        var insidePixel = At(bmp, lit.X + 40, lit.Y + 30);
        if (!Near(insidePixel, Color.White, 2)) f.Add($"lit area dimmed {insidePixel}");
        var outsidePixel = At(bmp, 5, 5);
        var want = (int)Math.Round(255 * (1 - 0.6));
        if (Math.Abs(outsidePixel.R - want) > 3)
            f.Add($"dim {outsidePixel.R} want {want}");
        // The dimming stops AT the edge, not a few pixels in.
        if (!Near(At(bmp, lit.X + 1, lit.Y + 1), Color.White, 4))
            f.Add("dim bleeds into the lit rect");
        return f;
    }

    // ---------- area review ----------

    /// The review surface produces the same two readings the editor does, from
    /// a crop that can still move under it.
    static List<string> AreaReviewPayloads()
    {
        var f = new List<string>();
        using var desktop = CheckeredDocument(
            600, 500, Color.FromArgb(255, 30, 90, 200), Color.FromArgb(255, 240, 240, 240));
        var crop = new Rectangle(100, 80, 200, 150);
        var session = new AreaReviewSession(desktop, crop);

        // A mark inside the crop, and one entirely outside it.
        var inside = new BlurAnnotation { Rect = new Rectangle(140, 120, 40, 40) };
        var outside = new BlurAnnotation { Rect = new Rectangle(20, 20, 40, 40) };
        session.Add(inside);
        session.Add(outside);

        using (var semantic = session.Semantic())
        {
            if (semantic.Width != crop.Width || semantic.Height != crop.Height)
                f.Add($"semantic {semantic.Width}x{semantic.Height} want {crop.Size}");
            // The inside mark landed, shifted into the crop's coordinates.
            int changed = 0;
            for (int y = 4; y < 36; y++)
                for (int x = 4; x < 36; x++)
                {
                    var docPixel = At(desktop, inside.Rect.X + x, inside.Rect.Y + y);
                    var cropPixel = At(
                        semantic, inside.Rect.X - crop.X + x, inside.Rect.Y - crop.Y + y);
                    if (!Near(docPixel, cropPixel, 2)) changed++;
                }
            if (changed * 2 < 32 * 32) f.Add($"mark not in the crop ({changed})");
        }

        // Framed: outer size from the layout, and `.none` untouched.
        session.ApplyBackdrop(BackdropPreset.Graphite);
        var layout = new BackdropLayout(crop.Size, 1, BackdropPreset.Graphite);
        using (var visual = session.Visual())
        {
            if (visual.Width != layout.OuterSize.Width || visual.Height != layout.OuterSize.Height)
                f.Add($"visual {visual.Width}x{visual.Height} want {layout.OuterSize}");
        }
        if (session.ExportedSize != layout.OuterSize)
            f.Add($"badge {session.ExportedSize} want {layout.OuterSize}");
        using (var copy = session.ForRoute(OverlayAction.Copy))
        using (var ocr = session.ForRoute(OverlayAction.Ocr))
        {
            if (copy.Width != layout.OuterSize.Width) f.Add("Copy not framed");
            if (ocr.Width != crop.Width) f.Add("OCR framed");
        }
        session.ApplyBackdrop(BackdropPreset.None);

        // A magnifier made here, then the crop moves off its source: preview
        // and export stop showing it, because the compositor is asked the same
        // question by both.
        var mag = session.MakeMagnifier(new Rectangle(140, 120, 40, 40));
        if (mag == null) f.Add("no magnifier");
        else
        {
            session.Add(mag);
            if (!session.PixelRect.Contains(mag.CalloutRect))
                f.Add($"callout parked outside the crop {mag.CalloutRect}");
            using (var withCallout = session.Semantic())
            {
                session.Annotations.Remove(mag);
                using var without = session.Semantic();
                session.Annotations.Add(mag);
                int drawn = 0;
                var local = new Rectangle(
                    mag.CalloutRect.X - crop.X, mag.CalloutRect.Y - crop.Y,
                    mag.CalloutRect.Width, mag.CalloutRect.Height);
                for (int y = local.Top + 4; y < local.Bottom - 4; y++)
                    for (int x = local.Left + 4; x < local.Right - 4; x++)
                        if (!Near(At(withCallout, x, y), At(without, x, y), 2)) drawn++;
                if (drawn == 0) f.Add("callout not drawn inside the crop");
            }
            // Move the crop so the SOURCE falls outside it. The callout is
            // still where it was; what changed is that its source is no longer
            // part of the picture.
            session.SetSelection(new Rectangle(180, 140, 200, 150));
            using (var moved = session.Semantic())
            {
                session.Annotations.Remove(mag);
                using var movedWithout = session.Semantic();
                session.Annotations.Add(mag);
                int leaked = 0;
                for (int y = 0; y < moved.Height; y++)
                    for (int x = 0; x < moved.Width; x++)
                        if (!Near(At(moved, x, y), At(movedWithout, x, y), 2)) leaked++;
                if (leaked != 0) f.Add($"callout survived the crop move ({leaked}px)");
            }
        }
        return f;
    }

    /// A hint must land on the screen, whatever button it belongs to. The
    /// buttons that matter are the ones in the corners: a hint placed below a
    /// button at the bottom edge, or centred on a button at the left edge, is
    /// exactly where an off-screen rect comes from.
    static List<string> HoverHintClamped()
    {
        var f = new List<string>();
        var screen = new Rectangle(0, 0, 1920, 1080);
        var size = new Size(160, 28);
        var corners = new (string Where, Rectangle Anchor)[]
        {
            ("top-left", new Rectangle(0, 0, 34, 30)),
            ("top-right", new Rectangle(1886, 0, 34, 30)),
            ("bottom-left", new Rectangle(0, 1050, 34, 30)),
            ("bottom-right", new Rectangle(1886, 1050, 34, 30)),
            ("middle", new Rectangle(940, 520, 34, 30)),
        };
        foreach (var (where, anchor) in corners)
        {
            var placed = HoverHint.Place(size, anchor, screen);
            if (placed is not Rectangle rect) { f.Add($"{where}: no placement"); continue; }
            if (!screen.Contains(rect)) f.Add($"{where}: {rect} outside {screen}");
            if (rect.Width < size.Width || rect.Height < size.Height)
                f.Add($"{where}: truncated to {rect.Size}");
            // It must not cover the button it describes.
            if (rect.IntersectsWith(anchor)) f.Add($"{where}: hint covers its button");
        }
        // Below by preference, above when there is no room below.
        var bottom = HoverHint.Place(size, new Rectangle(940, 1046, 34, 30), screen);
        if (bottom is Rectangle b && b.Top > 1046) f.Add("bottom button: hint pushed off");
        var top = HoverHint.Place(size, new Rectangle(940, 4, 34, 30), screen);
        if (top is Rectangle t && t.Top < 34) f.Add("top button: hint sits above the screen edge");
        // And a hole too small for a hint gets none rather than a sliver.
        if (HoverHint.Place(size, new Rectangle(0, 0, 34, 30), new Rectangle(0, 0, 40, 12)) != null)
            f.Add("sliver accepted");
        return f;
    }

    /// What a preview draws around the document and what the export writes
    /// around it are the same frame — same geometry, same ramp, same wash.
    ///
    /// Both go through `DrawFrameForPreview`/`Compose`, which share `DrawFrame`;
    /// this renders each one and compares the ring of frame around the
    /// document, which is the part a second drawing path would get wrong.
    static List<string> PreviewMatchesExport()
    {
        var f = new List<string>();
        using var doc = Document(240, 180);
        var layout = new BackdropLayout(new Size(240, 180), 1, BackdropPreset.Ocean);
        var pad = layout.Pad;
        using var exported = BackdropRender.Compose(doc, BackdropPreset.Ocean)!;

        // Every zoom the editor can be at, not just 100%. A preview drawn in
        // the wrong units looks perfect at 1 and wrong everywhere else — which
        // is exactly how the hairline shipped: the canvas' pixel size and the
        // zoom multiplied each other, so at 0.5 and 2 the line went off the
        // document's edge while the zoom-1 probe stayed happy.
        foreach (var zoom in new[] { 0.5f, 1f, 2f })
        {
            var outerW = (int)Math.Round((240 + pad * 2) * zoom);
            var outerH = (int)Math.Round((180 + pad * 2) * zoom);
            var padView = pad * zoom;
            var docRect = new RectangleF(padView, padView, 240 * zoom, 180 * zoom);

            using var preview = new Bitmap(outerW, outerH, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(preview))
            {
                using (var basecoat = new SolidBrush(
                    BackdropSpec.GradientStops(BackdropPreset.Ocean)[0].Color))
                    g.FillRectangle(basecoat, 0, 0, outerW, outerH);
                BackdropRender.DrawFrameForPreview(g, docRect, zoom, BackdropPreset.Ocean);
                // The document, and its hairline, the way the canvas draws
                // them: scaled by the zoom, in document units.
                var state = g.Save();
                g.TranslateTransform(docRect.X, docRect.Y);
                g.ScaleTransform(zoom, zoom);
                g.DrawImage(doc, new Rectangle(0, 0, 240, 180));
                BackdropRender.DrawPlateHairline(g, new RectangleF(0, 0, 240, 180), 1f);
                g.Restore(state);
            }

            // The exported picture at the same size, so the two can be
            // compared pixel for pixel.
            using var reference = new Bitmap(outerW, outerH, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(reference))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                g.DrawImage(exported, new Rectangle(0, 0, outerW, outerH));
            }

            int differing = 0, probed = 0, worst = 0;
            string first = "";
            for (int y = 0; y < outerH; y++)
                for (int x = 0; x < outerW; x++)
                {
                    // The frame ring. Inside the document the two differ by
                    // the resampling of the picture itself, which is not what
                    // this compares.
                    if (x >= docRect.Left - 2 && x < docRect.Right + 2
                        && y >= docRect.Top - 2 && y < docRect.Bottom + 2) continue;
                    probed++;
                    var got = At(preview, x, y);
                    var want = At(reference, x, y);
                    worst = Math.Max(
                        worst,
                        Math.Max(
                            Math.Abs(got.R - want.R),
                            Math.Max(Math.Abs(got.G - want.G), Math.Abs(got.B - want.B))));
                    if (Near(got, want, 12)) continue;
                    differing++;
                    if (first.Length == 0)
                        first = $"{x},{y} preview {got} export {want}";
                }
            // Every zoom is reported, whatever the earlier ones did: reading
            // one failure and guessing about the other two costs a CI round
            // trip that the log could have paid for.
            if (probed == 0) { f.Add($"{zoom}x: nothing probed"); continue; }
            if (differing * 50 > probed)
                f.Add($"{zoom}x: frame differs ({differing}/{probed}, worst {worst}) {first}");

            // The hairline is ON the document's edge at every zoom. It is
            // white at 16% over the picture, so the edge reads lighter than
            // the pixels a few rows in — and if it were drawn in the wrong
            // units it would be off the edge entirely and the two would match.
            int edgeX = (int)(docRect.Left + docRect.Width / 2);
            int edgeY = (int)docRect.Top;
            var edge = At(preview, edgeX, edgeY + 1);
            var inside = At(preview, edgeX, edgeY + (int)Math.Max(4, 6 * zoom));
            if (edge.R <= inside.R && edge.G <= inside.G && edge.B <= inside.B)
                f.Add($"{zoom}x: no hairline at the document edge ({edge} vs {inside})");
        }

        // The oracle is not blind: a different preset really does change these
        // pixels, so agreement above means something.
        var probeLayout = new BackdropLayout(new Size(240, 180), 1, BackdropPreset.Sunset);
        using var other = new Bitmap(
            probeLayout.OuterSize.Width, probeLayout.OuterSize.Height,
            PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(other))
            BackdropRender.DrawFrameForPreview(
                g, new RectangleF(pad, pad, 240, 180), 1f, BackdropPreset.Sunset);
        if (Near(At(other, 4, 4), At(exported, 4, 4), 3))
            f.Add("presets are indistinguishable at the probe");
        return f;
    }

    /// The radius is not just a number in a table: the plate really is cut
    /// that far in, and the preview cuts it the same way.
    ///
    /// Measured by walking the document's top edge inward until the frame stops
    /// and the document starts — which is the corner's chord, and grows with
    /// the style.
    static List<string> CornerRadiusPixels()
    {
        var f = new List<string>();
        using var doc = Document(600, 400);

        int CutAt(Bitmap picture, int pad)
        {
            // Along the document's top row, how many pixels from its left edge
            // are still frame rather than document?
            for (int x = 0; x < 300; x++)
                if (Near(At(picture, pad + x, pad + 1), Color.FromArgb(20, 200, 90), 40))
                    return x;
            return -1;
        }

        var measured = new Dictionary<BackdropCornerStyle, int>();
        foreach (var style in Enum.GetValues<BackdropCornerStyle>())
        {
            using var framed = BackdropRender.Compose(
                doc, BackdropPreset.Ocean, corners: style)!;
            var layout = new BackdropLayout(new Size(600, 400), 1, BackdropPreset.Ocean);
            var cut = CutAt(framed, (int)layout.Pad);
            if (cut < 0) { f.Add($"{style}: document never starts"); continue; }
            measured[style] = cut;
            var want = BackdropSpec.CornerRadius(new Size(600, 400), style);
            // The chord at one row in is a shade under the radius; what matters
            // is that it TRACKS the radius rather than a constant.
            if (cut > want + 3) f.Add($"{style}: cut {cut}px for radius {want}");
        }
        if (measured.TryGetValue(BackdropCornerStyle.None, out var none) && none > 1)
            f.Add($"None still rounds ({none}px)");
        if (measured.TryGetValue(BackdropCornerStyle.Small, out var small)
            && measured.TryGetValue(BackdropCornerStyle.Large, out var large)
            && large <= small)
            f.Add($"Large ({large}) does not round more than Small ({small})");
        if (measured.TryGetValue(BackdropCornerStyle.Medium, out var medium)
            && medium <= (int)BackdropSpec.CornerRadiusPt / 2)
            f.Add($"Medium on a 400px edge is still the old fixed corner ({medium}px)");

        // And the preview cuts the same corner as the export, at each style.
        foreach (var style in new[] { BackdropCornerStyle.Small, BackdropCornerStyle.Large })
        {
            var layout = new BackdropLayout(new Size(600, 400), 1, BackdropPreset.Ocean);
            var pad = (int)layout.Pad;
            using var preview = new Bitmap(
                layout.OuterSize.Width, layout.OuterSize.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(preview))
            {
                using (var basecoat = new SolidBrush(
                    BackdropSpec.GradientStops(BackdropPreset.Ocean)[0].Color))
                    g.FillRectangle(basecoat, 0, 0, preview.Width, preview.Height);
                BackdropRender.DrawFrameForPreview(
                    g, new RectangleF(pad, pad, 600, 400), 1f, BackdropPreset.Ocean, style);
                var state = g.Save();
                using (var plate = BackdropRender.RoundedRect(
                    new RectangleF(pad, pad, 600, 400),
                    BackdropSpec.CornerRadius(new Size(600, 400), style)))
                using (var brush = new TextureBrush(doc) { WrapMode = WrapMode.Clamp })
                {
                    brush.TranslateTransform(pad, pad);
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.FillPath(brush, plate);
                }
                g.Restore(state);
            }
            using var exported = BackdropRender.Compose(
                doc, BackdropPreset.Ocean, corners: style)!;
            var previewCut = CutAt(preview, pad);
            var exportCut = CutAt(exported, pad);
            if (previewCut < 0 || exportCut < 0 || Math.Abs(previewCut - exportCut) > 2)
                f.Add($"{style}: preview cuts {previewCut}px, export {exportCut}px");
        }
        return f;
    }

    /// With a preset on, the review surface still shows the DOCUMENT.
    ///
    /// The frame's fill covers the whole outer rect, so a surface that paints
    /// it over the desktop and stops leaves the user reviewing a rectangle of
    /// gradient — which is what the first smoke run photographed. The gate that
    /// existed checked the PAYLOAD, and the payload was always right; nothing
    /// looked at the preview.
    static List<string> ReviewPreviewShowsDocument()
    {
        var f = new List<string>();
        var crop = new Rectangle(200, 150, 400, 300);
        using var desktop = CheckeredDocument(
            1000, 700, Color.FromArgb(255, 20, 200, 90), Color.FromArgb(255, 245, 245, 245));

        foreach (var preset in new[] { BackdropPreset.Ocean, BackdropPreset.Graphite })
        {
            using var canvas = new Bitmap(1000, 700, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(canvas))
            {
                g.DrawImageUnscaled(desktop, 0, 0);
                AreaReviewPreview.Paint(
                    g, desktop, crop, preset, BackdropCornerStyle.Medium);
            }
            // The middle of the crop is the document, pixel for pixel.
            int wrong = 0;
            for (int y = crop.Top + 40; y < crop.Bottom - 40; y += 7)
                for (int x = crop.Left + 40; x < crop.Right - 40; x += 7)
                    if (!Near(At(canvas, x, y), At(desktop, x, y), 6)) wrong++;
            if (wrong > 0) f.Add($"{preset}: {wrong} document pixels covered by the frame");

            // …and the frame IS there, outside it: the padding is no longer
            // desktop.
            var pad = (int)new BackdropLayout(crop.Size, 1, preset).Pad;
            var outside = new Point(crop.Left - pad / 2, crop.Top + crop.Height / 2);
            if (Near(At(canvas, outside.X, outside.Y), At(desktop, outside.X, outside.Y), 6))
                f.Add($"{preset}: no frame drawn beside the crop");

            // The corner is cut: a pixel just inside the crop's square corner
            // belongs to the frame, not to the document.
            var cornerPixel = At(canvas, crop.Left + 2, crop.Top + 2);
            if (Near(cornerPixel, At(desktop, crop.Left + 2, crop.Top + 2), 6))
                f.Add($"{preset}: crop corner is square in the preview");
        }
        return f;
    }

    // ---------- the chrome paints its own colours ----------

    /// Every pixel of the overlay chrome is one this app named.
    ///
    /// The rail, the strip and all twenty-one buttons were WinForms `Control`s
    /// that set no background colour of their own, under a parent whose
    /// BackColor was `Color.Transparent`. A child does NOT inherit that unless
    /// it supports transparency itself — WinForms hands it
    /// `SystemColors.Control` instead. So every overlay button was a #F0F0F0
    /// slab of whatever the Windows theme said, with an icon drawn on it, and
    /// nothing inside the app could notice: the colour came from outside it.
    ///
    /// This paints the chrome over a sentinel and asks two things of every
    /// pixel — that the chrome covered it, and that what it put there came
    /// from `Theme` and not from the desktop.
    static List<string> OverlayChromePixels()
    {
        var f = new List<string>();
        // Magenta: nothing in the chrome's palette is anywhere near it, so a
        // surviving sentinel pixel means nobody painted that pixel.
        var sentinel = Color.FromArgb(255, 255, 0, 255);
        var system = SystemColors.Control;

        foreach (int dpi in new[] { 96, 120, 144, 192 })
        {
            var button = new Rectangle(
                20, 20, Theme.Px(Theme.OverlayBtnW, dpi), Theme.Px(Theme.OverlayBtnH, dpi));
            (string Name, bool Hover, bool Press, bool Ticked, bool Enabled)[] states =
            [
                ("normal", false, false, false, true),
                ("hover", true, false, false, true),
                ("pressed", false, true, false, true),
                ("checked", false, false, true, true),
                ("disabled", false, false, false, false),
            ];
            var probes = new Dictionary<string, Color>();
            foreach (var (name, hover, press, ticked, enabled) in states)
            {
                using var bmp = Sentinel(button.Right + 40, button.Bottom + 40, sentinel);
                using (var g = Graphics.FromImage(bmp))
                    OverlayChrome.PaintButton(
                        g, button, "rect", dpi,
                        hover: hover, pressed: press, isChecked: ticked,
                        enabled: enabled, tint: null);

                int bare = 0, systemColoured = 0;
                string first = "";
                for (int y = button.Top; y < button.Bottom; y++)
                    for (int x = button.Left; x < button.Right; x++)
                    {
                        var c = At(bmp, x, y);
                        if (c.ToArgb() == sentinel.ToArgb())
                        {
                            bare++;
                            if (first.Length == 0) first = $" first@{x},{y}";
                        }
                        if (Near(c, system, 6)) systemColoured++;
                    }
                if (bare > 0) f.Add($"{dpi}dpi {name}: {bare}px unpainted{first}");
                if (systemColoured > 0)
                    f.Add($"{dpi}dpi {name}: {systemColoured}px of SystemColors.Control");
                // …and nothing outside the button's own box is painted, or a
                // button would smear over the plate it sits on.
                if (At(bmp, button.Right + 2, button.Top + 2).ToArgb() != sentinel.ToArgb())
                    f.Add($"{dpi}dpi {name}: painted outside its bounds");
                // Inside the state pill, clear of the icon: the icon starts a
                // quarter of the way in at every DPI.
                probes[name] = At(bmp, button.Left + 3, button.Top + button.Height / 2);
            }

            // A resting button IS the plate, so the rail reads as one object
            // rather than as tiles laid on one.
            var resting = probes["normal"];
            if (!Near(resting, OverlayChrome.Plate, 0))
                f.Add($"{dpi}dpi: resting button is {resting}, not the plate");
            // And every state the user can put it in looks different from
            // resting. On the white background these all but vanished, which
            // is the other half of "the buttons feel wrong".
            foreach (var name in new[] { "hover", "pressed", "checked" })
                if (Near(probes[name], resting, 2))
                    f.Add($"{dpi}dpi: {name} is indistinguishable from normal");
            if (Near(probes["hover"], probes["pressed"], 2))
                f.Add($"{dpi}dpi: pressed is indistinguishable from hover");
        }

        foreach (int dpi in new[] { 96, 144 })
        {
            var frame = new Rectangle(10, 10, 200, 140);
            using var bmp = Sentinel(240, 180, sentinel);
            using (var g = Graphics.FromImage(bmp))
                OverlayChrome.PaintPlate(g, frame, dpi);
            var middle = At(bmp, frame.Left + frame.Width / 2, frame.Top + frame.Height / 2);
            if (!Near(middle, OverlayChrome.Plate, 0))
                f.Add($"{dpi}dpi plate: centre is {middle}, not the plate colour");
            if (Near(middle, system, 6))
                f.Add($"{dpi}dpi plate: centre is SystemColors.Control");
            if (At(bmp, frame.Right + 4, frame.Top + 4).ToArgb() != sentinel.ToArgb())
                f.Add($"{dpi}dpi plate: painted outside its frame");
            // The corner is cut, and cut no further than its radius: the
            // extreme corner is untouched, a pixel a radius in is solid plate.
            if (Near(At(bmp, frame.Left, frame.Top), OverlayChrome.Plate, 8))
                f.Add($"{dpi}dpi plate: corner is square");
            int r = Theme.Px(Theme.RadiusChrome, dpi);
            if (!Near(At(bmp, frame.Left + r + 2, frame.Top + r + 2), OverlayChrome.Plate, 0))
                f.Add($"{dpi}dpi plate: cut further in than its own radius");
        }
        return f;
    }

    static Bitmap Sentinel(int width, int height, Color colour)
    {
        var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        using var brush = new SolidBrush(colour);
        g.FillRectangle(brush, 0, 0, width, height);
        return bmp;
    }

    // ---------- the redaction still redacts ----------

    /// `Pixelate` stopped staging the picture through two managed byte[]s and
    /// now reads and writes the locked bits directly — three full-size buffers
    /// down to one, and no copy of every pixel before any block is averaged.
    ///
    /// That is a rewrite of the code that REDACTS, so "it looks about right"
    /// is not a standard anyone should accept. This runs the implementation
    /// the app ships beside a transcription of the one it replaced and demands
    /// they agree on every pixel, at sizes that are not multiples of the block
    /// (where the partial edge blocks live) and at blocks of 1 and 7 as well
    /// as the default 14.
    static List<string> PixelateMatchesReference()
    {
        var f = new List<string>();
        (int W, int H)[] sizes = [(64, 48), (61, 47), (14, 14), (15, 3), (1, 1), (97, 128)];
        int[] blocks = [14, 1, 7];
        foreach (var (w, h) in sizes)
        {
            foreach (var block in blocks)
            {
                using var src = Noise(w, h, (uint)(w * 7919 + h * 104729 + block));
                using var got = AnnotationRenderer.Pixelate(src, block);
                using var want = ReferencePixelate(src, block);
                if (got.Width != want.Width || got.Height != want.Height)
                {
                    f.Add($"{w}x{h}/{block}: size {got.Width}x{got.Height}");
                    continue;
                }
                int wrong = 0, changed = 0;
                string first = "";
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        var a = At(got, x, y);
                        var b = At(want, x, y);
                        if (a.ToArgb() != b.ToArgb())
                        {
                            wrong++;
                            if (first.Length == 0) first = $" first@{x},{y} {a} vs {b}";
                        }
                        if (a.ToArgb() != At(src, x, y).ToArgb()) changed++;
                    }
                if (wrong > 0) f.Add($"{w}x{h}/{block}: {wrong}px differ{first}");
                // Positive premise: at a block wider than a pixel the redaction
                // has to actually move pixels, or this compares two copies of
                // the source and would pass however broken both were.
                if (block > 1 && w > 1 && h > 1 && changed == 0)
                    f.Add($"{w}x{h}/{block}: redaction changed nothing");
            }
        }
        return f;
    }

    /// The staging implementation `Pixelate` replaced, kept here as the oracle.
    /// Deliberately a transcription — if it is "tidied" to share code with the
    /// thing it checks, it stops checking anything.
    static Bitmap ReferencePixelate(Bitmap src, int block)
    {
        block = Math.Max(1, block);
        int w = src.Width, h = src.Height;
        var bounds = new Rectangle(0, 0, w, h);
        var result = new Bitmap(w, h, PixelFormat.Format32bppArgb);

        var srcData = src.LockBits(bounds, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var pixels = new byte[srcData.Stride * h];
        System.Runtime.InteropServices.Marshal.Copy(srcData.Scan0, pixels, 0, pixels.Length);
        src.UnlockBits(srcData);

        var dstData = result.LockBits(bounds, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var outPixels = new byte[dstData.Stride * h];
        for (int by = 0; by < h; by += block)
        {
            int yEnd = Math.Min(by + block, h);
            for (int bx = 0; bx < w; bx += block)
            {
                int xEnd = Math.Min(bx + block, w);
                long b = 0, g2 = 0, r = 0, a = 0;
                int count = (xEnd - bx) * (yEnd - by);
                for (int y = by; y < yEnd; y++)
                {
                    int row = y * srcData.Stride;
                    for (int x = bx; x < xEnd; x++)
                    {
                        int i = row + x * 4;
                        b += pixels[i];
                        g2 += pixels[i + 1];
                        r += pixels[i + 2];
                        a += pixels[i + 3];
                    }
                }
                byte ab = (byte)(b / count), ag = (byte)(g2 / count);
                byte ar = (byte)(r / count), aa = (byte)(a / count);
                for (int y = by; y < yEnd; y++)
                {
                    int row = y * dstData.Stride;
                    for (int x = bx; x < xEnd; x++)
                    {
                        int i = row + x * 4;
                        outPixels[i] = ab;
                        outPixels[i + 1] = ag;
                        outPixels[i + 2] = ar;
                        outPixels[i + 3] = aa;
                    }
                }
            }
        }
        System.Runtime.InteropServices.Marshal.Copy(outPixels, 0, dstData.Scan0, outPixels.Length);
        result.UnlockBits(dstData);
        return result;
    }

    /// Deterministic noise, so a failure is reproducible and a block average
    /// is not the same number everywhere.
    static Bitmap Noise(int w, int h, uint seed)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        uint state = seed | 1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5;
                bmp.SetPixel(x, y, Color.FromArgb(
                    (int)(160 + (state >> 24) % 96),
                    (int)(state & 0xFF),
                    (int)((state >> 8) & 0xFF),
                    (int)((state >> 16) & 0xFF)));
            }
        return bmp;
    }

    // ---------- still RED ----------

    /// The pixels each kind of route receives. Which route is which is the
    /// parity gate's `win-backdrop-route-table`; this checks that the two
    /// readings really are one freeze seen twice — the visual one framed, the
    /// semantic one untouched. That the editor calls through the table is
    /// wiring, and is on the owner's RC checklist.
    static List<string> ExportRoutes()
    {
        var f = new List<string>();
        using var doc = CheckeredDocument(
            320, 240, Color.FromArgb(255, 20, 200, 90), Color.FromArgb(255, 245, 245, 245));
        var blur = new BlurAnnotation { Rect = new Rectangle(40, 40, 60, 60) };
        using var pixelated = AnnotationRenderer.Pixelate(doc);
        using var inner = AnnotationRenderer.Flatten(doc, [blur], pixelated);

        var layout = new BackdropLayout(new Size(320, 240), 1, BackdropPreset.Mint);
        using var visual = BackdropRender.Compose(inner, BackdropPreset.Mint)!;
        if (visual.Width != layout.OuterSize.Width || visual.Height != layout.OuterSize.Height)
            f.Add($"visual {visual.Width}x{visual.Height} want {layout.OuterSize}");
        // The semantic reading is the document, at the document's size.
        if (inner.Width != 320 || inner.Height != 240)
            f.Add($"semantic {inner.Width}x{inner.Height}");

        // Same freeze: the marks are in BOTH readings, at the same place, and
        // the frame is only around the outside.
        var pad = (int)layout.Pad;
        for (int i = 0; i < 12; i++)
        {
            var x = 30 + i * 20;
            var innerPixel = At(inner, x, 70);
            var visualPixel = At(visual, x + pad, 70 + pad);
            if (!Near(innerPixel, visualPixel, 2))
                f.Add($"@{x}: framed {visualPixel} vs document {innerPixel}");
        }
        // The redaction survived into both, so the comparison above is not
        // being made between two copies of an unmarked image. Counted over the
        // whole covered area rather than at one point: a pixelated block can
        // land on the value that was already there.
        int changed = 0;
        for (int y = blur.Rect.Top + 2; y < blur.Rect.Bottom - 2; y++)
            for (int x = blur.Rect.Left + 2; x < blur.Rect.Right - 2; x++)
                if (!Near(At(inner, x, y), At(doc, x, y), 2)) changed++;
        var covered = (blur.Rect.Width - 4) * (blur.Rect.Height - 4);
        if (changed * 2 < covered)
            f.Add($"redaction missing from the document reading ({changed}/{covered})");

        // `.none` adds nothing at all — the same object comes back, so no
        // route can quietly pay for a copy.
        if (!ReferenceEquals(BackdropRender.Compose(inner, BackdropPreset.None), inner))
            f.Add("none allocated");
        return f;
    }


}
