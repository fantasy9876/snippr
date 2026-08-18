using System.Drawing;
using System.Drawing.Drawing2D;

namespace Snippr;

/// Which pass an annotation belongs to. A redaction has to be under the
/// spotlight's dimming, and both have to be under the marks the user drew on
/// top — otherwise an arrow pointing at a covered area ends up dimmed while
/// the area it points at does not.
enum AnnotationPhase { Redaction = 0, Spotlight = 1, Foreground = 2 }

/// THE renderer. Preview and export both go through here, with the same
/// arguments, so the two cannot drift — the macOS build learned this the hard
/// way when its preview passed "the whole image" as visible and kept drawing a
/// magnifier the export had already dropped.
///
/// Counterpart: `SliceBCompositor.draw` in `Sources/Snippr/SliceBContract.swift`.
static class AnnotationCompositor
{
    public static AnnotationPhase PhaseOf(Annotation a) => a switch
    {
        BlurAnnotation => AnnotationPhase.Redaction,
        SpotlightAnnotation => AnnotationPhase.Spotlight,
        _ => AnnotationPhase.Foreground,
    };

    /// Stable sort into phase order: annotations added later still win inside
    /// their own phase.
    public static List<Annotation> PhaseOrder(IEnumerable<Annotation> annotations) =>
        annotations
            .Select((a, i) => (a, i))
            .OrderBy(t => (int)PhaseOf(t.a))
            .ThenBy(t => t.i)
            .Select(t => t.a)
            .ToList();

    /// `visiblePixels` is the crop the export will actually contain, in image
    /// pixels. Callers that show the whole image pass its bounds.
    public static void Draw(
        IEnumerable<Annotation> annotations, Graphics g, Bitmap baseImage,
        Rectangle visiblePixels, Bitmap? pixelated)
    {
        foreach (var a in PhaseOrder(annotations))
        {
            // A magnifier TRANSPORTS pixels: whatever its source covers is
            // reproduced, enlarged, wherever the callout sits. So the crop is a
            // privacy boundary for it, and the boundary is enforced HERE rather
            // than at the drag — a source that was legitimate when the callout
            // was made can be moved outside the crop afterwards by a crop move
            // or resize, and this catches that the instant it happens.
            //
            // CONTAINS, not intersects: a source hanging half out still shows
            // the half that is out.
            if (a is MagnifierAnnotation mag
                && !visiblePixels.Contains(mag.SourceRect))
                continue;
            a.Draw(g, pixelated);
        }
    }

    /// Source pixels for a callout, taken AFTER the redactions so a magnifier
    /// can never resurrect covered pixels. Returns null when the source cannot
    /// be sampled safely — fail closed, draw nothing.
    public static Bitmap? MagnifierSnapshot(
        Bitmap baseImage, Rectangle sourceRect, IEnumerable<BlurAnnotation> redactions)
    {
        var bounds = new Rectangle(0, 0, baseImage.Width, baseImage.Height);
        var region = Rectangle.Intersect(sourceRect, bounds);
        if (region.Width <= 1 || region.Height <= 1) return null;

        var covering = redactions
            .Where(b => b.Rect.Width > 1 && b.Rect.Height > 1)
            .Where(b => b.Rect.IntersectsWith(region))
            .ToList();

        var shot = new Bitmap(region.Width, region.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(shot))
        {
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.DrawImage(
                baseImage, new Rectangle(0, 0, region.Width, region.Height),
                region, GraphicsUnit.Pixel);
            if (covering.Count > 0)
            {
                // Redraw the redactions into the patch, in the patch's own
                // coordinates: sampling the raw image and hoping the callout
                // sits somewhere harmless is exactly the leak this prevents.
                using var pixelated = AnnotationRenderer.Pixelate(baseImage);
                g.TranslateTransform(-region.X, -region.Y);
                foreach (var blur in covering) blur.Draw(g, pixelated);
            }
        }
        return shot;
    }
}
