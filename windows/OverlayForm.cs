namespace Snippr;

/// Fullscreen frozen-desktop overlay: drag to select an area, Esc to cancel.
sealed class OverlayForm : Form
{
    readonly Bitmap _frozen;
    readonly Rectangle _virtualBounds;
    Point? _dragStart;
    Point _current;
    public Rectangle? SelectedVirtualRect { get; private set; }

    /// True while the frozen-desktop picker is on screen — lets hotkey
    /// handlers refuse re-entrant captures that would photograph the overlay.
    public static bool IsActive { get; private set; }

    public static (Bitmap? shot, Rectangle virtualRect) SelectArea()
    {
        var frozen = CaptureUtil.VirtualScreen(out var bounds);
        using var overlay = new OverlayForm(frozen, bounds);
        IsActive = true;
        try
        {
            overlay.ShowDialog();
        }
        finally
        {
            IsActive = false;
        }
        if (overlay.SelectedVirtualRect is Rectangle rect && rect.Width > 3 && rect.Height > 3)
        {
            var cropped = CaptureUtil.CropVirtual(frozen, bounds, rect);
            frozen.Dispose();
            if (cropped == null) return (null, Rectangle.Empty);
            return (cropped, rect);
        }
        frozen.Dispose();
        return (null, Rectangle.Empty);
    }

    /// Selection only, keeping the frozen desktop alive for the caller.
    ///
    /// `SelectArea` crops and disposes, which is what every route wanted until
    /// the review surface: reviewing happens ON the frozen desktop, and the
    /// crop can still move while it does, so the caller needs the whole
    /// picture and the rect — not a cut-out of it. The caller owns the bitmap.
    public static (Bitmap? Frozen, Rectangle Bounds, Rectangle SelectionLocal) SelectForReview()
    {
        var frozen = CaptureUtil.VirtualScreen(out var bounds);
        using var overlay = new OverlayForm(frozen, bounds);
        IsActive = true;
        try
        {
            overlay.ShowDialog();
        }
        finally
        {
            IsActive = false;
        }
        if (overlay.SelectedVirtualRect is Rectangle rect
            && rect.Width > 3 && rect.Height > 3)
        {
            var local = new Rectangle(
                rect.X - bounds.X, rect.Y - bounds.Y, rect.Width, rect.Height);
            return (frozen, bounds, local);
        }
        frozen.Dispose();
        return (null, bounds, Rectangle.Empty);
    }

    OverlayForm(Bitmap frozen, Rectangle virtualBounds)
    {
        _frozen = frozen;
        _virtualBounds = virtualBounds;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        // WinForms clamps Form.Size to SystemInformation.MaxWindowTrackSize —
        // the PRIMARY monitor plus a border — unless MaximumSize says
        // otherwise. On a multi-monitor desktop the virtual screen is wider
        // than that, so the overlay silently came up smaller than the picture
        // it is showing and the chrome was laid out against a client area
        // that did not reach the crop. Set the ceiling before the bounds.
        MaximumSize = virtualBounds.Size;
        Bounds = virtualBounds;
        TopMost = true;
        ShowInTaskbar = false;
        Cursor = Cursors.Cross;
        KeyPreview = true;
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
            | ControlStyles.OptimizedDoubleBuffer, true);
    }

    /// The window must be allowed to be as large as the picture it shows —
    /// see Native.AnswerMinMaxInfo. MaximumSize alone left it clamped to the
    /// primary monitor, which CI caught: bounds 1280x800, client 1044x788.
    protected override void WndProc(ref Message m)
    {
        if (Native.AnswerMinMaxInfo(ref m, _virtualBounds)) return;
        base.WndProc(ref m);
    }


    Rectangle? SelectionLocal
    {
        get
        {
            if (_dragStart is not Point a) return null;
            var b = _current;
            return new Rectangle(
                Math.Min(a.X, b.X), Math.Min(a.Y, b.Y),
                Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.DrawImageUnscaled(_frozen, 0, 0);

        using var dim = new SolidBrush(Color.FromArgb(105, Color.Black));
        var sel = SelectionLocal;
        if (sel is Rectangle r)
        {
            var region = new Region(ClientRectangle);
            region.Exclude(r);
            g.FillRegion(dim, region);
            region.Dispose();

            using var pen = new Pen(Color.DeepSkyBlue, 1.6f);
            g.DrawRectangle(pen, r);

            string label = $"{r.Width} × {r.Height}";
            DrawBubble(g, label, new Point(r.Right + 8, r.Bottom + 6));
        }
        else
        {
            g.FillRectangle(dim, ClientRectangle);
            using var cross = new Pen(Color.FromArgb(170, Color.White), 1f);
            g.DrawLine(cross, _current.X, 0, _current.X, Height);
            g.DrawLine(cross, 0, _current.Y, Width, _current.Y);
        }
    }

    static void DrawBubble(Graphics g, string text, Point at)
    {
        using var font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
        var size = g.MeasureString(text, font);
        var rect = new RectangleF(at.X, at.Y, size.Width + 12, size.Height + 6);
        using var bg = new SolidBrush(Color.FromArgb(195, Color.Black));
        g.FillRectangle(bg, rect);
        g.DrawString(text, font, Brushes.White, at.X + 6, at.Y + 3);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) { _dragStart = e.Location; _current = e.Location; }
        else Close(); // right-click cancels
    }

    /// Areas the marquee/crosshair touched on the previous frame — only these
    /// (plus the new ones) are repainted, instead of the whole virtual screen
    /// on every mouse move.
    Rectangle[] _dirty = Array.Empty<Rectangle>();

    Rectangle[] CurrentDirty()
    {
        if (SelectionLocal is Rectangle r)
        {
            // selection border + interior (dim area changes as it grows/shrinks)
            // + room for the size bubble at bottom-right
            return new[] { Rectangle.Inflate(r, 4, 4), new Rectangle(r.Right, r.Bottom, 200, 48) };
        }
        return new[]
        {
            new Rectangle(_current.X - 2, 0, 5, Height),
            new Rectangle(0, _current.Y - 2, Width, 5),
        };
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var prev = _dirty;
        _current = e.Location;
        _dirty = CurrentDirty();
        foreach (var rect in prev) Invalidate(rect);
        foreach (var rect in _dirty) Invalidate(rect);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (SelectionLocal is Rectangle r && r.Width > 3 && r.Height > 3)
        {
            SelectedVirtualRect = new Rectangle(
                r.X + _virtualBounds.X, r.Y + _virtualBounds.Y, r.Width, r.Height);
        }
        Close();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) Close();
    }
}
