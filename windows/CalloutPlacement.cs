using System.Drawing;

namespace Snippr;

/// Where a magnifier callout sits relative to its source.
///
/// This is the Windows reading of `MagnifierAnnotation.calloutRect` on macOS
/// (`SliceBContract.swift` at f6f475c). Mac annotation space grows up; GDI+
/// grows down. The four sides are the ones a person looking at the picture
/// names — right, left, below, above — so Mac's `below` (toward minY) is
/// toward `Bottom` here. Same preference, same shrink-to-fit, same 1× floor.
///
/// Lives on its own so the parity gate can run the arithmetic without GDI+.
/// `MagnifierAnnotation.PlaceCallout` is the one function callers use.
static class CalloutPlacement
{
    public const int Gap = 16;
    /// Same number `MagnifierAnnotation.DefaultZoom` advertises — kept here
    /// so the parity gate does not have to name 2.5 twice.
    public const float DefaultZoom = 2.5f;

    public static Rectangle Place(Rectangle source, Rectangle bounds, float zoom)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0
            || source.Width <= 0 || source.Height <= 0)
        {
            return new Rectangle(
                source.Right + Gap,
                source.Top,
                Math.Max(0, (int)(source.Width * zoom)),
                Math.Max(0, (int)(source.Height * zoom)));
        }

        int minX = bounds.Left, minY = bounds.Top;
        int ClampX(int x, int w) =>
            Math.Min(Math.Max(x, minX), Math.Max(minX, bounds.Right - w));
        int ClampY(int y, int h) =>
            Math.Min(Math.Max(y, minY), Math.Max(minY, bounds.Bottom - h));

        double z = zoom;
        double fitH = (double)bounds.Height / source.Height;
        double fitW = (double)bounds.Width / source.Width;
        double right = Min3(z, (bounds.Right - source.Right - Gap) / (double)source.Width, fitH);
        double left = Min3(z, (source.Left - Gap - minX) / (double)source.Width, fitH);
        // Visual below / above: Mac's `below`/`above` with the Y axis flipped.
        double below = Min3(z, (bounds.Bottom - source.Bottom - Gap) / (double)source.Height, fitW);
        double above = Min3(z, (source.Top - Gap - minY) / (double)source.Height, fitW);

        // First side that still holds the asked zoom; otherwise the roomiest,
        // even if that means shrinking. A tie keeps the earlier preference.
        int pick;
        if (right >= z) pick = 0;
        else if (left >= z) pick = 1;
        else if (below >= z) pick = 2;
        else if (above >= z) pick = 3;
        else
        {
            pick = 0;
            var best = right;
            if (left > best) { best = left; pick = 1; }
            if (below > best) { best = below; pick = 2; }
            if (above > best) { best = above; pick = 3; }
        }

        double scale = pick switch { 0 => right, 1 => left, 2 => below, _ => above };
        if (scale < 1) scale = 1;
        var size = new Size(
            Math.Max(1, (int)Math.Round(source.Width * scale)),
            Math.Max(1, (int)Math.Round(source.Height * scale)));

        // Horizontal sides align to the visual bottom of the source (Mac
        // aligns to minY, which is that edge in Y-up space), then clamp.
        int x = pick switch
        {
            0 => source.Right + Gap,
            1 => source.Left - Gap - size.Width,
            _ => ClampX(source.Left, size.Width),
        };
        int y = pick switch
        {
            2 => source.Bottom + Gap,
            3 => source.Top - Gap - size.Height,
            _ => ClampY(source.Bottom - size.Height, size.Height),
        };
        return new Rectangle(ClampX(x, size.Width), ClampY(y, size.Height),
            size.Width, size.Height);
    }

    static double Min3(double a, double b, double c) => Math.Min(a, Math.Min(b, c));
}
