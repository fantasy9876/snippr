using System.Drawing.Drawing2D;

namespace Snippr;

/// The overlay chrome's PIXELS: the rounded plate the rail and the strip sit
/// on, and the buttons that sit on the plate.
///
/// Split out of the control on purpose. The plate and the buttons were
/// WinForms `Control`s that never named a background colour, and a child of a
/// `Color.Transparent` parent does NOT inherit that transparency unless it
/// sets `ControlStyles.SupportsTransparentBackColor` itself — WinForms falls
/// back to `SystemColors.Control` instead. That fallback is the
/// near-white slab every overlay button was painted on, and it moves with
/// whatever the Windows theme says, which is why the chrome looked like it
/// belonged to a different app.
///
/// So every colour below is named here, every pixel handed to these methods is
/// written, and nothing reads an ambient one. They are static and take a
/// `Graphics` so the raster gate can point them at a bitmap and check exactly
/// that — a rule the code obeys beats a rule someone remembers.
static class OverlayChrome
{
    /// The plate's colour, and therefore a button's own background: a button
    /// that painted anything else would read as a tile ON the plate rather
    /// than part of it.
    public static Color Plate => Theme.ChromeRaised;

    /// The rail / strip plate. <paramref name="frame"/> is in the coordinates
    /// of whatever <paramref name="g"/> is drawing into.
    public static void PaintPlate(Graphics g, Rectangle frame, int dpi)
    {
        if (frame.Width <= 1 || frame.Height <= 1) return;
        var smoothing = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        // Inset by the pen's own width, or the hairline is drawn half outside
        // the frame and the plate reads a pixel wider than it was placed.
        var r = frame;
        r.Width -= 1;
        r.Height -= 1;
        using (var path = Round(r, Theme.PxF(Theme.RadiusChrome, dpi)))
        using (var fill = new SolidBrush(Plate))
        using (var border = new Pen(Theme.Hairline))
        {
            g.FillPath(fill, path);
            g.DrawPath(border, path);
        }
        g.SmoothingMode = smoothing;
    }

    /// One button, filled edge to edge. The base fill is not decoration: it is
    /// what makes the button opaque, and any pixel left unpainted is a pixel
    /// showing whatever WinForms decided the background was.
    public static void PaintButton(
        Graphics g, Rectangle bounds, string iconKey, int dpi,
        bool hover, bool pressed, bool isChecked, bool enabled, Color? tint)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        using (var plate = new SolidBrush(Plate))
            g.FillRectangle(plate, bounds);

        var smoothing = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var r = bounds;
        r.Inflate(-1, -1);
        Color? fill = !enabled ? null
            : pressed ? Theme.Pressed
            : isChecked ? Theme.Selected
            : hover ? Theme.Hover
            : null;
        if (fill is { } pill && r.Width > 0 && r.Height > 0)
        {
            using var path = Round(r, Theme.PxF(Theme.RadiusBtn, dpi));
            using var brush = new SolidBrush(pill);
            g.FillPath(brush, path);
        }
        int side = Theme.Scale(Theme.OverlayIcon, dpi);
        var dest = new RectangleF(
            bounds.X + (bounds.Width - side) / 2f,
            bounds.Y + (bounds.Height - side) / 2f,
            side, side);
        Color colour = tint
            ?? (iconKey == "close" && hover ? Theme.Danger
                : isChecked ? Theme.Accent
                : enabled ? Theme.Icon
                : Theme.IconMuted);
        Icons.Draw(g, iconKey, dest, colour);
        g.SmoothingMode = smoothing;
    }

    public static GraphicsPath Round(Rectangle r, float radius)
    {
        var path = new GraphicsPath();
        if (r.Width <= 0 || r.Height <= 0) return path;
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0)
        {
            path.AddRectangle(r);
            return path;
        }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
