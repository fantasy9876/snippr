using System.Drawing;

namespace Snippr;

/// The crop, reduced to arithmetic.
///
/// It lives on its own so the rule can be checked without a capture to review:
/// one integral rect, clamped to the picture it indexes, never empty. What the
/// review surface shows and what the export writes both come from here, which
/// is the whole point — on macOS the fractional selection stayed live beside
/// the integral one and every border, badge and frame sat half a point away
/// from the exported pixels.
static class CropGeometry
{
    public static Rectangle Canonical(Rectangle proposed, Size capture)
    {
        var bounds = new Rectangle(0, 0, capture.Width, capture.Height);
        var clamped = Rectangle.Intersect(proposed, bounds);
        if (clamped.Width >= 1 && clamped.Height >= 1) return clamped;
        // No overlap at all: keep the origin the user asked for, pinned inside
        // the capture, and give it the smallest crop that can still export.
        var x = Math.Clamp(proposed.X, 0, Math.Max(0, capture.Width));
        var y = Math.Clamp(proposed.Y, 0, Math.Max(0, capture.Height));
        return new Rectangle(x, y, 1, 1);
    }

    /// `area` with `hole` cut out of it, as up to four non-overlapping bands.
    /// Returns how many of <paramref name="bands"/> were filled.
    ///
    /// This is the dim around a crop, and the review surface draws it on every
    /// mouse move of a drag. It used to be `new Region(area).Exclude(hole)` —
    /// a real GDI object allocated, combined and destroyed per frame to
    /// describe a shape that is always a rectangle with a rectangular bite out
    /// of it. Four bands say the same thing with arithmetic, and arithmetic is
    /// something a gate can check without a screen.
    ///
    /// Bands are laid out top, bottom, left, right — the left and right ones
    /// spanning only the hole's rows, so no pixel is painted twice. Painting
    /// one twice would show: the dim is translucent.
    public static int Surround(Rectangle area, Rectangle hole, Span<Rectangle> bands)
    {
        hole.Intersect(area);
        if (hole.Width <= 0 || hole.Height <= 0)
        {
            if (area.Width <= 0 || area.Height <= 0) return 0;
            bands[0] = area;
            return 1;
        }
        // Written out rather than looped through a local helper: a local
        // function cannot capture a Span parameter.
        int n = 0;
        var top = Rectangle.FromLTRB(area.Left, area.Top, area.Right, hole.Top);
        if (top.Width > 0 && top.Height > 0) bands[n++] = top;
        var bottom = Rectangle.FromLTRB(area.Left, hole.Bottom, area.Right, area.Bottom);
        if (bottom.Width > 0 && bottom.Height > 0) bands[n++] = bottom;
        var left = Rectangle.FromLTRB(area.Left, hole.Top, hole.Left, hole.Bottom);
        if (left.Width > 0 && left.Height > 0) bands[n++] = left;
        var right = Rectangle.FromLTRB(hole.Right, hole.Top, area.Right, hole.Bottom);
        if (right.Width > 0 && right.Height > 0) bands[n++] = right;
        return n;
    }
}
