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
        failed += Check("win-spotlight-dim", SpotlightDim());
        failed += Check("win-backdrop-export-routes", ExportRoutes());
        failed += Pend("win-hover-hint-clamped",
            "HoverHint (lane UI) is not merged yet");
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
        // Every pixel is opaque: a frame with holes would print as black.
        for (int i = 0; i < 40; i++)
        {
            var x = i * (framed.Width - 1) / 39;
            if (At(framed, x, 0).A != 255 || At(framed, x, framed.Height - 1).A != 255)
                f.Add("frame not opaque");
        }
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
        return f;
    }

    // ---------- magnifier privacy ----------

    static List<string> MagnifierPrivacy()
    {
        var f = new List<string>();
        var secret = new Rectangle(20, 20, 40, 40);
        var callout = new Rectangle(180, 180, 80, 80);

        Bitmap Source()
        {
            var bmp = new Bitmap(320, 300, PixelFormat.Format32bppArgb);
            using var g = Graphics.FromImage(bmp);
            using (var grey = new SolidBrush(Color.FromArgb(255, 140, 140, 140)))
                g.FillRectangle(grey, 0, 0, 320, 300);
            using (var red = new SolidBrush(Color.FromArgb(255, 255, 0, 0)))
                g.FillRectangle(red, secret);
            return bmp;
        }
        static bool IsRed(Color c) => c.R > 150 && c.G < 110 && c.B < 110;

        using var baseImage = Source();
        Bitmap Shot(Rectangle visible, IEnumerable<BlurAnnotation>? redactions = null)
        {
            var mag = new MagnifierAnnotation
            {
                SourceRect = secret,
                CalloutRect = callout,
                Snapshot = AnnotationCompositor.MagnifierSnapshot(
                    baseImage, secret, redactions ?? []),
            };
            var bmp = new Bitmap(320, 300, PixelFormat.Format32bppArgb);
            using var g = Graphics.FromImage(bmp);
            g.DrawImageUnscaled(baseImage, 0, 0);
            AnnotationCompositor.Draw([mag], g, baseImage, visible, null);
            return bmp;
        }

        // Premise: with the source wholly inside the crop the callout IS drawn.
        using (var inside = Shot(new Rectangle(0, 0, 320, 300)))
            if (!IsRed(At(inside, callout.X + 40, callout.Y + 40)))
                f.Add("inside-crop:not-drawn");
        // Wholly outside.
        using (var outside = Shot(new Rectangle(150, 150, 170, 150)))
            if (IsRed(At(outside, callout.X + 40, callout.Y + 40)))
                f.Add("outside-crop:leaked");
        // Only PARTLY outside is still a leak of the part that is out, so the
        // test is `contains`, not `intersects`.
        using (var partial = Shot(new Rectangle(40, 40, 280, 260)))
            if (IsRed(At(partial, callout.X + 40, callout.Y + 40)))
                f.Add("partial-crop:leaked");

        // And the patch is sampled AFTER the redactions: a callout over a
        // pixelated area must show the pixelation, not the pixels under it.
        var blur = new BlurAnnotation { Rect = secret };
        using (var covered = Shot(new Rectangle(0, 0, 320, 300), [blur]))
        {
            var patch = At(covered, callout.X + 40, callout.Y + 40);
            if (IsRed(patch) && patch.R > 240 && patch.G < 30)
                f.Add($"callout resurrected raw pixels {patch}");
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

    // ---------- still RED ----------

    /// The pixels each kind of route receives. Which route is which is the
    /// parity gate's `win-backdrop-route-table`; this checks that the two
    /// readings really are one freeze seen twice — the visual one framed, the
    /// semantic one untouched. That the editor calls through the table is
    /// wiring, and is on the owner's RC checklist.
    static List<string> ExportRoutes()
    {
        var f = new List<string>();
        using var doc = Document(320, 240);
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
        // The redaction survived into both, so this comparison is not being
        // made between two copies of an unmarked image.
        if (Near(At(inner, 70, 70), At(doc, 70, 70), 1))
            f.Add("redaction missing from the document reading");

        // `.none` adds nothing at all — the same object comes back, so no
        // route can quietly pay for a copy.
        if (!ReferenceEquals(BackdropRender.Compose(inner, BackdropPreset.None), inner))
            f.Add("none allocated");
        return f;
    }


}
