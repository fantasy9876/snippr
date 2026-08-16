using System.Drawing.Imaging;

namespace Snippr;

/// Vertical stitcher (GDI+, top-left origin). Frames that can't be matched
/// confidently are rejected rather than guessed. It shares the conservative
/// signature/uniqueness/footer gates with macOS; macOS additionally has
/// platform-specific recovery for fractional Core Animation rasterization.
sealed class WinStitcher : IDisposable
{
    readonly List<Bitmap> _slices = new();
    Bitmap _lastFrame;
    bool _ownsLastFrame; // first frame is owned by _slices, later ones by us
    Signatures? _lastSig; // cached signatures of _lastFrame
    Signatures? _firstSig; // reference for validating a claimed sticky footer
    public int Width { get; }
    public int TotalHeight { get; private set; }

    /// Sticky rows detected at the bottom of the viewport (fixed footer/chat
    /// bar). LATCHED on the first accepted append and constant for the whole
    /// session — per-pair estimates flap (blinking cursor in the bar) and
    /// slicing frames with different footer values baked bar fragments into
    /// the page mid-seam. Compose() re-attaches the footer once at the end.
    public int FooterRows { get; private set; }
    bool _footerLatched;

    public WinStitcher(Bitmap first)
    {
        _slices.Add(first);
        _lastFrame = first;
        _ownsLastFrame = false;
        Width = first.Width;
        TotalHeight = first.Height;
    }

    /// Most recently appended slice — consumed by the live preview.
    public Bitmap? LastSlice { get; private set; }

    public bool Append(Bitmap next)
    {
        if (next.Width != Width || next.Height != _lastFrame.Height) return false;
        var nextSig = RowSignatures(next);
        if (nextSig == null) return false;
        if (_lastSig == null)
        {
            _lastSig = RowSignatures(_lastFrame); // cache: rejected ticks must not redo this
            if (_lastSig == null) return false;
        }
        var prevSig = _lastSig;
        _firstSig ??= prevSig; // prev of the 1st append IS frame #1

        var match = FindOverlap(prevSig.Value, nextSig.Value, next.Height,
            _footerLatched ? FooterRows : null);
        if (match is not (int offset, int pairFooter)) return false;
        int footer = _footerLatched ? FooterRows : pairFooter;

        // A true sticky footer stays identical to the FIRST frame's bottom
        // band all session. Pitch-aligned scrolling content that merely
        // matched the previous frame drifts away from it — reject the frame
        // instead of silently dropping/duplicating page rows.
        if (footer > 0 && _firstSig is Signatures first)
        {
            int stable = 0;
            for (int y = next.Height - footer; y < next.Height; y++)
            {
                int b = y * 4;
                double d = (Math.Abs(first.Bands[b] - nextSig.Value.Bands[b])
                    + Math.Abs(first.Bands[b + 1] - nextSig.Value.Bands[b + 1])
                    + Math.Abs(first.Bands[b + 2] - nextSig.Value.Bands[b + 2])
                    + Math.Abs(first.Bands[b + 3] - nextSig.Value.Bands[b + 3])) / 4;
                if (d < 2.0) stable++; // tolerates a blinking cursor row
            }
            if (stable * 10 < footer * 7) return false; // <70% unchanged
        }

        int contentHeight = next.Height - footer;
        int rows = Math.Min(offset, contentHeight);
        if (rows <= 0) return false;
        // new content sits just above the (possibly empty) footer band
        var slice = next.Clone(
            new Rectangle(0, contentHeight - rows, Width, rows), next.PixelFormat);
        _slices.Add(slice);
        LastSlice = slice;
        TotalHeight += rows;
        FooterRows = footer;
        _footerLatched = true;

        if (_ownsLastFrame) _lastFrame.Dispose();
        _lastFrame = next;
        _ownsLastFrame = true;
        _lastSig = nextSig;
        return true;
    }

    public Bitmap Compose()
    {
        // A detected sticky footer was excluded from every appended slice, but
        // the FIRST frame still carries it — move it to the end of the page.
        Bitmap? trimmedFirst = null, footerBand = null;
        if (FooterRows > 0 && _slices.Count > 1
            && _slices[0].Height > FooterRows && _lastFrame.Height > FooterRows)
        {
            trimmedFirst = _slices[0].Clone(
                new Rectangle(0, 0, Width, _slices[0].Height - FooterRows), _slices[0].PixelFormat);
            footerBand = _lastFrame.Clone(
                new Rectangle(0, _lastFrame.Height - FooterRows, Width, FooterRows), _lastFrame.PixelFormat);
        }

        var result = new Bitmap(Width, TotalHeight, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(result))
        {
            int y = 0;
            for (int i = 0; i < _slices.Count; i++)
            {
                var s = i == 0 && trimmedFirst != null ? trimmedFirst : _slices[i];
                g.DrawImageUnscaled(s, 0, y);
                y += s.Height;
            }
            if (footerBand != null)
            {
                g.DrawImageUnscaled(footerBand, 0, y);
            }
        }
        trimmedFirst?.Dispose();
        footerBand?.Dispose();
        return result;
    }

    public void Dispose()
    {
        foreach (var s in _slices) s.Dispose();
        _slices.Clear();
        if (_ownsLastFrame) _lastFrame.Dispose();
        LastSlice = null;
        _lastSig = null;
    }

    /// Shared safeguards: 4-band row signatures, detail weighting,
    /// static-bottom (sticky footer) detection, and a two-pass
    /// uniqueness margin (the old single-pass second-best tracking was
    /// order-dependent: a chain of small improvements could swallow a real
    /// alias and accept a wrong offset on periodic content).
    static (int offset, int footer)? FindOverlap(Signatures prevS, Signatures nextS, int h,
        int? lockedFooter = null)
    {
        const int minHeight = 40;
        if (h <= minHeight) return null;
        if (prevS.Bands.Length != h * 4 || nextS.Bands.Length != h * 4) return null;

        // Per-row difference at offset 0: identifies rows that did NOT move.
        var rowDiff = new double[h];
        int changedRows = 0;
        const double changeEps = 1.5;
        for (int y = 0; y < h; y++)
        {
            int b = y * 4;
            double d = (Math.Abs(prevS.Bands[b] - nextS.Bands[b])
                + Math.Abs(prevS.Bands[b + 1] - nextS.Bands[b + 1])
                + Math.Abs(prevS.Bands[b + 2] - nextS.Bands[b + 2])
                + Math.Abs(prevS.Bands[b + 3] - nextS.Bands[b + 3])) / 4;
            rowDiff[y] = d;
            if (d > changeEps) changedRows++;
        }
        if (changedRows <= h / 20) return null; // essentially identical frames

        // Trailing static run at the bottom = sticky footer candidate. Once
        // the session latched a footer, that value is used verbatim so every
        // slice is cut with the same geometry.
        int footer;
        if (lockedFooter is int locked)
        {
            footer = Math.Min(locked, h / 3);
        }
        else
        {
            // Trailing static run, allowed to bridge ONE small dynamic band
            // (a blinking cursor / spinner inside the sticky bar would
            // otherwise truncate the detected footer on half the frame pairs).
            const double staticEps = 0.8;
            const int maxGap = 8;
            int limit = h / 3;
            footer = 0;
            int i = 0;
            bool gapUsed = false;
            while (i < limit)
            {
                if (rowDiff[h - 1 - i] < staticEps)
                {
                    i++;
                    footer = i;
                    continue;
                }
                int gap = 0;
                while (i + gap < limit && gap < maxGap && rowDiff[h - 1 - i - gap] >= staticEps)
                    gap++;
                if (!gapUsed && gap < maxGap && i + gap < limit && rowDiff[h - 1 - i - gap] < staticEps)
                {
                    gapUsed = true;
                    i += gap;
                    continue;
                }
                break;
            }
            const int minFooter = 6;
            if (footer < minFooter) footer = 0;
        }

        int hEff = h - footer;
        if (hEff <= minHeight) return null;

        int k = Math.Max(32, hEff / 4);
        if (hEff - k < 1) return null;

        var weights = new double[k];
        double weightSum = 0;
        for (int i = 0; i < k; i++)
        {
            double w = Math.Max(prevS.Energy[hEff - k + i], 0.5);
            weights[i] = w;
            weightSum += w;
        }
        if (weightSum <= 0) return null;

        // Pass 1: score every offset.
        int count = hEff - k + 1;
        var scores = new double[count];
        int bestOffset = -1;
        double bestScore = double.MaxValue;
        for (int s = 0; s < count; s++)
        {
            int start = hEff - k - s;
            double diff = 0;
            for (int i = 0; i < k; i++)
            {
                int a = (hEff - k + i) * 4;
                int b = (start + i) * 4;
                double d = (Math.Abs(prevS.Bands[a] - nextS.Bands[b])
                    + Math.Abs(prevS.Bands[a + 1] - nextS.Bands[b + 1])
                    + Math.Abs(prevS.Bands[a + 2] - nextS.Bands[b + 2])
                    + Math.Abs(prevS.Bands[a + 3] - nextS.Bands[b + 3])) / 4;
                diff += weights[i] * d;
            }
            diff /= weightSum;
            scores[s] = diff;
            if (diff < bestScore)
            {
                bestScore = diff;
                bestOffset = s;
            }
        }

        // Pass 2: runner-up must sit OUTSIDE the winner's plateau.
        const int exclusion = 6;
        double secondScore = double.MaxValue;
        for (int s = 0; s < count; s++)
        {
            if (Math.Abs(s - bestOffset) > exclusion && scores[s] < secondScore)
                secondScore = scores[s];
        }

        // ratio uniqueness (true overlap ≈ 0.0, line-pitch aliases ~0.4–2)
        // with an absolute-gap fallback for pages with animation noise
        if (bestOffset <= 0 || bestScore >= 2.0) return null;
        // no offsets outside the winner's plateau = zero uniqueness evidence
        // (tiny effective heights after footer subtraction) — don't guess
        if (secondScore == double.MaxValue) return null;
        bool unique = secondScore > bestScore * 3 + 0.15
            || secondScore - bestScore > 2.5;
        return unique ? (bestOffset, footer) : null;
    }

    readonly record struct Signatures(double[] Bands, double[] Energy);

    /// Per-row: mean gray of 4 horizontal bands + horizontal gradient energy.
    /// Gray uses Rec.601 luma (matching the macOS port's luminance-based gray)
    /// so the shared tuned thresholds mean the same thing on both platforms.
    static unsafe Signatures? RowSignatures(Bitmap bmp)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int w = bmp.Width, h = bmp.Height;
            int bandWidth = Math.Max(1, w / 4);
            int colStride = Math.Max(1, bandWidth / 24);
            var bands = new double[h * 4];
            var energy = new double[h];
            byte* basePtr = (byte*)data.Scan0;
            for (int y = 0; y < h; y++)
            {
                byte* row = basePtr + y * data.Stride;
                int grad = 0, gradCount = 0;
                for (int band = 0; band < 4; band++)
                {
                    int x0 = band * bandWidth;
                    int x1 = band == 3 ? w : (band + 1) * bandWidth;
                    int sum = 0, count = 0, prevPx = -1;
                    for (int x = x0; x < x1; x += colStride)
                    {
                        byte* px = row + x * 3; // 24bpp BGR
                        int g = (77 * px[2] + 150 * px[1] + 29 * px[0]) >> 8;
                        sum += g;
                        count++;
                        if (prevPx >= 0) { grad += Math.Abs(g - prevPx); gradCount++; }
                        prevPx = g;
                    }
                    bands[y * 4 + band] = (double)sum / Math.Max(1, count);
                }
                energy[y] = (double)grad / Math.Max(1, gradCount);
            }
            return new Signatures(bands, energy);
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }

    public static unsafe int QuickHash(Bitmap bmp)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int total = data.Stride * bmp.Height;
            int step = Math.Max(1, total / 4096);
            byte* p = (byte*)data.Scan0;
            var hash = new HashCode();
            for (int i = 0; i < total; i += step)
            {
                hash.Add(p[i]);
            }
            return hash.ToHashCode();
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }
}
