namespace Snippr;

/// DIP tokens for the Windows chrome. Numbers are device-independent;
/// multiply with <see cref="Scale"/> at the destination DPI.
static class Theme
{
    public static Color Window => Color.FromArgb(28, 30, 36);
    public static Color Canvas => Color.FromArgb(33, 36, 43);
    public static Color Chrome => Color.FromArgb(23, 24, 28);
    public static Color ChromeRaised => Color.FromArgb(32, 34, 40);
    public static Color Hairline => Color.FromArgb(26, 255, 255, 255);
    public static Color Icon => Color.FromArgb(216, 216, 216);
    public static Color IconMuted => Color.FromArgb(154, 156, 162);
    public static Color Accent => Color.FromArgb(59, 130, 246);
    public static Color Hover => Color.FromArgb(20, 255, 255, 255);
    public static Color Pressed => Color.FromArgb(36, 255, 255, 255);
    public static Color Selected => Color.FromArgb(56, 59, 130, 246);
    public static Color HintBg => Color.FromArgb(240, 20, 21, 24);
    public static Color HintBorder => Color.FromArgb(31, 255, 255, 255);
    public static Color Danger => Color.FromArgb(232, 88, 88);
    public static Color Shadow => Color.FromArgb(89, 0, 0, 0);
    public static Color HintText => Color.White;

    public const float Grid = ThemeMetrics.Grid;
    public const float EditorChromeH = ThemeMetrics.EditorChromeH;
    public const float EditorRowH = ThemeMetrics.EditorRowH;
    public const float EditorBtnW = ThemeMetrics.EditorBtnW;
    public const float EditorBtnH = ThemeMetrics.EditorBtnH;
    public const float EditorIcon = ThemeMetrics.EditorIcon;
    public const float OverlayBtnW = ThemeMetrics.OverlayBtnW;
    public const float OverlayBtnH = ThemeMetrics.OverlayBtnH;
    public const float OverlayIcon = ThemeMetrics.OverlayIcon;
    public const float Spacing = ThemeMetrics.Spacing;
    public const float Pad = ThemeMetrics.Pad;
    public const float Gap = ThemeMetrics.Gap;
    public const float HandleHit = ThemeMetrics.HandleHit;
    public const float RadiusChrome = ThemeMetrics.RadiusChrome;
    public const float RadiusHint = ThemeMetrics.RadiusHint;
    public const float RadiusBtn = ThemeMetrics.RadiusBtn;
    public const float HintPadX = ThemeMetrics.HintPadX;
    public const float HintPadY = ThemeMetrics.HintPadY;
    public const float HintMaxW = ThemeMetrics.HintMaxW;
    public const float HintMinW = ThemeMetrics.HintMinW;
    public const float HintMinH = ThemeMetrics.HintMinH;
    public const float HintGap = ThemeMetrics.HintGap;
    public const int HintDelayMs = 450;

    public const float EditorMinW = ThemeMetrics.EditorMinW;
    public const float EditorMinViewportH = ThemeMetrics.EditorMinViewportH;

    public static Font HintFont { get; } = new("Segoe UI", 11f, FontStyle.Bold);
    public static Font ChromeFont { get; } = new("Segoe UI", 11f, FontStyle.Regular);
    public static Font MenuFont { get; } = new("Segoe UI", 12f, FontStyle.Regular);

    /// Device-independent units to real pixels. EVERY chrome constant above
    /// is in the former and must pass through here before it becomes a size:
    /// used raw, they are correct only on a 100% display, and on a 150% one
    /// they quietly make the toolbar too small to hold its own buttons.
    public static int Px(float dip, int dpi) => ThemeMetrics.Px(dip, dpi);

    public static float PxF(float dip, int dpi) => ThemeMetrics.PxF(dip, dpi);

    public static int Scale(float dip, int dpi) => Px(dip, dpi);

    public static float ScaleF(float dip, int dpi) => PxF(dip, dpi);
}
