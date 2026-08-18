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
}
