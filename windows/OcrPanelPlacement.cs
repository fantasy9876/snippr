using System.Drawing;

namespace Snippr;

/// Where the region OCR panel sits: BESIDE the pixels it read, never on them.
///
/// This is the Windows reading of macOS `OverlayToolbarLayout.popover`
/// (`Sources/Snippr/OverlayToolbarLayout.swift`), which Windows never had.
/// Same contract, stated as arithmetic so the parity gate can run it without
/// a screen:
///
/// - the panel never covers the region — the whole point of picking a region
///   is to read the text next to the pixels it came from;
/// - it never covers the rail or the strip, because chrome the panel hides is
///   chrome the user cannot press;
/// - it stays inside the surface;
/// - and when no placement satisfies all three it returns null rather than a
///   "best effort" rectangle. A panel half off-screen or sitting on the shot
///   is worse than a panel the caller knows it must not show.
static class OcrPanelPlacement
{
    /// Breathing room between the panel and the region it describes.
    public const int Gap = 12;

    /// Sides in preference order: below the region first, because a panel
    /// under the text reads like a caption and leaves the region and the
    /// toolbar where the eye already is.
    public enum Side { Below, Above, Right, Left }

    public static readonly Side[] Order =
        [Side.Below, Side.Above, Side.Right, Side.Left];

    public static Rectangle? Place(
        Size panel, Rectangle region, Rectangle bounds, params RectangleF[] occupied)
    {
        if (panel.Width <= 0 || panel.Height <= 0) return null;
        if (panel.Width > bounds.Width || panel.Height > bounds.Height) return null;
        foreach (var side in Order)
        {
            var candidate = Candidate(side, panel, region, bounds);
            if (candidate is not { } rect) continue;
            if (!bounds.Contains(rect)) continue;
            if (rect.IntersectsWith(region)) continue;
            var clash = false;
            foreach (var busy in occupied)
            {
                if (busy.Width <= 0 || busy.Height <= 0) continue;
                if (rect.IntersectsWith(Rectangle.Round(busy))) { clash = true; break; }
            }
            if (clash) continue;
            return rect;
        }
        return null;
    }

    /// One side's rectangle, aligned to the region's near edge and slid along
    /// that edge until it fits the surface. Sliding is what keeps a region at
    /// the screen edge from pushing the panel out of bounds; it never slides
    /// ACROSS the region, because the caller rejects any overlap after.
    static Rectangle? Candidate(Side side, Size panel, Rectangle region, Rectangle bounds)
    {
        int x, y;
        switch (side)
        {
            case Side.Below:
                x = region.Left;
                y = region.Bottom + Gap;
                break;
            case Side.Above:
                x = region.Left;
                y = region.Top - Gap - panel.Height;
                break;
            case Side.Right:
                x = region.Right + Gap;
                y = region.Top;
                break;
            default:
                x = region.Left - Gap - panel.Width;
                y = region.Top;
                break;
        }
        x = Clamp(x, bounds.Left, bounds.Right - panel.Width);
        y = Clamp(y, bounds.Top, bounds.Bottom - panel.Height);
        return new Rectangle(x, y, panel.Width, panel.Height);
    }

    static int Clamp(int v, int lo, int hi) => hi < lo ? lo : Math.Min(hi, Math.Max(lo, v));
}
