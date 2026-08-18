using System.Drawing;
using System.Drawing.Drawing2D;

namespace Snippr;

/// The frame and the document, in the order the export puts them.
///
/// The review surface draws the frozen desktop first and the frame on top of
/// it, which meant the frame's fill — which covers the WHOLE outer rect, not
/// just the margin — painted straight over the document. In the editor the
/// same call looks right only because the document is a child control that
/// paints itself afterwards; on the review surface there is no child, so the
/// picture the user was reviewing was a rectangle of gradient. Compose has
/// always drawn the document AFTER the frame; this is that order, in one place,
/// for the surface that has to match it.
static class AreaReviewPreview
{
    /// Paints the frame around `documentRect`, then puts the document back on
    /// top of it, cut to the same rounded plate the export cuts.
    public static void Paint(
        Graphics g, Bitmap desktop, Rectangle documentRect,
        BackdropPreset preset, BackdropCornerStyle corners)
    {
        if (preset == BackdropPreset.None) return;
        BackdropRender.DrawFrameForPreview(
            g,
            new RectangleF(
                documentRect.X, documentRect.Y, documentRect.Width, documentRect.Height),
            1f, preset, corners);

        var radius = BackdropSpec.CornerRadius(documentRect.Size, corners);
        var state = g.Save();
        using (var plate = BackdropRender.RoundedRect(documentRect, radius))
        using (var brush = new TextureBrush(desktop) { WrapMode = WrapMode.Clamp })
        {
            // The desktop is drawn at the origin, so its pixels already line up
            // with this coordinate space: no transform, and the crop lands
            // exactly where it came from.
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.FillPath(brush, plate);
        }
        g.Restore(state);
    }
}
