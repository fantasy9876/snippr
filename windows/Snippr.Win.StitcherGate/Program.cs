using System.Drawing;
using System.Drawing.Imaging;

namespace Snippr.Tests;

/// Headless WinStitcher gate for windows-latest.
/// Ports the macOS scroll8 pair: a side-band ad swap (≤1/2 width) must keep
/// stitching; a majority-width change must keep failing closed.
///
/// Counterpart: Sources/Snippr/SelfTest.swift scroll8-animated-band-stitches
/// + scroll8-animated-majority-fails-closed (SHA 5f86075 / a3827c4).
static class Program
{
    const int Viewport = 500;
    const int Width = 400;
    const int PageHeight = 3000;
    static readonly int[] WalkSteps = [40, 40, 60, 80, 120, 160, 200, 200, 200];
    static readonly int WalkHeight = Viewport + 40 + 40 + 60 + 80 + 120 + 160 + 200 + 200 + 200;

    static int Main()
    {
        int failed = 0;
        failed += Check(
            "win-scroll8-animated-band-stitches",
            RunSideBand(),
            "one/two-band ad swap must append all 9 steps as one strip");
        failed += Check(
            "win-scroll8-animated-majority-fails-closed",
            RunMajorityFailClosed(),
            "three-band change must reject rather than guess a seam");
        Console.WriteLine(failed == 0
            ? "StitcherGate: 2/2 PASS"
            : $"StitcherGate: {2 - failed}/2 PASS, {failed} FAIL");
        return failed == 0 ? 0 : 1;
    }

    static int Check(string name, (bool ok, string detail) result, string why)
    {
        if (result.ok)
        {
            Console.WriteLine($"PASS  {name}  {result.detail}");
            return 0;
        }
        Console.WriteLine($"FAIL  {name}  {result.detail}  ({why})");
        return 1;
    }

    static (bool ok, string detail) RunSideBand()
    {
        var one = AnimatedRun([3]);
        var two = AnimatedRun([2, 3]);
        bool ok = one.Ok && two.Ok
            && one.Appended == WalkSteps.Length && one.Height == WalkHeight
            && two.Appended == WalkSteps.Length && two.Height == WalkHeight;
        return (ok,
            $"one app {one.Appended}/{WalkSteps.Length} h {one.Height}/{WalkHeight}; "
            + $"two app {two.Appended}/{WalkSteps.Length} h {two.Height}/{WalkHeight}");
    }

    static (bool ok, string detail) RunMajorityFailClosed()
    {
        var three = AnimatedRun([1, 2, 3]);
        // Windows has no multi-segment stitcher: fail-closed = reject the
        // frame rather than silently accept a wrong offset. Height must stay
        // at the first viewport; zero appends.
        bool ok = three.Ok && three.Appended == 0 && three.Height == Viewport
            && three.Rejected >= 1;
        return (ok,
            $"app {three.Appended} rej {three.Rejected} h {three.Height}/{Viewport}");
    }

    static (int Appended, int Rejected, int Height, bool Ok) AnimatedRun(HashSet<int> bands)
    {
        using var doc = MakeTexturedStripePattern(Width, PageHeight, 0xAD115EEDUL);
        using var adA = MakeTexturedStripePattern(Width, Viewport, 0xADA00001UL);
        using var adB = MakeTexturedStripePattern(Width, Viewport, 0xADB00002UL);
        using var pageA = CompositePage(doc, adA, bands);
        using var pageB = CompositePage(doc, adB, bands);

        var first = Crop(pageA, 0);
        if (first == null) return (0, 0, 0, false);
        using var stitcher = new WinStitcher(first);

        int off = 0, appended = 0, rejected = 0;
        foreach (int step in WalkSteps)
        {
            off += step;
            var frame = Crop(pageB, off);
            if (frame == null) return (appended, rejected, stitcher.TotalHeight, false);
            if (stitcher.Append(frame)) appended++;
            else
            {
                rejected++;
                frame.Dispose();
            }
        }
        return (appended, rejected, stitcher.TotalHeight, true);
    }

    static Bitmap CompositePage(Bitmap doc, Bitmap ad, HashSet<int> bands)
    {
        var page = new Bitmap(Width, PageHeight, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(page))
        {
            g.DrawImageUnscaled(doc, 0, 0);
            int bandW = Width / 4;
            foreach (int band in bands)
            {
                var src = new Rectangle(band * bandW, 0, bandW, Viewport);
                var dst = new Rectangle(band * bandW, 0, bandW, Viewport);
                g.DrawImage(ad, dst, src, GraphicsUnit.Pixel);
            }
        }
        return page;
    }

    static Bitmap? Crop(Bitmap page, int y)
    {
        if (y < 0 || y + Viewport > page.Height) return null;
        return page.Clone(new Rectangle(0, y, Width, Viewport), PixelFormat.Format24bppRgb);
    }

    /// Deterministic per-row colour plus per-pixel texture — same LCG as
    /// SelfTest.makeTexturedStripePattern so rows have unique energy.
    static unsafe Bitmap MakeTexturedStripePattern(int width, int height, ulong seed)
    {
        var bmp = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        var data = bmp.LockBits(
            new Rectangle(0, 0, width, height),
            ImageLockMode.WriteOnly,
            PixelFormat.Format24bppRgb);
        try
        {
            for (int y = 0; y < height; y++)
            {
                seed = seed * 6364136223846793005UL + 1442695040888963407UL;
                int br = (int)((seed >> 33) & 0xFF);
                int bg = (int)((seed >> 41) & 0xFF);
                int bb = (int)((seed >> 49) & 0xFF);
                ulong px = seed ^ 0x9E3779B97F4A7C15UL;
                byte* row = (byte*)data.Scan0 + y * data.Stride;
                for (int x = 0; x < width; x++)
                {
                    px = px * 6364136223846793005UL + 1442695040888963407UL;
                    int noise = (int)((px >> 40) & 0x3F) - 32;
                    row[x * 3 + 2] = (byte)Math.Clamp(br + noise, 0, 255);
                    row[x * 3 + 1] = (byte)Math.Clamp(bg + noise, 0, 255);
                    row[x * 3 + 0] = (byte)Math.Clamp(bb + noise, 0, 255);
                }
            }
        }
        finally
        {
            bmp.UnlockBits(data);
        }
        return bmp;
    }
}
