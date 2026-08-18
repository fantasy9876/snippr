using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace Snippr;

/// The backdrop, rasterized. Every number it uses comes from `BackdropSpec`;
/// this file only knows how to put them on a surface with GDI+.
///
/// One deliberate difference from macOS, written down because it is the kind
/// of thing that gets rediscovered as a bug: CoreGraphics blends the grain
/// with an `overlay` mode, which GDI+ does not have. The tile's BYTES are the
/// spec's — same hash, same ±2/255 — but they are applied as translucent
/// white/black over the ramp, which is what overlay does either side of mid
/// grey. The raster gate pins the result to ±3/255 of the ramp beneath it.
static class BackdropRender
{
    /// Paints the frame's background across `size`, and NOWHERE else.
    ///
    /// It clips itself: a gradient has no bounds and a texture brush repeats
    /// until something stops it, so in a bitmap the buffer edge hid the
    /// overflow while a window context let the backdrop run across the whole
    /// form. The macOS build shipped exactly that bug.
    public static void DrawFill(
        Graphics g, SizeF size, BackdropPreset preset, float documentPixelsPerUserUnit = 1)
    {
        if (preset == BackdropPreset.None || size.Width <= 0 || size.Height <= 0) return;
        var canvas = new RectangleF(0, 0, size.Width, size.Height);
        var state = g.Save();
        g.SetClip(canvas, CombineMode.Intersect);
        // The background is rectangles, and antialiasing them is not just
        // pointless — an antialiased fill (and an antialiased CLIP) leaves the
        // outermost row and column only partly covered, so the exported frame
        // came back with alpha below 255 all the way round its edge. A frame
        // with a translucent border prints as a dark fringe wherever it lands
        // on something else. The rounded plate and the hairline still get
        // antialiasing; they ask for it below.
        g.SmoothingMode = SmoothingMode.None;
        g.PixelOffsetMode = PixelOffsetMode.Half;

        var stops = BackdropSpec.GradientStops(preset);
        var (start, end) = BackdropSpec.GradientAxis(size.Width, size.Height);
        using (var ramp = new LinearGradientBrush(start, end, stops[0].Color, stops[^1].Color))
        {
            ramp.InterpolationColors = new ColorBlend(stops.Length)
            {
                Colors = stops.Select(s => s.Color).ToArray(),
                Positions = stops.Select(s => s.Location).ToArray(),
            };
            // The brush is defined by two points, not by a rect, so it has to
            // be told to hold its last colour past the end instead of tiling
            // the ramp back on itself.
            ramp.WrapMode = WrapMode.TileFlipXY;
            g.FillRectangle(ramp, canvas);
        }

        var (centre, edge) = BackdropSpec.RadialWash(preset);
        if (centre.A > 0)
        {
            var origin = BackdropSpec.WashCentre(size.Width, size.Height);
            var radius = BackdropSpec.WashRadius(size.Width, size.Height);
            using var circle = new GraphicsPath();
            circle.AddEllipse(
                origin.X - radius, origin.Y - radius, radius * 2, radius * 2);
            using var wash = new PathGradientBrush(circle)
            {
                CenterPoint = origin,
                CenterColor = centre,
                SurroundColors = [edge],
            };
            g.FillRectangle(wash, canvas);
        }

        DrawGrain(g, canvas, preset, documentPixelsPerUserUnit);
        g.Restore(state);
    }

    /// The dither that keeps an 8-bit ramp from banding. Tiled from the canvas
    /// ORIGIN every time — never from a dirty rect — so a partial repaint
    /// lands on the same pattern as a full one.
    static void DrawGrain(
        Graphics g, RectangleF canvas, BackdropPreset preset, float documentPixelsPerUserUnit)
    {
        using var tile = GrainBitmap(BackdropSpec.GrainSeed(preset));
        var side = BackdropSpec.GrainTileSide / Math.Max(0.0001f, documentPixelsPerUserUnit);
        using var brush = new TextureBrush(tile, WrapMode.Tile);
        brush.ScaleTransform(side / BackdropSpec.GrainTileSide, side / BackdropSpec.GrainTileSide);
        var state = g.Save();
        g.PixelOffsetMode = PixelOffsetMode.Half;
        g.FillRectangle(brush, canvas);
        g.Restore(state);
    }

    /// The spec's tile bytes turned into what GDI+ can composite: a deviation
    /// of +d becomes white at d/255 alpha, −d becomes black. Mid grey stays
    /// perfectly transparent, so the ramp shows through untouched where the
    /// hash says "no change".
    public static Bitmap GrainBitmap(uint seed)
    {
        var side = BackdropSpec.GrainTileSide;
        var bytes = BackdropSpec.GrainTile(seed);
        var bmp = new Bitmap(side, side, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(
            new Rectangle(0, 0, side, side), ImageLockMode.WriteOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            var row = new byte[data.Stride];
            for (int y = 0; y < side; y++)
            {
                for (int x = 0; x < side; x++)
                {
                    var delta = bytes[(y * side + x) * 4] - 128;
                    var lift = (byte)(delta >= 0 ? 255 : 0);
                    var alpha = (byte)Math.Min(255, Math.Abs(delta));
                    var i = x * 4;
                    // BGRA in memory, premultiplied by nothing: GDI+ blends
                    // straight alpha for Format32bppArgb.
                    row[i] = lift; row[i + 1] = lift; row[i + 2] = lift;
                    row[i + 3] = alpha;
                }
                System.Runtime.InteropServices.Marshal.Copy(
                    row, 0, data.Scan0 + y * data.Stride, data.Stride);
            }
        }
        finally { bmp.UnlockBits(data); }
        return bmp;
    }

    /// The frame around a document: fill, the plate's shadow, and the fill
    /// again inside the plate so the ramp, the wash and the grain stay
    /// continuous across the plate's edge instead of restarting there.
    public static void DrawFrame(
        Graphics g, SizeF size, RectangleF target, BackdropPreset preset,
        float pixelScale, float documentPixelsPerUserUnit = 1)
    {
        if (preset == BackdropPreset.None) return;
        var state = g.Save();
        // Nothing the frame draws may land outside the canvas it was asked
        // for — including the plate's shadow, which reaches past the plate.
        g.SetClip(new RectangleF(0, 0, size.Width, size.Height), CombineMode.Intersect);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        DrawFill(g, size, preset, documentPixelsPerUserUnit);

        var scale = Math.Max(1f, pixelScale);
        var radius = BackdropSpec.CornerRadiusPt * scale;
        using var plate = RoundedRect(target, radius);
        DrawPlateShadow(g, plate, scale);

        var inner = g.Save();
        g.SetClip(plate, CombineMode.Intersect);
        DrawFill(g, size, preset, documentPixelsPerUserUnit);
        g.Restore(inner);
        g.Restore(state);
    }

    /// GDI+ has no shadow primitive, so the plate is stamped a few times with
    /// a growing, fading outline — cheap, and close enough to a 24pt blur at
    /// the sizes a frame uses.
    static void DrawPlateShadow(Graphics g, GraphicsPath plate, float scale)
    {
        var blur = BackdropSpec.ShadowBlurPt * scale;
        var offset = BackdropSpec.ShadowOffsetPt * scale;
        var steps = Math.Max(4, (int)Math.Round(blur / 3));
        var state = g.Save();
        g.TranslateTransform(0, -offset);
        for (int i = steps; i >= 1; i--)
        {
            var spread = blur * i / steps;
            var alpha = (int)Math.Round(
                BackdropSpec.ShadowAlpha * 255 / (steps * 1.6) * (1 - (float)i / (steps + 1)) * 2);
            if (alpha <= 0) continue;
            using var pen = new Pen(Color.FromArgb(Math.Min(255, alpha), Color.Black), spread)
            {
                LineJoin = LineJoin.Round,
            };
            g.DrawPath(pen, plate);
        }
        using (var fill = new SolidBrush(Color.FromArgb((int)(BackdropSpec.ShadowAlpha * 255), Color.Black)))
            g.FillPath(fill, plate);
        g.Restore(state);
    }

    /// The 1px white line that softens the plate's clipped edge. Drawn AFTER
    /// the document and its marks and BEFORE any chrome, inside the plate's
    /// clip, so it sits on the screenshot rather than under it.
    public static void DrawPlateHairline(Graphics g, RectangleF rect, float pixelScale)
    {
        var scale = Math.Max(1f, pixelScale);
        var radius = BackdropSpec.CornerRadiusPt * scale;
        // Inset by half the line width so the whole stroke lands INSIDE the
        // plate; a centred stroke spills half of itself onto the frame.
        var inset = RectangleF.Inflate(rect, -0.5f * scale, -0.5f * scale);
        if (inset.Width <= 0 || inset.Height <= 0) return;
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = RoundedRect(inset, radius);
        using var pen = new Pen(
            Color.FromArgb(
                (int)Math.Round(BackdropSpec.HairlineAlpha * 255), Color.White),
            1 * scale);
        g.DrawPath(pen, path);
        g.Restore(state);
    }

    public static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        var d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) { path.AddRectangle(r); return path; }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    /// The exported picture: the document inside its frame. `.none` hands the
    /// input straight back — not one byte is touched, and nothing is
    /// allocated.
    public static Bitmap? Compose(Bitmap image, BackdropPreset preset, float pixelScale = 1)
    {
        if (preset == BackdropPreset.None) return image;
        var layout = new BackdropLayout(new Size(image.Width, image.Height), pixelScale, preset);
        if (layout.IsCollapsed) return image;
        var outer = layout.OuterSize;
        if (outer.Width <= 0 || outer.Height <= 0) return null;

        var result = new Bitmap(outer.Width, outer.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(result);
        // A fresh bitmap is fully transparent, and everything drawn onto it
        // blends. Laying down one opaque coat first means no combination of
        // antialiasing, clipping or a translucent grain can leave a hole in an
        // exported picture.
        using (var basecoat = new SolidBrush(
            Color.FromArgb(255, BackdropSpec.GradientStops(preset)[0].Color)))
        {
            var mode = g.CompositingMode;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.FillRectangle(basecoat, 0, 0, outer.Width, outer.Height);
            g.CompositingMode = mode;
        }
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var target = new RectangleF(
            layout.Pad, layout.Pad, image.Width, image.Height);
        DrawFrame(g, new SizeF(outer.Width, outer.Height), target, preset, pixelScale);

        var state = g.Save();
        var radius = BackdropSpec.CornerRadiusPt * Math.Max(1f, pixelScale);
        using (var plate = RoundedRect(target, radius))
        using (var document = new TextureBrush(image))
        {
            // FillPath, not SetClip. A GDI+ clip region has no antialiasing at
            // all, so clipping the document to the plate gave the corners a
            // visible staircase — the very thing the frame is there to avoid.
            // Painting the image THROUGH the path as a brush antialiases the
            // edge the way the plate's own outline is.
            // Clamp, not tile: an antialiased edge samples a hair outside the
            // image, and a tiling brush would answer with the pixels from the
            // opposite side of the picture.
            document.WrapMode = WrapMode.Clamp;
            document.TranslateTransform(target.X, target.Y);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.FillPath(document, plate);
        }
        DrawPlateHairline(g, target, pixelScale);
        g.Restore(state);
        return result;
    }
}
