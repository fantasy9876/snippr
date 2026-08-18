namespace Snippr;

/// The editor's two toolbar rows, in real pixels for a real display.
///
/// Every chrome number is written in device-independent units and was being
/// used as PIXELS. At 100% those are the same thing; at 150% — which is what
/// most office laptops ship at — two 35-unit rows no longer fit in a 70-pixel
/// strip, the tool row (docked Fill) gets what is left of nothing, and the
/// buttons are not small, they are ABSENT. With overflow switched off, an item
/// that does not fit is not moved anywhere: it just is not there. That is one
/// cause for both halves of "the toolbar is ugly and no button works".
///
/// It lives apart from the form so the arithmetic can be checked at several
/// DPIs without a display.
readonly record struct EditorChromeMetrics(
    int Dpi,
    int RowHeight,
    int ChromeHeight,
    int ButtonWidth,
    int ButtonHeight,
    int IconSize,
    int Spacing,
    int RequiredWidth,
    int MinimumWindowWidth)
{
    public static EditorChromeMetrics For(int dpi, int actionItems, int toolItems)
    {
        int rowH = ThemeMetrics.Px(ThemeMetrics.EditorRowH, dpi);
        int btnW = ThemeMetrics.Px(ThemeMetrics.EditorBtnW, dpi);
        int btnH = ThemeMetrics.Px(ThemeMetrics.EditorBtnH, dpi);
        int spacing = Math.Max(1, ThemeMetrics.Px(ThemeMetrics.Spacing, dpi));
        // A row has to be at least as tall as the button in it, plus the
        // margins the button carries; the chrome has to hold two of them.
        int rowMargin = ThemeMetrics.Px(3, dpi) * 2;
        rowH = Math.Max(rowH, btnH + rowMargin);
        int chromeH = rowH * 2;
        // The widest row decides how wide the window has to be before a button
        // starts falling off the end. Labels and the separator ride along, so
        // there is slack in the number rather than the other way round.
        int widest = Math.Max(actionItems, toolItems);
        int required = widest * (btnW + spacing * 2) + ThemeMetrics.Px(ThemeMetrics.Pad, dpi) * 2;
        int labels = ThemeMetrics.Px(220, dpi); // zoom + size + stroke width, right-aligned
        return new EditorChromeMetrics(
            dpi, rowH, chromeH, btnW, btnH,
            ThemeMetrics.Px(ThemeMetrics.EditorIcon, dpi), spacing,
            required + labels,
            Math.Max(ThemeMetrics.Px(ThemeMetrics.EditorMinW, dpi), required + labels));
    }

    public (int Width, int Height) ButtonSize => (ButtonWidth, ButtonHeight);
}
