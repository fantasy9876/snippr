using System.Drawing.Imaging;

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
///
/// Covering the whole surface means this control is what the user SEES, so it
/// paints the picture as well as the chrome — see <see cref="PaintSurface"/>.
sealed class OverlayToolbar : Control
{
    public event EventHandler<string>? ToolSelected;
    public event EventHandler<string>? ActionInvoked;
    /// The plate's corner rounding, chosen from the backdrop menu. Not an
    /// action id: it carries a style, and it does not displace the tool.
    public event EventHandler<BackdropCornerStyle>? CornerChosen;

    /// What is UNDER the chrome, drawn by the host into this control's own
    /// paint. Clipped to the rectangle passed alongside it.
    ///
    /// It used to arrive by way of `BackColor = Color.Transparent`, which
    /// makes WinForms re-run the parent's whole paint into the child. That is
    /// three defects in one line. It cost TWO full-screen renders per frame —
    /// the form's own, which nothing can see under a child that covers every
    /// pixel of it, and then the emulated one. It went straight to the screen
    /// with no buffer, so each render was a visible sweep. And because a child
    /// of a transparent parent does not inherit the transparency, WinForms
    /// gave every button and both plates `SystemColors.Control` — the white
    /// they were painted on. Asking the host directly is one render, into a
    /// buffer, in colours this app chooses.
    public Action<Graphics, Rectangle>? PaintSurface { get; set; }

    readonly List<OverlayButton> _toolButtons = new();
    readonly List<OverlayButton> _actionButtons = new();
    /// Rail order: the tools, then the four actions that live with them.
    /// Kept separately from `_toolButtons` because those four are NOT tools —
    /// they must never be ticked as the active one — and separately from the
    /// strip because the layout places the rail as a single run of buttons.
    readonly List<OverlayButton> _railButtons = new();
    readonly List<OverlayButton> _stripButtons = new();
    readonly List<(string Key, string Hint)> _toolSpecs = new();
    readonly List<(string Key, string Hint)> _railActionSpecs = new();
    readonly List<(string Key, string Hint)> _stripActionSpecs = new();
    readonly HoverHint _hint;
    readonly BackdropMenu _menu = new();
    Color _color = Theme.Accent;
    string? _active;
    Rectangle _lastSelection;
    Rectangle _lastScreen;
    bool _havePlace;
    Rectangle _railFrame;
    Rectangle _stripFrame;
    bool _chromeVisible;
    /// One buffer, kept. WinForms' own OptimizedDoubleBuffer allocates for the
    /// CLIENT rectangle every paint, and this control's client rectangle is the
    /// whole virtual desktop — a 30-odd MB allocate-and-free per mouse move.
    Bitmap? _buffer;

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

    static readonly (string Key, string Hint)[] DefaultRailActions =
    [
        ("backdrop", "Backdrop (D)"),
        ("color", "Annotation color"),
        ("undo", "Undo (Ctrl+Z)"),
        ("redo", "Redo (Ctrl+Y)"),
    ];

    static readonly (string Key, string Hint)[] DefaultActions =
    [
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
        // Opaque: WinForms must not paint a background under this, because
        // this control paints every pixel of its own — the picture first, the
        // plates on top — from one buffer.
        SetStyle(
            ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.Opaque | ControlStyles.ResizeRedraw, true);
        // Never Color.Transparent: see PaintSurface. Named so that a paint
        // arriving before the host has a picture shows the app's own canvas
        // rather than the desktop's idea of a window background.
        BackColor = Theme.Canvas;
        TabStop = false;
        SetTools(DefaultTools);
        SetActions(DefaultRailActions, DefaultActions);
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
        _toolSpecs.Clear();
        _toolSpecs.AddRange(tools.Select(t => (t.IconKey, t.Hint)));
        Rebuild();
    }

    /// Two lists, because the rail and the strip are two different places and
    /// the rail's own contents are tools THEN actions. Rebuilding both at once
    /// is what keeps that order true: filling one panel at a time meant
    /// clearing the rail's tools to add an action to it.
    public void SetActions(
        IEnumerable<(string IconKey, string Hint)> railActions,
        IEnumerable<(string IconKey, string Hint)> stripActions)
    {
        _railActionSpecs.Clear();
        _railActionSpecs.AddRange(railActions.Select(a => (a.IconKey, a.Hint)));
        _stripActionSpecs.Clear();
        _stripActionSpecs.AddRange(stripActions.Select(a => (a.IconKey, a.Hint)));
        Rebuild();
    }

    /// What the layout has to place on each side.
    public int RailCount => _railButtons.Count;
    public int StripCount => _stripActionSpecs.Count;

    /// Where the chrome is, in this control's client space — the answer the
    /// hit test needs on every mouse event. Read, not recomputed: asking
    /// `OverlayToolbarLayout.Compute` again per event ran the whole candidate
    /// search (two lists, four placements each, eight forbidden rects) for a
    /// rectangle that had not moved since the last Place.
    public (RectangleF Tool, RectangleF Action) ChromeFrames =>
        _chromeVisible ? (_railFrame, _stripFrame) : (RectangleF.Empty, RectangleF.Empty);

    public bool ChromeVisible => _chromeVisible;

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
            if (b.IconKey == "color") b.Tint = color;
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
            selection, screen, RailCount, StripCount,
            Theme.HandleHit * DeviceDpi / 96f, metrics);
        var wasVisible = _chromeVisible;
        var oldRail = _railFrame;
        var oldStrip = _stripFrame;
        if (area is not { } placed)
        {
            _chromeVisible = false;
            _railFrame = Rectangle.Empty;
            _stripFrame = Rectangle.Empty;
            foreach (var b in _railButtons) b.Visible = false;
            foreach (var b in _stripButtons) b.Visible = false;
        }
        else
        {
            _chromeVisible = true;
            _railFrame = Rectangle.Round(placed.ToolFrame);
            _stripFrame = Rectangle.Round(placed.ActionFrame);
            PlaceButtons(_railButtons, placed.ToolButtonFrames);
            PlaceButtons(_stripButtons, placed.ActionButtonFrames);
        }
        if (_railFrame == oldRail && _stripFrame == oldStrip
            && _chromeVisible == wasVisible)
            return;
        // The plates are drawn by THIS control, so a plate that moved leaves
        // its old rectangle showing a plate that is no longer there.
        if (wasVisible) { Invalidate(oldRail); Invalidate(oldStrip); }
        if (_chromeVisible) { Invalidate(_railFrame); Invalidate(_stripFrame); }
    }

    /// Which button is under a point in this control's client space. The
    /// buttons' own `Bounds` are already in it, so this is arithmetic —
    /// the round trip through `RectangleToScreen`/`RectangleToClient` it
    /// replaced was two `MapWindowPoints` calls per button, on every move of
    /// the mouse anywhere on the desktop.
    string? HintAt(Point pt)
    {
        if (!_chromeVisible) return null;
        foreach (var b in _railButtons)
            if (b.Bounds.Contains(pt)) return b.Hint;
        foreach (var b in _stripButtons)
            if (b.Bounds.Contains(pt)) return b.Hint;
        return null;
    }

    void Rebuild()
    {
        foreach (var b in _railButtons.Concat(_stripButtons)) b.Dispose();
        _toolButtons.Clear();
        _actionButtons.Clear();
        _railButtons.Clear();
        _stripButtons.Clear();
        Controls.Clear();

        foreach (var (key, hint) in _toolSpecs)
        {
            var btn = Make(key, hint, isTool: true);
            Controls.Add(btn);
            _toolButtons.Add(btn);
            _railButtons.Add(btn);
        }
        foreach (var (key, hint) in _railActionSpecs)
        {
            var btn = Make(key, hint, isTool: false);
            Controls.Add(btn);
            _actionButtons.Add(btn);
            _railButtons.Add(btn);
        }
        foreach (var (key, hint) in _stripActionSpecs)
        {
            var btn = Make(key, hint, isTool: false);
            Controls.Add(btn);
            _actionButtons.Add(btn);
            _stripButtons.Add(btn);
        }
        SetActive(_active);
        if (_havePlace) Place(_lastSelection, _lastScreen);
    }

    OverlayButton Make(string key, string hint, bool isTool)
    {
        var btn = new OverlayButton(key, hint);
        if (key == "color") btn.Tint = _color;
        btn.Click += (_, _) => OnButton(btn, isTool);
        return btn;
    }

    /// Opens the preset menu from the Backdrop button, as a click would.
    /// The D key routes here rather than synthesising a click, so the menu
    /// appears under the button either way.
    public void OpenBackdropMenu()
    {
        var btn = _actionButtons.FirstOrDefault(b => b.IconKey == "backdrop");
        if (btn == null) return;
        _hint.HideNow();
        _menu.Show(btn.PointToScreen(new Point(0, btn.Height)));
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

    /// <paramref name="frames"/> are already in this control's client space —
    /// the buttons are its direct children now, not a panel's.
    static void PlaceButtons(List<OverlayButton> buttons, RectangleF[] frames)
    {
        int n = Math.Min(buttons.Count, frames.Length);
        for (int i = 0; i < n; i++)
        {
            buttons[i].Bounds = Rectangle.Round(frames[i]);
            buttons[i].Visible = true;
        }
        for (int i = n; i < buttons.Count; i++) buttons[i].Visible = false;
    }

    // ---------- painting ----------

    /// Nothing: this control is Opaque and writes every pixel in OnPaint.
    /// Left overridden rather than left out, because the base would otherwise
    /// fill with a colour on the WM_PRINT path that `DrawToBitmap` uses.
    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var clip = Rectangle.Intersect(e.ClipRectangle, ClientRectangle);
        if (clip.Width <= 0 || clip.Height <= 0) return;
        var buffer = Buffer(clip.Size);
        if (buffer is null)
        {
            // No buffer to be had: a torn frame beats a blank one.
            PaintInto(e.Graphics, clip);
            return;
        }
        using (var back = Graphics.FromImage(buffer))
        {
            back.TranslateTransform(-clip.X, -clip.Y);
            // Set AFTER the transform: SetClip takes world coordinates, and
            // the world here is the surface's, not the buffer's.
            back.SetClip(clip);
            PaintInto(back, clip);
        }
        e.Graphics.DrawImage(
            buffer, clip, new Rectangle(Point.Empty, clip.Size), GraphicsUnit.Pixel);
    }

    void PaintInto(Graphics g, Rectangle clip)
    {
        // An opaque ground first, always. The buffer starts fully transparent
        // and the screen DC it stands in for has no alpha channel at all, so a
        // frozen capture whose alpha bytes came back as zero would composite to
        // the desktop against one and to nothing against the other. Ground it
        // and the two are the same picture.
        using (var ground = new SolidBrush(BackColor))
            g.FillRectangle(ground, clip);
        if (PaintSurface is { } paint)
        {
            // The host's painter sets its own clip and transform for the marks
            // it draws. Bracketing it is what keeps the plates below in THIS
            // control's coordinates whatever it leaves behind.
            var state = g.Save();
            paint(g, clip);
            g.Restore(state);
        }
        if (!_chromeVisible) return;
        // The buttons are child windows and are clipped out of this paint, so
        // what lands here is the plate showing between and around them.
        if (clip.IntersectsWith(_railFrame))
            OverlayChrome.PaintPlate(g, _railFrame, DeviceDpi);
        if (clip.IntersectsWith(_stripFrame))
            OverlayChrome.PaintPlate(g, _stripFrame, DeviceDpi);
    }

    Bitmap? Buffer(Size need)
    {
        if (_buffer is not null
            && _buffer.Width >= need.Width && _buffer.Height >= need.Height)
            return _buffer;
        int width = Math.Max(need.Width, _buffer?.Width ?? 0);
        int height = Math.Max(need.Height, _buffer?.Height ?? 0);
        _buffer?.Dispose();
        _buffer = null;
        try
        {
            // Premultiplied: GDI+ blits PArgb through its fast opaque path,
            // the same reason the captures use it.
            _buffer = new Bitmap(width, height, PixelFormat.Format32bppPArgb);
        }
        catch (Exception ex)
        {
            Diag.Crash("overlay-buffer", ex);
        }
        return _buffer;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hint.Dispose();
            _menu.Dispose();
            _buffer?.Dispose();
            _buffer = null;
        }
        base.Dispose(disposing);
    }

    sealed class OverlayButton : Control
    {
        public string IconKey { get; }
        public string Hint { get; }

        Color? _tint;
        bool _checked;
        bool _hover;
        bool _press;

        /// Each of these repaints ONLY when it changes. Invalidating on every
        /// enter, move and release is how a button that looks identical
        /// before and after still flickers.
        public Color? Tint
        {
            get => _tint;
            set { if (_tint != value) { _tint = value; Invalidate(); } }
        }

        public bool Checked
        {
            get => _checked;
            set { if (_checked != value) { _checked = value; Invalidate(); } }
        }

        public OverlayButton(string key, string hint)
        {
            IconKey = key;
            Hint = hint;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
                | ControlStyles.Opaque, true);
            // Chrome does not take the keyboard: focus belongs to the surface,
            // whose ProcessCmdKey routes every tool letter.
            SetStyle(ControlStyles.Selectable, false);
            // Named, not inherited. A child of a Color.Transparent parent that
            // does not itself support transparency gets SystemColors.Control
            // from WinForms — the near-white every overlay button wore.
            BackColor = OverlayChrome.Plate;
            TabStop = false;
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            if (!_hover) { _hover = true; Invalidate(); }
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            if (_hover || _press) { _hover = false; _press = false; Invalidate(); }
            base.OnMouseLeave(e);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (!_press) { _press = true; Invalidate(); }
            base.OnMouseDown(e);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (_press) { _press = false; Invalidate(); }
            base.OnMouseUp(e);
        }

        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e) =>
            OverlayChrome.PaintButton(
                e.Graphics, ClientRectangle, IconKey, DeviceDpi,
                hover: _hover, pressed: _press, isChecked: _checked,
                enabled: Enabled, tint: _tint);
    }
}
