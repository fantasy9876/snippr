using System.Drawing;

namespace Snippr;

/// Dragging the crop while reviewing it: which handle was grabbed, and what
/// the rect becomes as the pointer moves.
///
/// Arithmetic, deliberately: the review surface has no screen to be tested on,
/// so the part that decides where the crop ENDS UP is kept where a gate can
/// reach it. The eight handles are the UI lane's own `HandleRects`, in its own
/// order, so the hit region and the drawn handle cannot drift apart.
enum CropGrip
{
    None = -1,
    TopLeft = 0, Top = 1, TopRight = 2,
    Left = 3, Right = 4,
    BottomLeft = 5, Bottom = 6, BottomRight = 7,
    Inside = 8,
}

static class AreaReviewCrop
{
    /// The handle under a point, or `Inside` for the body of the crop, or
    /// `None` for the surround. Handles win over the body: they overlap it,
    /// and a corner grab must resize rather than move.
    public static CropGrip GripAt(
        Point point, Rectangle selection, float handleSize, float cornerRadius = 0)
    {
        var handles = OverlayToolbarLayout.HandleRects(selection, handleSize, cornerRadius);
        for (int i = 0; i < handles.Length; i++)
            if (handles[i].Contains(point)) return (CropGrip)i;
        return selection.Contains(point) ? CropGrip.Inside : CropGrip.None;
    }

    /// The crop after dragging `grip` from where it was pressed to `to`.
    /// `original` is the rect as it was when the drag STARTED, so a drag can
    /// never accumulate rounding, and edges may be dragged past each other:
    /// the result is normalized rather than refused.
    public static Rectangle Drag(
        CropGrip grip, Rectangle original, Point from, Point to)
    {
        int dx = to.X - from.X, dy = to.Y - from.Y;
        if (grip == CropGrip.Inside)
            return new Rectangle(
                original.X + dx, original.Y + dy, original.Width, original.Height);

        int left = original.Left, top = original.Top;
        int right = original.Right, bottom = original.Bottom;
        switch (grip)
        {
            case CropGrip.TopLeft: left += dx; top += dy; break;
            case CropGrip.Top: top += dy; break;
            case CropGrip.TopRight: right += dx; top += dy; break;
            case CropGrip.Left: left += dx; break;
            case CropGrip.Right: right += dx; break;
            case CropGrip.BottomLeft: left += dx; bottom += dy; break;
            case CropGrip.Bottom: bottom += dy; break;
            case CropGrip.BottomRight: right += dx; bottom += dy; break;
            default: return original;
        }
        return Rectangle.FromLTRB(
            Math.Min(left, right), Math.Min(top, bottom),
            Math.Max(left, right), Math.Max(top, bottom));
    }
}

/// Pointer shape for the review surface, as a table the parity gate can
/// read. The WinForms `Cursor` mapping lives next to the form; this is the
/// (tool, hit) answer both `SelectTool` and `CanvasMouseMove` must use, so a
/// tool switch cannot leave a leftover grip cursor.
enum ReviewCursorKind
{
    Cross,
    IBeam,
    SizeAll,
    SizeWE,
    SizeNS,
    SizeNWSE,
    SizeNESW,
}

static class AreaReviewCursor
{
    public static ReviewCursorKind For(Tool tool, CropGrip grip)
    {
        if (tool == Tool.Text) return ReviewCursorKind.IBeam;
        if (tool != Tool.Select) return ReviewCursorKind.Cross;
        return grip switch
        {
            CropGrip.TopLeft or CropGrip.BottomRight => ReviewCursorKind.SizeNWSE,
            CropGrip.TopRight or CropGrip.BottomLeft => ReviewCursorKind.SizeNESW,
            CropGrip.Top or CropGrip.Bottom => ReviewCursorKind.SizeNS,
            CropGrip.Left or CropGrip.Right => ReviewCursorKind.SizeWE,
            CropGrip.Inside => ReviewCursorKind.SizeAll,
            _ => ReviewCursorKind.Cross,
        };
    }
}
