using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace Snippr;

/// All coordinates are in image pixel space.
abstract class Annotation
{
    public Color Color = Color.Red;
    public float Width = 3f;

    public abstract Rectangle Bounds { get; }
    public abstract void Draw(Graphics g, Bitmap? pixelated);
    public abstract Annotation Clone();
    public virtual bool HitTest(Point p) =>
        Rectangle.Inflate(Bounds, 8, 8).Contains(p);
    public abstract void Move(int dx, int dy);

    protected static float DistToSegment(PointF p, PointF a, PointF b)
    {
        float abx = b.X - a.X, aby = b.Y - a.Y;
        float lenSq = abx * abx + aby * aby;
        if (lenSq < 0.01f) return Dist(p, a);
        float t = Math.Clamp(((p.X - a.X) * abx + (p.Y - a.Y) * aby) / lenSq, 0, 1);
        return Dist(p, new PointF(a.X + t * abx, a.Y + t * aby));
    }

    protected static float Dist(PointF a, PointF b) =>
        (float)Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
}

sealed class ShapeAnnotation : Annotation
{
    public enum Kind { Arrow, Line, Rect, Oval, Highlight }
    public Kind Shape;
    public Point Start, End;

    public override Rectangle Bounds => Rectangle.FromLTRB(
        Math.Min(Start.X, End.X), Math.Min(Start.Y, End.Y),
        Math.Max(Start.X, End.X), Math.Max(Start.Y, End.Y));

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        using var pen = new Pen(Color, Width)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round,
        };
        var b = Bounds;
        switch (Shape)
        {
            case Kind.Line:
                g.DrawLine(pen, Start, End);
                break;
            case Kind.Arrow:
                DrawArrow(g, pen);
                break;
            case Kind.Rect:
                if (b.Width > 0 && b.Height > 0) g.DrawRectangle(pen, b);
                break;
            case Kind.Oval:
                if (b.Width > 0 && b.Height > 0) g.DrawEllipse(pen, b);
                break;
            case Kind.Highlight:
                using (var hl = new SolidBrush(Color.FromArgb(90, Color)))
                    g.FillRectangle(hl, b);
                break;
        }
    }

    void DrawArrow(Graphics g, Pen pen)
    {
        float dx = End.X - Start.X, dy = End.Y - Start.Y;
        float len = Math.Max(1, (float)Math.Sqrt(dx * dx + dy * dy));
        float angle = (float)Math.Atan2(dy, dx);
        float headLen = Math.Min(len * 0.35f, 16 + Width * 2.2f);
        float headWidth = headLen * 0.62f;

        var baseP = new PointF(
            End.X - (float)Math.Cos(angle) * headLen,
            End.Y - (float)Math.Sin(angle) * headLen);
        var perp = new PointF(-(float)Math.Sin(angle), (float)Math.Cos(angle));
        var p1 = new PointF(baseP.X + perp.X * headWidth / 2, baseP.Y + perp.Y * headWidth / 2);
        var p2 = new PointF(baseP.X - perp.X * headWidth / 2, baseP.Y - perp.Y * headWidth / 2);

        g.DrawLine(pen, Start, Point.Round(baseP));
        using var brush = new SolidBrush(Color);
        g.FillPolygon(brush, new[] { (PointF)End, p1, p2 });
    }

    public override bool HitTest(Point p)
    {
        float pad = 8 + Width;
        switch (Shape)
        {
            case Kind.Line:
            case Kind.Arrow:
                return DistToSegment(p, Start, End) < pad;
            case Kind.Highlight:
                return Bounds.Contains(p);
            default:
                var outer = Rectangle.Inflate(Bounds, (int)pad, (int)pad);
                var inner = Rectangle.Inflate(Bounds, -(int)pad, -(int)pad);
                return outer.Contains(p) && !(inner.Width > 0 && inner.Height > 0 && inner.Contains(p));
        }
    }

    public override void Move(int dx, int dy)
    {
        Start.Offset(dx, dy);
        End.Offset(dx, dy);
    }

    public override Annotation Clone() =>
        new ShapeAnnotation { Shape = Shape, Start = Start, End = End, Color = Color, Width = Width };
}

sealed class PenAnnotation : Annotation
{
    public List<Point> Points = new();

    public override Rectangle Bounds
    {
        get
        {
            if (Points.Count == 0) return Rectangle.Empty;
            int minX = Points.Min(p => p.X), minY = Points.Min(p => p.Y);
            int maxX = Points.Max(p => p.X), maxY = Points.Max(p => p.Y);
            return Rectangle.FromLTRB(minX, minY, maxX, maxY);
        }
    }

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        if (Points.Count < 2) return;
        using var pen = new Pen(Color, Width)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round,
        };
        g.DrawCurve(pen, Points.ToArray(), 0.35f);
    }

    public override bool HitTest(Point p)
    {
        float pad = 8 + Width;
        for (int i = 0; i + 1 < Points.Count; i++)
            if (DistToSegment(p, Points[i], Points[i + 1]) < pad) return true;
        return false;
    }

    public override void Move(int dx, int dy)
    {
        for (int i = 0; i < Points.Count; i++)
            Points[i] = new Point(Points[i].X + dx, Points[i].Y + dy);
    }

    public override Annotation Clone() =>
        new PenAnnotation { Points = new List<Point>(Points), Color = Color, Width = Width };
}

sealed class TextAnnotation : Annotation
{
    public string Text = "";
    public Point Origin;
    public float FontSize = 20f;

    Font MakeFont() => new("Segoe UI", FontSize, FontStyle.Bold, GraphicsUnit.Pixel);

    // Measure with the SAME engine that draws (GDI+ DrawString). The old
    // TextRenderer.MeasureText is GDI, whose metrics drift from DrawString's
    // by several px on long strings — selection marquee and hit-testing then
    // miss the visible glyphs.
    static readonly Bitmap MeasureBitmap = new(1, 1);
    static readonly Graphics MeasureGraphics = Graphics.FromImage(MeasureBitmap);

    public override Rectangle Bounds
    {
        get
        {
            using var f = MakeFont();
            var size = MeasureGraphics.MeasureString(Text.Length == 0 ? " " : Text, f);
            return new Rectangle(Origin, Size.Ceiling(size));
        }
    }

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        if (Text.Length == 0) return;
        using var f = MakeFont();
        using var shadow = new SolidBrush(Color.FromArgb(140, Color.Black));
        using var brush = new SolidBrush(Color);
        g.DrawString(Text, f, shadow, Origin.X + 1.5f, Origin.Y + 1.5f);
        g.DrawString(Text, f, brush, Origin.X, Origin.Y);
    }

    public override void Move(int dx, int dy) => Origin.Offset(dx, dy);

    public override Annotation Clone() =>
        new TextAnnotation { Text = Text, Origin = Origin, FontSize = FontSize, Color = Color };
}

sealed class CounterAnnotation : Annotation
{
    public Point Center;
    public int Number = 1;
    public int Radius = 16;

    public override Rectangle Bounds =>
        new(Center.X - Radius, Center.Y - Radius, Radius * 2, Radius * 2);

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        using var brush = new SolidBrush(Color);
        using var shadow = new SolidBrush(Color.FromArgb(90, Color.Black));
        var b = Bounds;
        b.Offset(1, 2);
        g.FillEllipse(shadow, b);
        g.FillEllipse(brush, Bounds);
        using var f = new Font("Segoe UI", Radius * 1.05f, FontStyle.Bold, GraphicsUnit.Pixel);
        var text = Number.ToString();
        var size = g.MeasureString(text, f);
        g.DrawString(text, f, Brushes.White,
            Center.X - size.Width / 2, Center.Y - size.Height / 2);
    }

    public override bool HitTest(Point p) => Dist(p, Center) <= Radius + 6;

    public override void Move(int dx, int dy) => Center.Offset(dx, dy);

    public override Annotation Clone() =>
        new CounterAnnotation { Center = Center, Number = Number, Radius = Radius, Color = Color };
}

sealed class BlurAnnotation : Annotation
{
    public Rectangle Rect;

    public override Rectangle Bounds => Rect;

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        if (pixelated == null || Rect.Width < 2 || Rect.Height < 2) return;
        var state = g.Save();
        g.SetClip(Rect);
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.DrawImage(pixelated, 0, 0, pixelated.Width, pixelated.Height);
        g.Restore(state);
    }

    public override bool HitTest(Point p) => Rect.Contains(p);

    public override void Move(int dx, int dy) => Rect.Offset(dx, dy);

    public override Annotation Clone() => new BlurAnnotation { Rect = Rect };
}

/// Lights one rectangle by dimming everything around it. The hole IS the
/// object: clicking the lit area selects the spotlight, clicking the dimmed
/// surround does not.
///
/// WP8 parity (macOS 1.2.14): preference `multipleSpotlight` (default ON)
/// allows several holes. Each Draw() still paints a full-canvas dim, so two
/// calls stack darkness and overlapping Alternate-fill flips the intersection
/// back to dim. Port must union holes in AnnotationCompositor (one dim layer,
/// punch with CompositingMode.SourceCopy/Color.Transparent — not even-odd).
sealed class SpotlightAnnotation : Annotation
{
    public Rectangle Rect;
    /// The area to dim — the document, normally. Empty means "just my rect",
    /// which dims nothing and is how a half-built spotlight stays invisible.
    public Rectangle BaseBounds;
    /// 0.1 … 0.9, driven by the number keys.
    public float DimFraction = 0.6f;

    public override Rectangle Bounds => Rect;

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        var canvas = BaseBounds.IsEmpty ? Rect : BaseBounds;
        if (canvas.Width <= 0 || canvas.Height <= 0) return;
        var state = g.Save();
        using var path = new GraphicsPath { FillMode = FillMode.Alternate };
        path.AddRectangle(canvas);
        path.AddRectangle(Rect);
        var alpha = (int)Math.Round(Math.Clamp(DimFraction, 0.1f, 0.9f) * 255);
        using var brush = new SolidBrush(Color.FromArgb(alpha, Color.Black));
        g.FillPath(brush, path);
        g.Restore(state);
    }

    public override bool HitTest(Point p) => Rect.Contains(p);

    public override void Move(int dx, int dy) => Rect.Offset(dx, dy);

    public override Annotation Clone() => new SpotlightAnnotation
    {
        Rect = Rect, BaseBounds = BaseBounds, DimFraction = DimFraction,
        Color = Color,
    };
}

/// A loupe: the pixels under `SourceRect`, enlarged, drawn at `CalloutRect`.
///
/// `Snapshot` is sampled ONCE, after the redactions, and kept — so a callout
/// can never resurrect pixels a pixelation covers, and it does not re-read the
/// document every repaint. Dragging moves the callout only: re-aiming the
/// source would show pixels the user never chose.
sealed class MagnifierAnnotation : Annotation
{
    public Rectangle SourceRect;
    public Rectangle CalloutRect;
    public Bitmap? Snapshot;

    public override Rectangle Bounds => CalloutRect;

    /// Review and editor share this so a live preview cannot be sized from a
    /// different default than the committed loupe.
    public const float DefaultZoom = CalloutPlacement.DefaultZoom;

    /// Where the callout for `source` sits. Same law as Mac
    /// `MagnifierAnnotation.calloutRect` (f6f475c): right, left, below,
    /// above — first side that holds `zoom`, else the roomiest, never below
    /// 1×, overlap only when the document cannot hold a 1× loupe beside the
    /// source. The arithmetic lives in `CalloutPlacement` so the parity gate
    /// can run it without GDI+; this is still the one function every caller
    /// uses, so a live drag cannot park somewhere the committed loupe will
    /// not.
    public static Rectangle PlaceCallout(
        Rectangle source, Rectangle bounds, float zoom = DefaultZoom)
        => CalloutPlacement.Place(source, bounds, zoom);

    public override void Draw(Graphics g, Bitmap? pixelated)
    {
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.None;
        g.PixelOffsetMode = PixelOffsetMode.None;
        if (Snapshot != null && CalloutRect.Width > 1 && CalloutRect.Height > 1)
        {
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            // A soft drop shadow, then the patch, then the ring — the same
            // order the macOS callout uses, so the two look like one feature.
            using (var shadow = new SolidBrush(Color.FromArgb(70, Color.Black)))
            {
                var below = CalloutRect;
                below.Offset(0, 2);
                below.Inflate(2, 2);
                g.FillRectangle(shadow, below);
            }
            g.DrawImage(Snapshot, CalloutRect);
            using var pen = new Pen(Color.White, 2);
            g.DrawRectangle(pen, CalloutRect);
            DrawSourceFrame(g, SourceRect);
        }
        else if (Snapshot == null)
        {
            // Nothing sampled yet, so nothing can leak: show the geometry
            // only. The dashed outline is where the callout will land.
            if (CalloutRect.Width > 1 && CalloutRect.Height > 1)
                DrawCalloutOutline(g, CalloutRect);
            DrawSourceFrame(g, SourceRect);
        }
        g.Restore(state);
    }

    /// 1 px dark line outside SourceRect, 1 px white line on its outermost
    /// row and column: visible on light and dark pixels alike. The interior
    /// of the source stays untouched.
    static void DrawSourceFrame(Graphics g, Rectangle src)
    {
        if (src.Width <= 1 || src.Height <= 1) return;
        var dark = Color.FromArgb(140, 0, 0, 0);
        StrokeRect(g, Rectangle.Inflate(src, 1, 1), dark, dashed: false);
        StrokeRect(g, src, Color.White, dashed: false);
    }

    static void DrawCalloutOutline(Graphics g, Rectangle callout)
    {
        var dark = Color.FromArgb(140, 0, 0, 0);
        StrokeRect(g, Rectangle.Inflate(callout, 1, 1), dark, dashed: true);
        StrokeRect(g, callout, Color.White, dashed: true);
    }

    static void StrokeRect(Graphics g, Rectangle r, Color color, bool dashed)
    {
        if (r.Width <= 0 || r.Height <= 0) return;
        using var brush = new SolidBrush(color);
        void Dash(int x, int y, int w, int h, bool horizontal)
        {
            if (!dashed)
            {
                g.FillRectangle(brush, x, y, w, h);
                return;
            }
            const int on = 4, off = 3;
            int span = horizontal ? w : h;
            int pos = 0;
            while (pos < span)
            {
                int n = Math.Min(on, span - pos);
                if (horizontal) g.FillRectangle(brush, x + pos, y, n, h);
                else g.FillRectangle(brush, x, y + pos, w, n);
                pos += on + off;
            }
        }
        Dash(r.X, r.Y, r.Width, 1, horizontal: true);
        Dash(r.X, r.Bottom - 1, r.Width, 1, horizontal: true);
        Dash(r.X, r.Y, 1, r.Height, horizontal: false);
        Dash(r.Right - 1, r.Y, 1, r.Height, horizontal: false);
    }

    public override bool HitTest(Point p) => CalloutRect.Contains(p);

    /// The callout travels; the source stays where it was aimed.
    public override void Move(int dx, int dy) => CalloutRect.Offset(dx, dy);

    /// A crop moves the whole document under the annotation, so BOTH rects
    /// travel — otherwise the loupe would point at different pixels than the
    /// ones the user picked.
    public void TranslateForDocumentChange(int dx, int dy)
    {
        SourceRect.Offset(dx, dy);
        CalloutRect.Offset(dx, dy);
    }

    public override Annotation Clone() => new MagnifierAnnotation
    {
        SourceRect = SourceRect, CalloutRect = CalloutRect,
        // The patch is immutable once sampled, so clones share it rather than
        // each holding a copy of the same pixels.
        Snapshot = Snapshot, Color = Color,
    };
}

static class AnnotationRenderer
{
    /// Flatten base + annotations into a new bitmap.
    ///
    /// It goes through the compositor, like the preview does: phase order and
    /// the magnifier's crop boundary must not be something only one of the two
    /// knows about.
    public static Bitmap Flatten(
        Bitmap baseImage, IEnumerable<Annotation> annotations, Bitmap? pixelated,
        Rectangle? visiblePixels = null)
    {
        var result = new Bitmap(baseImage.Width, baseImage.Height,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(result);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.DrawImageUnscaled(baseImage, 0, 0);
        AnnotationCompositor.Draw(
            annotations, g, baseImage,
            visiblePixels ?? new Rectangle(0, 0, baseImage.Width, baseImage.Height),
            pixelated);
        return result;
    }

    /// Blocky pixelated copy used by BlurAnnotation.
    /// Blocky pixelated copy used by BlurAnnotation.
    ///
    /// Every block is the AVERAGE of the pixels it covers, computed here
    /// rather than by asking GDI+ to shrink the image. Its downscaler is not
    /// an area filter: at a 14× reduction it samples rather than averages, so
    /// a block could come back as one source pixel's exact colour — a redaction
    /// that hands back original values, and one the magnifier gate caught
    /// carrying pure source red through a "pixelated" area. Averaging also
    /// matches what the macOS build produces, so a redaction looks the same on
    /// both platforms.
    public static Bitmap Pixelate(Bitmap src, int block = 14)
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
}
