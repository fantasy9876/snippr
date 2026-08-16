using System.Drawing;
using System.Drawing.Imaging;

namespace Snippr.Tests;

/// Headless WinStitcher gate for windows-latest.
/// Ports the macOS scroll8 pair: a side-band ad swap (≤1/2 width) must keep
/// stitching; a majority-width change must keep failing closed.
/// Also locks the ±1 dual-mask ranking: do not pick the smaller offset by
/// default; rank by confidence or fail closed.
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
        failed += Check(
            "win-scroll8-offset-split-fails-closed",
            RunAdversarialOffsetSplit(),
            "equal-length masks at offset and offset+1 must not pick the smaller offset");
        int total = 3;
        Console.WriteLine(failed == 0
            ? $"StitcherGate: {total}/{total} PASS"
            : $"StitcherGate: {total - failed}/{total} PASS, {failed} FAIL");
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
            && two.Appended == WalkSteps.Length && two.Height == WalkHeight
            && one.SlicesOk && two.SlicesOk
            && one.PixelsOk && two.PixelsOk;
        return (ok,
            $"one app {one.Appended}/{WalkSteps.Length} h {one.Height}/{WalkHeight} "
            + $"slices [{one.SliceSummary}] px {one.PixelsOk}; "
            + $"two app {two.Appended}/{WalkSteps.Length} h {two.Height}/{WalkHeight} "
            + $"slices [{two.SliceSummary}] px {two.PixelsOk}");
    }

    static (bool ok, string detail) RunMajorityFailClosed()
    {
        var three = AnimatedRun([1, 2, 3]);
        bool ok = three.Ok && three.Appended == 0 && three.Height == Viewport
            && three.Rejected >= 1;
        return (ok,
            $"app {three.Appended} rej {three.Rejected} h {three.Height}/{Viewport}");
    }

    /// Left half scrolled 40, right half scrolled 41. Mask [2,3] matches 40,
    /// mask [0,1] matches 41 — same mask length, ±1, equal-quality scores.
    /// Picking the smaller offset (current GREEN) accepts a 40px slice whose
    /// right half is the wrong row. Fail-closed (or a clearly better score)
    /// is required; LastSlice.Height must not become 40.
    static (bool ok, string detail) RunAdversarialOffsetSplit()
    {
        const int vp = 200, leftOff = 40, rightOff = 41;
        using var doc = MakeTexturedStripePattern(Width, vp + rightOff + vp, 0x51F7_0DDUL);
        using var first = SplitFrame(doc, 0, 0, vp);
        using var next = SplitFrame(doc, leftOff, rightOff, vp);
        using var stitcher = new WinStitcher(first);
        bool accepted = stitcher.Append(next);
        int sliceH = accepted ? stitcher.LastSlice?.Height ?? -1 : 0;
        bool pixelsOk = true;
        if (accepted)
        {
            using var composed = stitcher.Compose();
            // A 40px pick is the smaller-offset default. The left half of
            // that slice would match doc[vp : vp+40] but the right half
            // would be doc[rightOff+vp-40 : rightOff+vp] — not a single
            // translation. Either reject, or accept only the true 41.
            pixelsOk = sliceH == rightOff && ComposeMatchesSplit(composed, doc, vp, leftOff, rightOff);
        }
        bool ok = !accepted || (sliceH == rightOff && pixelsOk);
        // The lock: never accept the smaller offset as a default ranking.
        if (accepted && sliceH == leftOff) ok = false;
        return (ok,
            $"accepted={accepted} lastSlice={sliceH} total={stitcher.TotalHeight} px={pixelsOk}");
    }

    static (
        int Appended, int Rejected, int Height, bool Ok,
        bool SlicesOk, bool PixelsOk, string SliceSummary
    ) AnimatedRun(HashSet<int> bands)
    {
        using var doc = MakeTexturedStripePattern(Width, PageHeight, 0xAD115EEDUL);
        using var adA = MakeTexturedStripePattern(Width, Viewport, 0xADA00001UL);
        using var adB = MakeTexturedStripePattern(Width, Viewport, 0xADB00002UL);
        using var pageA = CompositePage(doc, adA, bands);
        using var pageB = CompositePage(doc, adB, bands);

        var first = Crop(pageA, 0, Viewport);
        if (first == null) return (0, 0, 0, false, false, false, "");
        using var stitcher = new WinStitcher(first);

        int off = 0, appended = 0, rejected = 0;
        var sliceHeights = new int[WalkSteps.Length];
        for (int i = 0; i < WalkSteps.Length; i++)
        {
            off += WalkSteps[i];
            var frame = Crop(pageB, off, Viewport);
            if (frame == null) return (appended, rejected, stitcher.TotalHeight, false, false, false, "");
            if (stitcher.Append(frame))
            {
                sliceHeights[appended] = stitcher.LastSlice?.Height ?? -1;
                appended++;
            }
            else
            {
                rejected++;
                frame.Dispose();
            }
        }

        bool slicesOk = appended == WalkSteps.Length;
        if (slicesOk)
        {
            for (int i = 0; i < WalkSteps.Length; i++)
            {
                if (sliceHeights[i] != WalkSteps[i]) { slicesOk = false; break; }
            }
        }

        bool pixelsOk = false;
        if (appended > 0)
        {
            using var composed = stitcher.Compose();
            using var expected = ExpectedWalkCompose(pageA, pageB, stitcher.TotalHeight);
            pixelsOk = BitmapsEqual(composed, expected);
        }

        return (appended, rejected, stitcher.TotalHeight, true,
            slicesOk, pixelsOk, string.Join(',', sliceHeights.Take(appended)));
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

    static Bitmap ExpectedWalkCompose(Bitmap pageA, Bitmap pageB, int height)
    {
        var expected = new Bitmap(Width, height, PixelFormat.Format24bppRgb);
        using var g = Graphics.FromImage(expected);
        using (var top = Crop(pageA, 0, Viewport)!)
            g.DrawImageUnscaled(top, 0, 0);
        int rest = height - Viewport;
        if (rest > 0)
        {
            using var body = Crop(pageB, Viewport, rest)!;
            g.DrawImageUnscaled(body, 0, Viewport);
        }
        return expected;
    }

    static Bitmap SplitFrame(Bitmap doc, int leftY, int rightY, int height)
    {
        var frame = new Bitmap(Width, height, PixelFormat.Format24bppRgb);
        using var g = Graphics.FromImage(frame);
        int half = Width / 2;
        g.DrawImage(doc, new Rectangle(0, 0, half, height),
            new Rectangle(0, leftY, half, height), GraphicsUnit.Pixel);
        g.DrawImage(doc, new Rectangle(half, 0, Width - half, height),
            new Rectangle(half, rightY, Width - half, height), GraphicsUnit.Pixel);
        return frame;
    }

    static bool ComposeMatchesSplit(Bitmap composed, Bitmap doc, int vp, int leftOff, int rightOff)
    {
        // Only used when the stitcher accepted the larger offset: first
        // viewport from the unsplit top, then 41 new rows with a split origin.
        if (composed.Height != vp + rightOff || composed.Width != Width) return false;
        using var expected = new Bitmap(Width, vp + rightOff, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(expected))
        {
            int half = Width / 2;
            g.DrawImage(doc, new Rectangle(0, 0, Width, vp),
                new Rectangle(0, 0, Width, vp), GraphicsUnit.Pixel);
            g.DrawImage(doc, new Rectangle(0, vp, half, rightOff),
                new Rectangle(0, leftOff + vp - (rightOff - leftOff), half, rightOff),
                GraphicsUnit.Pixel);
            g.DrawImage(doc, new Rectangle(half, vp, Width - half, rightOff),
                new Rectangle(half, rightOff + vp - rightOff, Width - half, rightOff),
                GraphicsUnit.Pixel);
        }
        // The 41-row accept path is only valid if the stitcher sliced
        // next[vp-41 : vp], i.e. left = doc[leftOff+vp-41 : leftOff+vp]
        // and right = doc[rightOff+vp-41 : rightOff+vp] = doc[vp : vp+rightOff].
        return BitmapsEqual(composed, expected);
    }

    static Bitmap? Crop(Bitmap page, int y, int height)
    {
        if (y < 0 || height <= 0 || y + height > page.Height) return null;
        return page.Clone(new Rectangle(0, y, Width, height), PixelFormat.Format24bppRgb);
    }

    static unsafe bool BitmapsEqual(Bitmap a, Bitmap b)
    {
        if (a.Width != b.Width || a.Height != b.Height) return false;
        var ra = new Rectangle(0, 0, a.Width, a.Height);
        var da = a.LockBits(ra, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        var db = b.LockBits(ra, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int w = a.Width, h = a.Height;
            byte* pa = (byte*)da.Scan0;
            byte* pb = (byte*)db.Scan0;
            for (int y = 0; y < h; y++)
            {
                byte* raRow = pa + y * da.Stride;
                byte* rbRow = pb + y * db.Stride;
                for (int x = 0; x < w * 3; x++)
                {
                    if (raRow[x] != rbRow[x]) return false;
                }
            }
            return true;
        }
        finally
        {
            a.UnlockBits(da);
            b.UnlockBits(db);
        }
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
