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

    public const float Grid = 4;
    public const float EditorChromeH = 70;
    public const float EditorRowH = 35;
    public const float EditorBtnW = 32;
    public const float EditorBtnH = 28;
    public const float EditorIcon = 20;
    public const float OverlayBtnW = 34;
    public const float OverlayBtnH = 30;
    public const float OverlayIcon = 16;
    public const float Spacing = 2;
    public const float Pad = 6;
    public const float Gap = 10;
    public const float HandleHit = 18;
    public const float RadiusChrome = 10;
    public const float RadiusHint = 6;
    public const float RadiusBtn = 6;
    public const float HintPadX = 8;
    public const float HintPadY = 5;
    public const float HintMaxW = 240;
    public const float HintMinW = 60;
    public const float HintMinH = 24;
    public const float HintGap = 6;
    public const int HintDelayMs = 450;

    public const float EditorMinW = 560;
    public const float EditorMinViewportH = 200;

    public static Font HintFont { get; } = new("Segoe UI", 11f, FontStyle.Bold);
    public static Font ChromeFont { get; } = new("Segoe UI", 11f, FontStyle.Regular);
    public static Font MenuFont { get; } = new("Segoe UI", 12f, FontStyle.Regular);

    public static int Scale(float dip, int dpi) =>
        (int)Math.Round(dip * dpi / 96.0);

    public static float ScaleF(float dip, int dpi) => dip * dpi / 96f;
}
