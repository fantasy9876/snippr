using System.Drawing;

namespace Snippr;

/// The region OCR pick, as a state machine with no screen in it.
///
/// macOS keeps this state in the overlay view (`ocrRegionPicking`,
/// `ocrRegionAnchor`, `ocrRegion` in `SelectionOverlay.swift`), and paid for
/// it: the mode existed in the places that SET it and not in the places that
/// answered questions about it, so the cursor table and the tool router both
/// behaved as if it were not there. Here the mode is one object, and every
/// question — what the pointer means, what a drag does, what Escape unwinds —
/// is asked of it.
///
/// Lives platform-free so the parity gate runs the whole thing on the machine
/// the port is written on.
sealed class OcrRegionPick
{
    /// Below this a drag is a stray click, and a recognizer handed a 3px strip
    /// returns noise the user has to undo. Same number as macOS
    /// `OverlayOCRPanel.minimumRegionSide`.
    public const int MinimumSide = 8;

    public bool Armed { get; private set; }

    /// True once the mode was armed FOR a translation. The pick is the same
    /// either way — one shape, one drag — and this only decides what happens
    /// to the text after the recognizer answers.
    public bool Translates { get; private set; }

    Point? _anchor;

    /// The rectangle the drag has described so far, in the frozen image's
    /// pixels, or null before the drag begins.
    public Rectangle? Region { get; private set; }

    /// Bumped on every arm, cancel and finish. A recognition already in flight
    /// carries the value it started with, so a result for a region the user
    /// has abandoned can be dropped instead of landing in a panel that now
    /// describes different pixels.
    public int Generation { get; private set; }

    public void Arm(bool translates)
    {
        Armed = true;
        Translates = translates;
        _anchor = null;
        Region = null;
        Generation++;
    }

    /// True when there was something to cancel, so a caller can tell "Escape
    /// closed the pick" from "Escape should close the session".
    public bool Cancel()
    {
        if (!Armed) return false;
        Armed = false;
        _anchor = null;
        Region = null;
        Generation++;
        return true;
    }

    public bool Begin(Point pointPx, Rectangle crop)
    {
        if (!Armed) return false;
        _anchor = Clamp(pointPx, crop);
        Region = Rectangle.FromLTRB(
            _anchor.Value.X, _anchor.Value.Y, _anchor.Value.X, _anchor.Value.Y);
        return true;
    }

    public bool Drag(Point pointPx, Rectangle crop)
    {
        if (!Armed || _anchor is not { } anchor) return false;
        Region = Normalize(anchor, Clamp(pointPx, crop));
        return true;
    }

    /// Ends the drag. Returns the region when it is big enough to recognize,
    /// and null when it is not — a stray click leaves the mode ARMED so the
    /// user can simply drag again, rather than silently dropping them back
    /// into a review whose toolbar shows no sign the mode ever started.
    public Rectangle? Finish(Point pointPx, Rectangle crop)
    {
        if (!Armed || _anchor is not { } anchor) return null;
        var rect = Normalize(anchor, Clamp(pointPx, crop));
        _anchor = null;
        if (rect.Width < MinimumSide || rect.Height < MinimumSide)
        {
            Region = null;
            return null;
        }
        Armed = false;
        Region = rect;
        Generation++;
        return rect;
    }

    static Point Clamp(Point p, Rectangle crop) => new(
        Math.Min(crop.Right, Math.Max(crop.Left, p.X)),
        Math.Min(crop.Bottom, Math.Max(crop.Top, p.Y)));

    /// Any drag direction gives the same rectangle: dragging up-left is how
    /// half of people select, and a negative-width rect recognizes nothing.
    static Rectangle Normalize(Point a, Point b) => Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y),
        Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
}
