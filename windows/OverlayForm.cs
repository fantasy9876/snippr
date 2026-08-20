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
        // WinForms clamps Form.Size to SystemInformation.MaxWindowTrackSize.
        // That metric is the whole desktop, so asking for the virtual screen
        // is within it; the ceiling is set anyway, before the bounds, so the
        // window is never the thing that trims itself.
        MaximumSize = virtualBounds.Size;
        Bounds = virtualBounds;
        TopMost = true;
        ShowInTaskbar = false;
        Cursor = Cursors.Cross;
        KeyPreview = true;
        // Opaque + a buffer of our own, NOT DoubleBuffered. WinForms buffers a
        // control by asking for a bitmap the size of its CLIENT rectangle, and
        // this window is the whole virtual desktop: every crosshair move was
        // allocating and freeing a full-screen DIB. The picture is identical —
        // one buffered blit per frame — but the buffer is made once.
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
            | ControlStyles.Opaque, true);
    }

    readonly PaintBuffer _buffer = new();

    /// What the window asked for and what it got. `MaxWindowTrackSize` is the
    /// whole DESKTOP, not the primary monitor, so a window asking for the
    /// virtual screen is not trimmed — but that is a claim about someone
    /// else's machine, and this line is how it gets checked on theirs.
    ///
    /// Measured at Shown, not at handle creation: the borderless style is not
    /// applied yet at creation, so the client area reads short there and the
    /// one line someone sends us to settle this would start the argument
    /// again.
    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Diag.Click(
            "overlay",
            $"window asked={_virtualBounds.Size} got={Size} client={ClientSize}");
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

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var clip = Rectangle.Intersect(e.ClipRectangle, ClientRectangle);
        if (clip.Width <= 0 || clip.Height <= 0) return;
        var buffer = _buffer.For(clip.Size);
        if (buffer is null)
        {
            // No buffer to be had: a torn frame beats a blank one.
            PaintInto(e.Graphics, clip);
            return;
        }
        using (var back = Graphics.FromImage(buffer))
        {
            back.TranslateTransform(-clip.X, -clip.Y);
            // Set AFTER the transform: SetClip takes world coordinates.
            back.SetClip(clip);
            PaintInto(back, clip);
        }
        e.Graphics.DrawImage(
            buffer, clip, new Rectangle(Point.Empty, clip.Size), GraphicsUnit.Pixel);
    }

    void PaintInto(Graphics g, Rectangle clip)
    {
        // An opaque ground first. The buffer starts fully transparent and the
        // screen DC it stands in for has no alpha channel at all, so a frozen
        // capture whose alpha bytes came back as zero would composite to the
        // desktop against one and to nothing against the other.
        g.FillRectangle(Ground, clip);
        g.DrawImageUnscaled(_frozen, 0, 0);

        var sel = SelectionLocal;
        if (sel is Rectangle r)
        {
            // Bands, not a Region: same coverage, no GDI object per frame.
            Span<Rectangle> bands = stackalloc Rectangle[4];
            int n = CropGeometry.Surround(clip, r, bands);
            for (int i = 0; i < n; i++) g.FillRectangle(Dim, bands[i]);

            g.DrawRectangle(SelectionEdge, r);

            string label = $"{r.Width} × {r.Height}";
            DrawBubble(g, label, new Point(r.Right + 8, r.Bottom + 6));
        }
        else
        {
            g.FillRectangle(Dim, clip);
            g.DrawLine(Crosshair, _current.X, 0, _current.X, Height);
            g.DrawLine(Crosshair, 0, _current.Y, Width, _current.Y);
        }
    }

    /// Made once. These never vary, and building them per paint meant three
    /// unmanaged GDI+ handles created and destroyed on every mouse move.
    static readonly SolidBrush Ground = new(Color.Black);
    static readonly SolidBrush Dim = new(Color.FromArgb(105, Color.Black));
    static readonly Pen SelectionEdge = new(Color.DeepSkyBlue, 1.6f);
    static readonly Pen Crosshair = new(Color.FromArgb(170, Color.White), 1f);
    static readonly Font BubbleFont = new("Segoe UI", 9.5f, FontStyle.Bold);
    static readonly SolidBrush BubbleBack = new(Color.FromArgb(195, Color.Black));

    static void DrawBubble(Graphics g, string text, Point at)
    {
        var size = g.MeasureString(text, BubbleFont);
        var rect = new RectangleF(at.X, at.Y, size.Width + 12, size.Height + 6);
        g.FillRectangle(BubbleBack, rect);
        g.DrawString(text, BubbleFont, Brushes.White, at.X + 6, at.Y + 3);
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

    protected override void Dispose(bool disposing)
    {
        if (disposing) _buffer.Dispose();
        base.Dispose(disposing);
    }
}
