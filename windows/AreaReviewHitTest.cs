using System.Drawing;

namespace Snippr;

/// Where the review surface's chrome is, as a question anything can ask.
///
/// The overlay toolbar is a transparent control laid over the whole screen, so
/// every click reaches IT rather than the surface underneath — including the
/// clicks meant to draw. The form forwards those, and this is the rule it
/// forwards by: only the rail and the strip are chrome, everything else is the
/// picture. It lives on its own so the rule can be checked without a screen.
static class AreaReviewHitTest
{
    public static bool IsChrome(Point point, RectangleF toolFrame, RectangleF actionFrame) =>
        toolFrame.Contains(point) || actionFrame.Contains(point);

    /// True when a click at this point should draw on the capture.
    public static bool IsCanvas(
        Point point, RectangleF toolFrame, RectangleF actionFrame, bool chromeVisible) =>
        !chromeVisible || !IsChrome(point, toolFrame, actionFrame);
}
