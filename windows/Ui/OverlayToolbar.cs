using System.Drawing.Drawing2D;

namespace Snippr;

/// Floating overlay chrome. Raises IconKey strings only — no OverlayAction
/// enum (that lives in ToolCatalog).
///
/// This control deliberately does NOT answer WM_NCHITTEST with HTTRANSPARENT
/// outside its rail and strip. It used to, from the days when it was a shell
/// with no host; `AreaReviewForm` then docked it Fill over the whole surface
/// and routed the picture's mouse events THROUGH it, and the two rules were
/// never reconciled. Click-through won, so every press on the picture fell to
/// a form that has no mouse handlers: no drawing, no crop drag, no cursor —
/// which is what "none of the buttons work" turned out to be.
sealed class OverlayToolbar : Control
{
    public event EventHandler<string>? ToolSelected;
    public event EventHandler<string>? ActionInvoked;
    /// The plate's corner rounding, chosen from the backdrop menu. Not an
    /// action id: it carries a style, and it does not displace the tool.
    public event EventHandler<BackdropCornerStyle>? CornerChosen;

    readonly ChromePanel _rail = new();
    readonly ChromePanel _strip = new();
    readonly List<OverlayButton> _toolButtons = new();
    readonly List<OverlayButton> _actionButtons = new();
    readonly HoverHint _hint;
    readonly BackdropMenu _menu = new();
    Color _color = Theme.Accent;
    string? _active;
    Rectangle _lastSelection;
    Rectangle _lastScreen;
    bool _havePlace;

    static readonly (string Key, string Hint)[] DefaultTools =
    [
        ("select", "Select / move (V)"),
        ("arrow", "Arrow (A)"),
        ("line", "Line (L)"),
        ("rect", "Rectangle (R)"),
        ("oval", "Oval (O)"),
        ("highlight", "Highlighter (H)"),
        ("pen", "Pen (P)"),
        ("text", "Text (T)"),
        ("counter", "Counter (N)"),
        ("pixelate", "Pixelate (B)"),
    ];

    static readonly (string Key, string Hint)[] DefaultActions =
    [
        ("backdrop", "Backdrop"),
        ("color", "Annotation color"),
        ("undo", "Undo (Ctrl+Z)"),
        ("redo", "Redo (Ctrl+Y)"),
        ("copy", "Copy to clipboard (Ctrl+C)"),
        ("save", "Save as… (Ctrl+S)"),
        ("pin", "Pin to screen (Ctrl+P)"),
        ("ocr", "Recognize text"),
        ("translate", "Recognize + translate"),
        ("editor", "Open in editor (E)"),
        ("close", "Close (Esc)"),
    ];

    public OverlayToolbar()
    {
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        TabStop = false;
        Controls.Add(_rail);
        Controls.Add(_strip);
        SetTools(DefaultTools);
        SetActions(DefaultActions);
        _hint = HoverHint.Attach(this, HintAt);
        // Honey binds Menu.PresetChosen for compose. Forward the same id so a
        // single ActionInvoked listener can see "none|ocean|sunset|mint|graphite".
        _menu.PresetChosen += (_, id) => ActionInvoked?.Invoke(this, id);
        _menu.CornerChosen += (_, style) => CornerChosen?.Invoke(this, style);
    }

    /// Raises exactly what a click on that button raises. The headless smoke
    /// entry uses it: no desktop, no mouse, same path.
    internal void RaiseToolForTesting(string iconKey) =>
        ToolSelected?.Invoke(this, iconKey);

    internal void RaiseActionForTesting(string iconKey) =>
        ActionInvoked?.Invoke(this, iconKey);

    public BackdropMenu Menu => _menu;
    public HoverHint Hint => _hint;

    public void SetTools(IEnumerable<(string IconKey, string Hint)> tools)
    {
        Rebuild(_rail, _toolButtons, tools, isTool: true);
        if (_havePlace) Place(_lastSelection, _lastScreen);
    }

    public void SetActions(IEnumerable<(string IconKey, string Hint)> actions)
    {
        Rebuild(_strip, _actionButtons, actions, isTool: false);
        if (_havePlace) Place(_lastSelection, _lastScreen);
    }

    public void SetActive(string? iconKey)
    {
        _active = iconKey;
        foreach (var b in _toolButtons) b.Checked = b.IconKey == iconKey;
    }

    public void SetUndoRedo(bool canUndo, bool canRedo)
    {
        foreach (var b in _actionButtons)
        {
            if (b.IconKey == "undo") b.Enabled = canUndo;
            if (b.IconKey == "redo") b.Enabled = canRedo;
        }
    }

    public void SetColor(Color color)
    {
        _color = color;
        foreach (var b in _actionButtons)
            if (b.IconKey == "color") { b.Tint = color; b.Invalidate(); }
    }

    /// <paramref name="selection"/> and <paramref name="screen"/> are in this
    /// control's client space (Honey docks the toolbar Fill on the overlay).
    /// Named Place — Control.Layout is already a WinForms event.
    public void Place(Rectangle selection, Rectangle screen)
    {
        _lastSelection = selection;
        _lastScreen = screen;
        _havePlace = true;
        var metrics = OverlayToolbarLayout.Metrics.Standard.Scaled(DeviceDpi / 96f);
        var area = OverlayToolbarLayout.Compute(
            selection, screen, _toolButtons.Count, _actionButtons.Count,
            Theme.HandleHit * DeviceDpi / 96f, metrics);
        if (area is not { } placed)
        {
            _rail.Visible = false;
            _strip.Visible = false;
            return;
        }
        _rail.Visible = true;
        _strip.Visible = true;
        _rail.Bounds = Rectangle.Round(placed.ToolFrame);
        _strip.Bounds = Rectangle.Round(placed.ActionFrame);
        PlaceButtons(_toolButtons, placed.ToolButtonFramesLocal);
        PlaceButtons(_actionButtons, placed.ActionButtonFramesLocal);
    }

    string? HintAt(Point pt)
    {
        foreach (var b in _toolButtons.Concat(_actionButtons))
        {
            var screen = b.RectangleToScreen(b.ClientRectangle);
            var local = RectangleToClient(screen);
            if (local.Contains(pt)) return b.Hint;
        }
        return null;
    }

    void Rebuild(
        ChromePanel panel,
        List<OverlayButton> list,
        IEnumerable<(string IconKey, string Hint)> items,
        bool isTool)
    {
        foreach (var b in list) b.Dispose();
        list.Clear();
        panel.Controls.Clear();
        foreach (var (key, hint) in items)
        {
            var btn = new OverlayButton(key, hint);
            if (key == "color") btn.Tint = _color;
            btn.Click += (_, _) => OnButton(btn, isTool);
            panel.Controls.Add(btn);
            list.Add(btn);
        }
        if (isTool) SetActive(_active);
    }

    void OnButton(OverlayButton btn, bool isTool)
    {
        _hint.HideNow();
        if (isTool)
        {
            SetActive(btn.IconKey);
            ToolSelected?.Invoke(this, btn.IconKey);
            return;
        }
        if (btn.IconKey == "backdrop")
        {
            var at = btn.PointToScreen(new Point(0, btn.Height));
            _menu.Show(at);
            return; // preset arrives via PresetChosen / ActionInvoked(id)
        }
        ActionInvoked?.Invoke(this, btn.IconKey);
    }

    static void PlaceButtons(List<OverlayButton> buttons, RectangleF[] local)
    {
        int n = Math.Min(buttons.Count, local.Length);
        for (int i = 0; i < n; i++)
            buttons[i].Bounds = Rectangle.Round(local[i]);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hint.Dispose();
            _menu.Dispose();
        }
        base.Dispose(disposing);
    }

    sealed class ChromePanel : Control
    {
        public ChromePanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = ClientRectangle;
            r.Width -= 1;
            r.Height -= 1;
            using var path = Round(r, Theme.PxF(Theme.RadiusChrome, DeviceDpi));
            using var fill = new SolidBrush(Theme.ChromeRaised);
            using var border = new Pen(Theme.Hairline);
            g.FillPath(fill, path);
            g.DrawPath(border, path);
        }
    }

    sealed class OverlayButton : Control
    {
        public string IconKey { get; }
        public string Hint { get; }
        public Color? Tint { get; set; }
        public bool Checked { get; set; }

        bool _hover;
        bool _press;

        public OverlayButton(string key, string hint)
        {
            IconKey = key;
            Hint = hint;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _press = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { _press = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _press = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = ClientRectangle;
            r.Inflate(-1, -1);
            Color? fill = _press ? Theme.Pressed
                : Checked ? Theme.Selected
                : _hover ? Theme.Hover
                : null;
            if (fill is not null)
            {
                using var path = Round(r, Theme.PxF(Theme.RadiusBtn, DeviceDpi));
                using var brush = new SolidBrush(fill.Value);
                g.FillPath(brush, path);
            }
            int side = Theme.Scale(Theme.OverlayIcon, DeviceDpi);
            var dest = new RectangleF(
                (Width - side) / 2f, (Height - side) / 2f, side, side);
            Color color = Tint
                ?? (IconKey == "close" && _hover ? Theme.Danger
                    : Checked ? Theme.Accent
                    : Enabled ? Theme.Icon
                    : Theme.IconMuted);
            Icons.Draw(g, IconKey, dest, color);
        }
    }

    static GraphicsPath Round(Rectangle r, float radius)
    {
        var path = new GraphicsPath();
        if (r.Width <= 0 || r.Height <= 0) return path;
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
