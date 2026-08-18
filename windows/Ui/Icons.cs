using System.Drawing.Drawing2D;

namespace Snippr;

/// Vector icons on a 24×24 grid. Dest size is whatever the chrome asks
/// (16 overlay / 20 editor / 24 sheet). Stroke 1.5, cap/join round.
static class Icons
{
    public static readonly string[] Keys =
    [
        "select", "arrow", "line", "rect", "oval", "highlight", "pen", "text",
        "counter", "pixelate", "spotlight", "magnifier", "crop",
        "backdrop", "color", "undo", "redo", "copy", "save", "pin",
        "ocr", "translate", "editor", "close",
    ];

    public static Bitmap Bitmap(string key, int size, Color color)
    {
        var bmp = new Bitmap(Math.Max(1, size), Math.Max(1, size));
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.Transparent);
        Draw(g, key, new RectangleF(0, 0, size, size), color);
        return bmp;
    }

    public static void Draw(Graphics g, string key, RectangleF dest, Color color)
    {
        if (dest.Width <= 0 || dest.Height <= 0) return;
        var state = g.Save();
        g.TranslateTransform(dest.X, dest.Y);
        g.ScaleTransform(dest.Width / 24f, dest.Height / 24f);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        Draw24(g, key, color);
        g.Restore(state);
    }

    static void Draw24(Graphics g, string key, Color color)
    {
        using var stroke = Pen(color, 1.5f);
        using var fill = new SolidBrush(color);
        switch (key)
        {
            case "select":
                FillPoly(g, fill, 6, 3, 6, 18, 10, 14, 14, 21, 16.5f, 20, 12.5f, 13, 18, 13);
                break;
            case "arrow":
                g.DrawLine(stroke, 6, 18, 18, 6);
                g.DrawLine(stroke, 18, 6, 12, 7);
                g.DrawLine(stroke, 18, 6, 17, 12);
                break;
            case "line":
                g.DrawLine(stroke, 5, 19, 19, 5);
                break;
            case "rect":
                using (var path = RoundRect(5, 6, 14, 12, 2))
                    g.DrawPath(stroke, path);
                break;
            case "oval":
                g.DrawEllipse(stroke, 5, 6, 14, 12);
                break;
            case "highlight":
                using (var body = new SolidBrush(Color.FromArgb(89, color)))
                    FillPoly(g, body, 7, 16, 15, 5, 18, 7, 10, 18);
                FillPoly(g, fill, 7, 16, 5, 20, 9, 18);
                break;
            case "pen":
                using (var fat = Pen(color, 2.2f))
                    g.DrawLine(fat, 8, 18, 16, 6);
                FillPoly(g, fill, 16, 6, 18, 8, 17, 5);
                break;
            case "text":
                g.DrawLine(stroke, 6, 6, 18, 6);
                g.DrawLine(stroke, 12, 6, 12, 19);
                break;
            case "counter":
                g.DrawEllipse(stroke, 4, 4, 16, 16);
                g.DrawLines(stroke, new[]
                {
                    new PointF(11, 8), new PointF(12.5f, 8), new PointF(12.5f, 16),
                });
                g.DrawLine(stroke, 10.5f, 16, 14.5f, 16);
                break;
            case "pixelate":
                g.FillRectangle(fill, 5, 5, 5, 5);
                g.DrawRectangle(stroke, 13, 5, 5, 5);
                g.DrawRectangle(stroke, 5, 13, 5, 5);
                g.DrawRectangle(stroke, 13, 13, 5, 5);
                break;
            case "spotlight":
                g.DrawRectangle(stroke, 4, 5, 16, 14);
                using (var dim = new SolidBrush(Color.FromArgb(89, color)))
                    g.FillRectangle(dim, 8, 8, 8, 8);
                break;
            case "magnifier":
                g.DrawEllipse(stroke, 4, 4, 12, 12);
                using (var fat = Pen(color, 2f))
                    g.DrawLine(fat, 14.5f, 14.5f, 19, 19);
                break;
            case "crop":
                g.DrawLines(stroke, new[]
                {
                    new PointF(7, 5), new PointF(7, 17), new PointF(19, 17),
                });
                g.DrawLines(stroke, new[]
                {
                    new PointF(5, 7), new PointF(17, 7), new PointF(17, 19),
                });
                break;
            case "backdrop":
                using (var frame = RoundRect(4, 6, 16, 12, 2))
                    g.DrawPath(stroke, frame);
                using (var plate = new SolidBrush(Color.FromArgb(64, color)))
                    g.FillRectangle(plate, 7, 9, 10, 6);
                break;
            case "color":
                g.FillEllipse(fill, 5, 5, 14, 14);
                break;
            case "undo":
                g.DrawArc(stroke, 6, 6, 14, 14, 200, 135);
                g.DrawLines(stroke, new[]
                {
                    new PointF(7, 10), new PointF(7, 16), new PointF(12, 16),
                });
                break;
            case "redo":
                g.DrawArc(stroke, 4, 6, 14, 14, 205, -135);
                g.DrawLines(stroke, new[]
                {
                    new PointF(17, 10), new PointF(17, 16), new PointF(12, 16),
                });
                break;
            case "copy":
                g.DrawRectangle(stroke, 7, 5, 11, 13);
                g.DrawRectangle(stroke, 5, 8, 11, 13);
                break;
            case "save":
                g.DrawLines(stroke, new[]
                {
                    new PointF(5, 14), new PointF(5, 18),
                    new PointF(19, 18), new PointF(19, 14),
                });
                g.DrawLine(stroke, 12, 5, 12, 14);
                g.DrawLines(stroke, new[]
                {
                    new PointF(8, 11), new PointF(12, 15), new PointF(16, 11),
                });
                break;
            case "pin":
                g.FillEllipse(fill, 9, 4, 6, 6);
                g.DrawLine(stroke, 12, 10, 12, 18);
                g.DrawLine(stroke, 8, 10, 16, 10);
                break;
            case "ocr":
                DrawCorner(g, stroke, 5, 5, 5, 5, 1, 1);
                DrawCorner(g, stroke, 19, 5, 5, 5, -1, 1);
                DrawCorner(g, stroke, 5, 19, 5, 5, 1, -1);
                DrawCorner(g, stroke, 19, 19, 5, 5, -1, -1);
                break;
            case "translate":
                g.DrawEllipse(stroke, 4, 4, 16, 16);
                g.DrawLine(stroke, 4, 12, 20, 12);
                g.DrawArc(stroke, 8, 4, 8, 16, 90, 180);
                g.DrawArc(stroke, 8, 4, 8, 16, 270, 180);
                break;
            case "editor":
                g.DrawRectangle(stroke, 4, 5, 16, 14);
                g.FillRectangle(fill, 4, 5, 16, 4);
                break;
            case "close":
                g.DrawLine(stroke, 7, 7, 17, 17);
                g.DrawLine(stroke, 17, 7, 7, 17);
                break;
            default:
                g.DrawRectangle(stroke, 6, 6, 12, 12);
                break;
        }
    }

    static void DrawCorner(Graphics g, Pen pen, float x, float y, float armX, float armY, int sx, int sy)
    {
        g.DrawLine(pen, x, y, x + armX * sx, y);
        g.DrawLine(pen, x, y, x, y + armY * sy);
    }

    static void FillPoly(Graphics g, Brush brush, params float[] xy)
    {
        var pts = new PointF[xy.Length / 2];
        for (int i = 0; i < pts.Length; i++)
            pts[i] = new PointF(xy[i * 2], xy[i * 2 + 1]);
        g.FillPolygon(brush, pts);
    }

    static GraphicsPath RoundRect(float x, float y, float w, float h, float r)
    {
        var path = new GraphicsPath();
        r = Math.Min(r, Math.Min(w, h) / 2f);
        float d = r * 2;
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    static Pen Pen(Color color, float width)
    {
        return new Pen(color, width)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round,
        };
    }
}
