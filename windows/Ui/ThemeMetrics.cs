namespace Snippr;

/// The chrome's NUMBERS, apart from its colours and fonts.
///
/// Every one of these is a device-independent unit: multiply by the display's
/// DPI over 96 before using it as a pixel. They live here rather than beside
/// the brushes because the parity gate checks the layout arithmetic and cannot
/// load GDI+ to do it — and a gate that cannot read these numbers is a gate
/// that cannot notice a toolbar too small to hold its own buttons.
static class ThemeMetrics
{
    public const float Grid = 4f;
    public const float EditorChromeH = 70f;
    public const float EditorRowH = 35f;
    public const float EditorBtnW = 32f;
    public const float EditorBtnH = 28f;
    public const float EditorIcon = 20f;
    public const float OverlayBtnW = 34f;
    public const float OverlayBtnH = 30f;
    public const float OverlayIcon = 16f;
    public const float Spacing = 2f;
    public const float Pad = 6f;
    public const float Gap = 10f;
    public const float HandleHit = 18f;
    public const float RadiusChrome = 10f;
    public const float RadiusHint = 6f;
    public const float RadiusBtn = 6f;
    public const float HintPadX = 8f;
    public const float HintPadY = 5f;
    public const float HintMaxW = 240f;
    public const float HintMinW = 60f;
    public const float HintMinH = 24f;
    public const float HintGap = 6f;
    public const float EditorMinW = 560f;
    public const float EditorMinViewportH = 200f;

    /// Device-independent units to real pixels.
    public static int Px(float dip, int dpi) => (int)Math.Round(dip * dpi / 96.0);

    public static float PxF(float dip, int dpi) => dip * dpi / 96f;
}
