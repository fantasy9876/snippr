using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Snippr;

/// Owner-drawn HUD. Click-through, no activation, clamped to the allowed
/// working area. Contract: <see cref="Attach"/> + <see cref="HideNow"/>.
sealed class HoverHint : Form
{
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter,
        int x, int y, int cx, int cy, uint flags);

    const uint SwpNosize = 0x0001;
    const uint SwpNomove = 0x0002;
    const uint SwpNoactivate = 0x0010;
    const uint SwpShowwindow = 0x0040;
    static readonly IntPtr HwndTop = IntPtr.Zero;

    readonly Control _host;
    readonly Func<Point, string?> _hintAt;
    readonly System.Windows.Forms.Timer _delay = new() { Interval = Theme.HintDelayMs };
    string? _pending;
    string? _shown;
    Rectangle _anchor;

    HoverHint(Control host, Func<Point, string?> hintAt)
    {
        _host = host;
        _hintAt = hintAt;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.FromArgb(20, 21, 24);
        DoubleBuffered = true;
        Padding = Padding.Empty;
        _delay.Tick += (_, _) => ShowPending();

        Wire(host);
        host.Disposed += (_, _) => Dispose();
        if (host.FindForm() is Form owner)
        {
            Owner = owner;
            owner.Deactivate += (_, _) => HideNow();
            owner.Move += (_, _) => HideNow();
        }
    }

    /// ToolStrip items are not child Controls; OverlayToolbar buttons are.
    /// Subscribe both, and translate every event into host coordinates.
    void Wire(Control c)
    {
        c.MouseMove += OnAnyMouseMove;
        c.MouseDown += (_, _) => HideNow();
        c.MouseLeave += OnAnyMouseLeave;
        c.ControlAdded += (_, e) => { if (e.Control is { } child) Wire(child); };
        foreach (Control child in c.Controls)
            Wire(child);
    }

    public static HoverHint Attach(Control host, Func<Point, string?> hintAt)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(hintAt);
        return new HoverHint(host, hintAt);
    }

    public void HideNow()
    {
        _delay.Stop();
        _pending = null;
        _shown = null;
        if (IsHandleCreated && Visible) Hide();
    }

    /// Places a hint of <paramref name="size"/> relative to <paramref name="anchor"/>
    /// inside <paramref name="allowed"/>. Null when the leftover hole is under 60×24.
    public static Rectangle? Place(Size size, Rectangle anchor, Rectangle allowed) =>
        Place(size, anchor, allowed, 96);

    /// The same placement, in real pixels for a given display. Minimums and
    /// gaps are device-independent units: on a 150% display an unscaled 60×24
    /// minimum lets a hint through that is two thirds the size it should be.
    public static Rectangle? Place(Size size, Rectangle anchor, Rectangle allowed, int dpi)
    {
        int minW = Theme.Px(Theme.HintMinW, dpi);
        int minH = Theme.Px(Theme.HintMinH, dpi);
        if (allowed.Width < minW || allowed.Height < minH)
            return null;
        int gap = Theme.Px(Theme.HintGap, dpi);
        int x = anchor.Left + (anchor.Width - size.Width) / 2;
        x = Math.Clamp(x, allowed.Left, Math.Max(allowed.Left, allowed.Right - size.Width));
        int below = anchor.Bottom + gap;
        int above = anchor.Top - gap - size.Height;
        int y;
        if (below + size.Height <= allowed.Bottom) y = below;
        else if (above >= allowed.Top) y = above;
        else y = Math.Clamp(below, allowed.Top, Math.Max(allowed.Top, allowed.Bottom - size.Height));

        var placed = new Rectangle(x, y, size.Width, size.Height);
        placed.Intersect(allowed);
        if (placed.Width < minW || placed.Height < minH)
            return null;
        return placed;
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        const int WmNcHitTest = 0x0084;
        const int HtTransparent = -1;
        if (m.Msg == WmNcHitTest)
        {
            m.Result = HtTransparent;
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = ClientRectangle;
        bounds.Width -= 1;
        bounds.Height -= 1;
        using var path = Round(bounds, Theme.PxF(Theme.RadiusHint, HostDpi));
        using var bg = new SolidBrush(Theme.HintBg);
        using var border = new Pen(Theme.HintBorder);
        g.FillPath(bg, path);
        g.DrawPath(border, path);
        if (_shown is null) return;
        var text = new Rectangle(
            bounds.X + Theme.Px(Theme.HintPadX, HostDpi),
            bounds.Y + Theme.Px(Theme.HintPadY, HostDpi),
            bounds.Width - Theme.Px(Theme.HintPadX, HostDpi) * 2,
            bounds.Height - Theme.Px(Theme.HintPadY, HostDpi) * 2);
        TextRenderer.DrawText(
            g, _shown, Theme.HintFont, text, Theme.HintText,
            TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPadding);
    }

    void OnAnyMouseMove(object? sender, MouseEventArgs e)
    {
        if (sender is not Control src || _host.IsDisposed) return;
        var hostPt = _host.PointToClient(src.PointToScreen(e.Location));
        var text = _hintAt(hostPt);
        if (string.IsNullOrWhiteSpace(text))
        {
            HideNow();
            return;
        }
        var item = HitBounds(hostPt);
        if (text == _shown && Visible) return;
        if (text == _pending)
        {
            _anchor = item;
            return;
        }
        _pending = text;
        _anchor = item;
        _delay.Stop();
        _delay.Start();
    }

    void OnAnyMouseLeave(object? sender, EventArgs e)
    {
        // Moving between child buttons fires Leave on the child while the
        // cursor is still inside the host — hide only once it really left.
        if (!_host.IsHandleCreated || _host.IsDisposed) { HideNow(); return; }
        _host.BeginInvoke(new Action(() =>
        {
            if (_host.IsDisposed) return;
            var r = _host.RectangleToScreen(_host.ClientRectangle);
            if (!r.Contains(Control.MousePosition)) HideNow();
        }));
    }

    Rectangle HitBounds(Point hostPt)
    {
        if (_host is ToolStrip strip && strip.GetItemAt(hostPt) is ToolStripItem item)
            return strip.RectangleToScreen(item.Bounds);
        var child = ChildAt(_host, _host.PointToScreen(hostPt));
        if (child != null && child != _host)
            return child.RectangleToScreen(child.ClientRectangle);
        return _host.RectangleToScreen(new Rectangle(hostPt.X - 8, hostPt.Y - 8, 16, 16));
    }

    static Control? ChildAt(Control root, Point screen)
    {
        foreach (Control child in root.Controls)
        {
            var hit = ChildAt(child, screen);
            if (hit != null) return hit;
        }
        return root.RectangleToScreen(root.ClientRectangle).Contains(screen) ? root : null;
    }

    void ShowPending()
    {
        _delay.Stop();
        if (_pending is null) return;
        _shown = _pending;
        var size = Measure(_shown);
        var allowed = AllowedRect();
        var placed = Place(size, _anchor, allowed, HostDpi);
        if (placed is null)
        {
            HideNow();
            return;
        }
        Size = placed.Value.Size;
        Location = placed.Value.Location;
        Invalidate();
        if (!IsHandleCreated) CreateHandle();
        SetWindowPos(
            Handle, HwndTop, placed.Value.X, placed.Value.Y,
            placed.Value.Width, placed.Value.Height,
            SwpNoactivate | SwpShowwindow);
    }

    /// The DPI of the display the HUD's host is on — every metric below is in
    /// device-independent units and has to become pixels for THAT screen.
    int HostDpi => _host.DeviceDpi;

    Size Measure(string text)
    {
        int dpi = HostDpi;
        int max = Theme.Px(Theme.HintMaxW, dpi);
        int padX = Theme.Px(Theme.HintPadX, dpi);
        int padY = Theme.Px(Theme.HintPadY, dpi);
        int minW = Theme.Px(Theme.HintMinW, dpi);
        int minH = Theme.Px(Theme.HintMinH, dpi);
        var area = AllowedRect();
        int wrap = Math.Max(1, Math.Min(max, area.Width) - padX * 2);
        var measured = TextRenderer.MeasureText(
            text, Theme.HintFont, new Size(wrap, int.MaxValue),
            TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPadding);
        int w = Math.Clamp(
            measured.Width + padX * 2,
            minW,
            Math.Min(max, Math.Max(minW, area.Width)));
        int h = Math.Max(minH, measured.Height + padY * 2);
        return new Size(w, h);
    }

    Rectangle AllowedRect()
    {
        var screen = Screen.FromControl(_host).WorkingArea;
        if (_host.FindForm() is Form form)
        {
            var hostScreen = form.RectangleToScreen(form.ClientRectangle);
            screen.Intersect(hostScreen);
        }
        return screen;
    }

    static GraphicsPath Round(Rectangle r, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _delay.Dispose();
        base.Dispose(disposing);
    }
}
