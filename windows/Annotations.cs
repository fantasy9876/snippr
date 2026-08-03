using System.Drawing.Drawing2D;

namespace Snippr;

enum Tool { Select, Arrow, Line, Rect, Oval, Highlight, Pen, Text, Counter, Blur, Crop }

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

    public override Rectangle Bounds
    {
        get
        {
            using var f = MakeFont();
            var size = TextRenderer.MeasureText(Text.Length == 0 ? " " : Text, f);
            return new Rectangle(Origin, size);
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

static class AnnotationRenderer
{
    /// Flatten base + annotations into a new bitmap.
    public static Bitmap Flatten(Bitmap baseImage, IEnumerable<Annotation> annotations, Bitmap? pixelated)
    {
        var result = new Bitmap(baseImage.Width, baseImage.Height,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(result);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.DrawImageUnscaled(baseImage, 0, 0);
        foreach (var a in annotations) a.Draw(g, pixelated);
        return result;
    }

    /// Blocky pixelated copy used by BlurAnnotation.
    public static Bitmap Pixelate(Bitmap src, int block = 14)
    {
        int sw = Math.Max(1, src.Width / block), sh = Math.Max(1, src.Height / block);
        using var small = new Bitmap(sw, sh);
        using (var g = Graphics.FromImage(small))
        {
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.DrawImage(src, 0, 0, sw, sh);
        }
        var result = new Bitmap(src.Width, src.Height);
        using (var g = Graphics.FromImage(result))
        {
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(small, 0, 0, src.Width, src.Height);
        }
        return result;
    }
}
