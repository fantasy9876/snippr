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

    /// True when this event should reach the picture.
    ///
    /// `dragInProgress` is not a convenience: once a gesture has begun the
    /// mouse is CAPTURED, so every later event belongs to that gesture no
    /// matter what the pointer is over. Asking the hit test again mid-drag
    /// dropped the events whose pointer crossed the toolbar — a crop that
    /// stalled while the pointer passed the rail, and a pen stroke with a gap
    /// in it. Worse, the toolbar is re-placed DURING a crop drag, so the
    /// chrome could move under the pointer and open a dead zone that was not
    /// there when the drag started. The hit test decides whether a gesture may
    /// BEGIN; it does not get to interrupt one.
    public static bool IsCanvas(
        Point point, RectangleF toolFrame, RectangleF actionFrame,
        bool chromeVisible, bool dragInProgress) =>
        dragInProgress || !chromeVisible || !IsChrome(point, toolFrame, actionFrame);
}
