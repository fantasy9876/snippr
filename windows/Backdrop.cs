using System.Drawing;

namespace Snippr;

enum BackdropPreset { None, Ocean, Sunset, Mint, Graphite }

/// The backdrop's NUMBERS, ported 1:1 from `Sources/Snippr/SliceBContract.swift`
/// (`SliceBBackdrop`) and from the literal table the macOS gate
/// `sliceB-backdrop-presets-match-spec` checks it against.
///
/// Deliberately free of `System.Drawing.Graphics`/`Bitmap`: only
/// `System.Drawing.Primitives` types appear here, so the headless parity gate
/// can compile and RUN this file on any OS. Everything that rasterizes lives
/// in `BackdropRender.cs`, which is Windows-only.
///
/// TWO coordinate flips are baked into this port, because CoreGraphics counts
/// y upwards from the bottom and GDI+ counts it downwards from the top:
///   * gradient axis: Swift's (0,h) -> (w,0) is top-left -> bottom-right on
///     screen, which is (0,0) -> (w,h) here;
///   * radial wash centre: Swift's (0.22w, 0.78h) is 22% from the left and 22%
///     from the TOP, which is (0.22w, 0.22h) here.
/// Getting either wrong mirrors the frame without changing a single constant,
/// which is why both are asserted in `win-backdrop-presets-match-spec`.
static class BackdropSpec
{
    public const float PaddingFraction = 0.06f;
    public const float MinPadding = 40f;
    /// A 40 000 px scrolling capture would otherwise get 2 400 px of padding.
    public const float MaxPadding = 320f;
    public const float CornerRadiusPt = 12f;
    public const float ShadowOffsetPt = -8f;
    public const float ShadowBlurPt = 24f;
    public const float ShadowAlpha = 0.35f;
    /// A Gaussian has no hard cutoff, so blur + offset is where the shadow
    /// becomes negligible, not where it stops.
    public const float ShadowSafetyFactor = 1.25f;
    /// The 1px white line that softens the plate's clipped edge.
    public const float HairlineAlpha = 0.16f;
    public const int GrainTileSide = 128;

    public static (float Location, Color Color)[] GradientStops(BackdropPreset preset)
    {
        static Color Rgb(int r, int g, int b) => Color.FromArgb(255, r, g, b);
        return preset switch
        {
            BackdropPreset.Ocean =>
            [
                (0.00f, Rgb(139, 180, 255)), (0.28f, Rgb(74, 124, 240)),
                (0.62f, Rgb(46, 61, 184)), (1.00f, Rgb(26, 24, 104)),
            ],
            BackdropPreset.Sunset =>
            [
                (0.00f, Rgb(255, 208, 138)), (0.28f, Rgb(255, 126, 74)),
                (0.62f, Rgb(230, 61, 120)), (1.00f, Rgb(122, 34, 136)),
            ],
            BackdropPreset.Mint =>
            [
                (0.00f, Rgb(154, 245, 212)), (0.28f, Rgb(61, 220, 176)),
                (0.62f, Rgb(26, 154, 138)), (1.00f, Rgb(10, 69, 80)),
            ],
            // Graphite has its own locations: the mid tones sit further apart,
            // or the darkest stop swallows most of the frame.
            BackdropPreset.Graphite =>
            [
                (0.00f, Rgb(90, 98, 112)), (0.32f, Rgb(52, 58, 70)),
                (0.68f, Rgb(28, 32, 40)), (1.00f, Rgb(11, 13, 17)),
            ],
            _ => [(0f, Rgb(0, 0, 0)), (1f, Rgb(0, 0, 0))],
        };
    }

    public static (Color Centre, Color Edge) RadialWash(BackdropPreset preset)
    {
        static Color Argb(int r, int g, int b, double a) =>
            Color.FromArgb((int)Math.Round(a * 255), r, g, b);
        return preset switch
        {
            BackdropPreset.Ocean => (Argb(255, 255, 255, 0.20), Argb(255, 255, 255, 0)),
            BackdropPreset.Sunset => (Argb(255, 232, 192, 0.18), Argb(255, 232, 192, 0)),
            BackdropPreset.Mint => (Argb(232, 255, 246, 0.16), Argb(232, 255, 246, 0)),
            BackdropPreset.Graphite => (Argb(139, 155, 184, 0.14), Argb(139, 155, 184, 0)),
            _ => (Argb(0, 0, 0, 0), Argb(0, 0, 0, 0)),
        };
    }

    public static uint GrainSeed(BackdropPreset preset) => preset switch
    {
        BackdropPreset.Ocean => 0x0CE40001u,
        BackdropPreset.Sunset => 0x5E700002u,
        BackdropPreset.Mint => 0xA1170003u,
        BackdropPreset.Graphite => 0x6A400004u,
        _ => 0u,
    };

    /// The gradient runs from the top-left corner to the bottom-right one.
    public static (PointF Start, PointF End) GradientAxis(float width, float height) =>
        (new PointF(0, 0), new PointF(width, height));

    /// Centre of the soft wash, 22% in from the left and from the top.
    public static PointF WashCentre(float width, float height) =>
        new(0.22f * width, 0.22f * height);

    public static float WashRadius(float width, float height) =>
        (float)Math.Sqrt(width * width + height * height) * 0.85f;

    /// How far the drop shadow reaches beyond the plate, in pixels.
    public static float ShadowExtent(float pixelScale)
    {
        var scale = Math.Max(1f, pixelScale);
        var nominal = (ShadowBlurPt + Math.Abs(ShadowOffsetPt)) * scale;
        return (float)Math.Ceiling(nominal * ShadowSafetyFactor);
    }

    /// Padding is a fraction of the LONG edge, floored so the shadow always
    /// fits and capped so a 40 000 px stitch does not get a 2 400 px frame.
    public static float Padding(float longEdge, float pixelScale = 1)
    {
        var floor = Math.Max(MinPadding, ShadowExtent(pixelScale));
        var cap = Math.Max(MaxPadding, floor);
        return Math.Min(cap, Math.Max(floor, (float)Math.Round(longEdge * PaddingFraction, MidpointRounding.AwayFromZero)));
    }

    public static Size? OuterDimensions(
        int innerWidth, int innerHeight, BackdropPreset preset, float pixelScale = 1)
    {
        if (innerWidth <= 0 || innerHeight <= 0) return null;
        if (preset == BackdropPreset.None) return new Size(innerWidth, innerHeight);
        var pad = (int)Padding(Math.Max(innerWidth, innerHeight), pixelScale);
        long w = (long)innerWidth + 2L * pad;
        long h = (long)innerHeight + 2L * pad;
        if (w > int.MaxValue || h > int.MaxValue) return null;
        return new Size((int)w, (int)h);
    }

    /// The deterministic dither. Integer arithmetic only, so the tile is
    /// byte-for-byte the same one the macOS build produces — no
    /// pseudo-randomness, no time, no platform pattern API.
    public static uint GrainHash(int x, int y, uint seed)
    {
        unchecked
        {
            uint h = seed;
            h += (uint)x * 374_761_393u;
            h += (uint)y * 668_265_263u;
            h ^= h >> 13;
            h *= 1_274_126_177u;
            h ^= h >> 16;
            return h;
        }
    }

    static readonly Dictionary<uint, byte[]> GrainCache = new();

    /// A 128×128 BGRA tile of grey with a ±2/255 nudge, row-major from the TOP
    /// row — the same order the macOS bitmap is filled in, so the bytes match.
    /// Drawn with an overlay blend, ±2 is a luma dither that kills the banding
    /// an 8-bit ramp shows without reading as texture.
    public static byte[] GrainTile(uint seed)
    {
        lock (GrainCache)
        {
            if (GrainCache.TryGetValue(seed, out var cached)) return cached;
            var side = GrainTileSide;
            var bytes = new byte[side * side * 4];
            for (int y = 0; y < side; y++)
            {
                for (int x = 0; x < side; x++)
                {
                    var delta = (int)(GrainHash(x, y, seed) % 5) - 2;
                    var grey = (byte)Math.Clamp(128 + delta, 0, 255);
                    var i = (y * side + x) * 4;
                    bytes[i] = grey;
                    bytes[i + 1] = grey;
                    bytes[i + 2] = grey;
                    bytes[i + 3] = 255;
                }
            }
            GrainCache[seed] = bytes;
            return bytes;
        }
    }
}

/// Where the untouched document sits inside its frame. One description, read
/// by the preview, the export, the size label and the gates alike — when each
/// of them derived its own, they disagreed about where the image was and a
/// click landed on a different pixel than the one under the cursor.
readonly record struct BackdropLayout
{
    public BackdropPreset Preset { get; }
    public float PixelScale { get; }
    public float Pad { get; }
    public Size InnerSize { get; }
    public Size OuterSize { get; }

    public BackdropLayout(Size innerPixels, float pixelScale, BackdropPreset preset)
    {
        var scale = Math.Max(1f, pixelScale);
        var inner = new Size(Math.Max(0, innerPixels.Width), Math.Max(0, innerPixels.Height));
        var pad = preset == BackdropPreset.None
            ? 0f
            : BackdropSpec.Padding(Math.Max(inner.Width, inner.Height), scale);
        Preset = preset;
        PixelScale = scale;
        Pad = pad;
        InnerSize = inner;
        OuterSize = new Size(
            inner.Width + (int)(pad * 2), inner.Height + (int)(pad * 2));
    }

    public Rectangle InnerRect =>
        new((int)Pad, (int)Pad, InnerSize.Width, InnerSize.Height);

    /// `.none` collapses: the frame is not a thin border, it is absent.
    public bool IsCollapsed => Preset == BackdropPreset.None || Pad == 0;
}
