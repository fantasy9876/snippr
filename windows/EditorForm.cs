using System.Drawing.Drawing2D;

namespace Snippr;

sealed class EditorForm : Form
{
    Bitmap _image;
    Bitmap? _pixelated;
    readonly List<Annotation> _annotations = new();
    /// One timeline for everything the user can undo — the marks AND the
    /// backdrop preset. macOS proved a second stack for the frame walks the
    /// two histories in an order nobody performed: mark, preset, mark must
    /// undo as mark, preset, mark.
    readonly Timeline<EditorState> _history = new();
    BackdropPreset _backdrop = BackdropPreset.None;

    Tool _tool = Tool.Select;
    Color _color = Color.Red;
    float _zoom = 1f;

    Annotation? _draft;
    Annotation? _selected;
    Point _dragStartPx;
    bool _movingSelection;
    Rectangle? _cropRectPx;

    readonly Panel _scroller = new();
    readonly CanvasControl _canvas;
    readonly Panel _chrome = new();
    readonly ToolStrip _actionBar = new();
    readonly ToolStrip _toolBar = new();
    ToolStripLabel _sizeLabel = new();
    ToolStripLabel _zoomLabel = new();
    ToolStripLabel _widthLabel = new();
    ToolStripButton _colorButton = new();
    readonly Dictionary<Tool, ToolStripButton> _toolButtons = new();
    HoverHint? _actionHint;
    HoverHint? _toolHint;
    /// A transparent stand-in that gives every button an image box of the
    /// right SIZE; the renderer paints the real vector on top. It has to be
    /// scaled too, or the icon area stays 20px while the button grows.
    static readonly Dictionary<int, Bitmap> IconSlots = new();

    static Bitmap SlotFor(int size)
    {
        if (IconSlots.TryGetValue(size, out var slot)) return slot;
        slot = new Bitmap(Math.Max(1, size), Math.Max(1, size));
        IconSlots[size] = slot;
        return slot;
    }
    TextBox? _textBox;
    TextAnnotation? _editingText;

    /// Builds an editor without showing it, for the headless smoke entry.
    internal static EditorForm CreateForTesting(Bitmap image) => new(image);

    /// Runs exactly what the toolbar button for this action runs.
    internal void PressForTesting(OverlayAction action) => Run(action);

    /// The picture a terminal route would hand over, without handing it over:
    /// pressing Copy for real closes the editor and reaches for a clipboard a
    /// runner does not have.
    internal Bitmap RouteImageForTesting(OverlayAction action) => ForRoute(action);

    /// Dismisses anything the last press opened, so the next step is not
    /// waiting behind a menu.
    internal void CloseMenusForTesting() => _backdropMenu.Close();

    public static void OpenWith(Bitmap image)
    {
        var f = new EditorForm(image);
        f.Show();
        f.Activate();
    }

    /// Builds an editor (never shown) so WinForms, GDI+ and the toolbar are
    /// warm before the first capture — the first open is otherwise noticeably
    /// slower than the rest.
    internal static void Prewarm()
    {
        try
        {
            var f = new EditorForm(new Bitmap(8, 8));
            _ = f.Handle; // force handle + control creation
            f.Dispose();
        }
        catch { /* warming is best-effort */ }
    }

    EditorForm(Bitmap image)
    {
        _image = image;
        try { _color = ColorTranslator.FromHtml(AppSettings.Current.LastColor); } catch { }
        Text = "Snippr";
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Theme.Window;
        KeyPreview = true;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(
            Theme.Px(Theme.EditorMinW, DeviceDpi),
            Theme.Px(Theme.EditorChromeH + Theme.EditorMinViewportH, DeviceDpi));

        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        ClientSize = new Size(
            Math.Min(
                Math.Max(image.Width, Theme.Px(Theme.EditorMinW, DeviceDpi)),
                (int)(wa.Width * 0.9)),
            Math.Min(image.Height, (int)(wa.Height * 0.85))
                + Theme.Px(Theme.EditorChromeH, DeviceDpi));

        _canvas = new CanvasControl(this);
        BuildToolbar();

        _scroller.Dock = DockStyle.Fill;
        _scroller.AutoScroll = true;
        _scroller.BackColor = Theme.Canvas;
        _scroller.Controls.Add(_canvas);
        Controls.Add(_scroller);
        Controls.Add(_chrome);
        _previewTimer.Tick += (_, _) => { _previewTimer.Stop(); _canvas.Invalidate(); };
        _scroller.Resize += (_, _) => CenterCanvas();
        _scroller.Paint += DrawBackdropAround;
        // Scrolling a panel BLITS what it already has and repaints only the
        // strip that came into view, so a frame drawn on the panel would smear
        // behind the document instead of travelling with it.
        _scroller.Scroll += (_, _) => _scroller.Invalidate();

        ApplyZoom(1f);
        // Disposed (not FormClosed) so the prewarm instance — which is
        // disposed without ever being shown — cleans up the same way.
        Disposed += (_, _) => DisposeBitmaps();
    }

    /// The shot, the pixelate/scale caches, and every bitmap held by the
    /// undo/redo stacks are unmanaged GDI+ memory; leaving them to finalizers
    /// used to leak ~100 MB per editing session while the app idled in tray.
    void DisposeBitmaps()
    {
        _previewTimer.Dispose();
        _pixelated?.Dispose();
        _pixelated = null;
        InvalidateScaledCache();
        var seen = new HashSet<Bitmap>(ReferenceEqualityComparer.Instance) { _image };
        // Teardown releases everything, including the bitmap still on screen,
        // so the collector here is deliberately wider than the fork handler.
        _history.Discarding = dropped =>
        {
            foreach (var state in dropped) seen.Add(state.Image);
        };
        _history.Clear();
        foreach (var bmp in seen) bmp.Dispose();
    }

    // ---------- toolbar ----------

    void BuildToolbar()
    {
        // Real pixels for this display, not device-independent units used as
        // if they were pixels.
        var metrics = EditorChromeMetrics.For(
            DeviceDpi,
            ToolCatalog.EditorActions.Count() + 4, // + separator and three labels
            ToolCatalog.EditorTools.Count());
        _chrome.Dock = DockStyle.Top;
        _chrome.Height = metrics.ChromeHeight;
        _chrome.BackColor = Theme.Chrome;
        _chrome.Padding = Padding.Empty;

        StyleStrip(_actionBar);
        StyleStrip(_toolBar);
        _actionBar.Dock = DockStyle.Top;
        _toolBar.Dock = DockStyle.Fill;

        ToolStripButton IconBtn(ToolStrip strip, string key, string tip, EventHandler onClick)
        {
            var b = new ToolStripButton
            {
                DisplayStyle = ToolStripItemDisplayStyle.Image,
                Image = SlotFor(metrics.IconSize),
                ImageScaling = ToolStripItemImageScaling.None,
                AutoSize = false,
                Size = new Size(metrics.ButtonWidth, metrics.ButtonHeight),
                Margin = new Padding(
                    metrics.Spacing, Theme.Px(3, DeviceDpi),
                    metrics.Spacing, Theme.Px(3, DeviceDpi)),
                Padding = Padding.Empty,
                ToolTipText = tip,
                Tag = new IconRef(key),
            };
            b.Click += onClick;
            strip.Items.Add(b);
            return b;
        }

        // The action row comes from the catalog too. A hand-written list here
        // is how the editor ended up advertising a Backdrop button in the
        // table and not having one on screen — the tool row was built from the
        // table and this one was not, so nothing could tell them apart.
        foreach (var entry in ToolCatalog.EditorActions)
        {
            var action = entry.Action;
            var button = IconBtn(
                _actionBar, entry.IconKey, entry.HintText, (_, _) => Run(action));
            if (action == OverlayAction.Color) _colorButton = button;
            if (action == OverlayAction.Backdrop) _backdropButton = button;
        }
        _actionBar.Items.Add(new ToolStripSeparator { AutoSize = false, Size = new Size(8, 18) });
        UpdateColorSwatch();

        _widthLabel = new ToolStripLabel("")
        {
            ForeColor = Theme.IconMuted,
            Font = Theme.ChromeFont,
            ToolTipText = "Stroke width — scroll on the image",
        };
        _actionBar.Items.Add(_widthLabel);
        UpdateWidthLabel();

        _zoomLabel = new ToolStripLabel("100%")
        {
            Alignment = ToolStripItemAlignment.Right,
            ForeColor = Theme.IconMuted,
            Font = Theme.ChromeFont,
        };
        _sizeLabel = new ToolStripLabel("")
        {
            Alignment = ToolStripItemAlignment.Right,
            ForeColor = Theme.IconMuted,
            Font = Theme.ChromeFont,
        };
        _actionBar.Items.Add(_zoomLabel);
        _actionBar.Items.Add(_sizeLabel);

        // Which buttons exist, in which order, with which icon and which text:
        // all of it from the catalog. A second list here is how a toolbar ends
        // up advertising a key its host does not route, or missing a tool the
        // review surface has — and it is where Spotlight and Magnifier would
        // have gone missing.
        foreach (var entry in ToolCatalog.EditorTools)
        {
            var tool = entry.Tool;
            _toolButtons[tool] = IconBtn(
                _toolBar, entry.IconKey, entry.HintText, (_, _) => SelectTool(tool));
        }

        // Last-docked Top wins the top edge: add tools first, then actions.
        _chrome.Controls.Add(_toolBar);
        _chrome.Controls.Add(_actionBar);
        _actionBar.Height = metrics.RowHeight;
        _toolBar.Height = metrics.RowHeight;
        // A window narrow enough to hide a button is a window that must not
        // exist: with overflow off an item that does not fit is not moved
        // anywhere, it is simply gone.
        MinimumSize = new Size(
            Math.Max(MinimumSize.Width, metrics.MinimumWindowWidth),
            Math.Max(
                MinimumSize.Height,
                metrics.ChromeHeight + Theme.Px(Theme.EditorMinViewportH, DeviceDpi)));

        _actionBar.Name = "actions";
        _toolBar.Name = "tools";
        // Measured AFTER layout, so the log carries what the user is actually
        // looking at rather than what the constants asked for.
        _chrome.Layout += (_, _) => Diag.Chrome("editor", _chrome, _actionBar, _toolBar);
        _actionHint = HoverHint.Attach(_actionBar, pt => _actionBar.GetItemAt(pt)?.ToolTipText);
        _toolHint = HoverHint.Attach(_toolBar, pt => _toolBar.GetItemAt(pt)?.ToolTipText);

        _backdropMenu.CornerChosen += (_, style) =>
        {
            AppSettings.Current.BackdropCorners = style.ToString();
            AppSettings.Current.Save();
            // The plate's corners do not change its SIZE, so a repaint is
            // enough here — unlike choosing a preset.
            _canvas.Invalidate();
        };
        _backdropMenu.PresetChosen += (_, id) =>
        {
            if (Enum.TryParse<BackdropPreset>(id, ignoreCase: true, out var preset)
                && ApplyBackdrop(preset))
            {
                // The frame changes the SIZE of what is on screen, so the
                // layout has to be redone, not just repainted.
                ApplyZoom(_zoom);
            }
        };

        SelectTool(Tool.Select);
        RefreshLabels();
    }

    static void StyleStrip(ToolStrip strip)
    {
        strip.GripStyle = ToolStripGripStyle.Hidden;
        strip.BackColor = Theme.Chrome;
        strip.ForeColor = Theme.Icon;
        strip.Renderer = new ToolbarRenderer();
        strip.Font = Theme.ChromeFont;
        strip.ImageScalingSize = new Size((int)Theme.EditorIcon, (int)Theme.EditorIcon);
        strip.Padding = new Padding((int)Theme.Pad, 0, (int)Theme.Pad, 0);
        strip.AutoSize = false;
        strip.ShowItemToolTips = false;
        // Overflow ON. It is the ugly answer, and it is still better than the
        // alternative this build shipped with: an item that does not fit is
        // not moved anywhere, it is not drawn at all, and the user is left
        // with a toolbar that silently lost half its buttons.
        strip.CanOverflow = true;
    }

    void UpdateColorSwatch()
    {
        _colorButton.Tag = new IconRef("color", _color);
        _colorButton.Invalidate();
    }

    void PickColor()
    {
        _actionHint?.HideNow();
        using var dlg = new ColorDialog { Color = _color, FullOpen = true };
        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            _color = dlg.Color;
            AppSettings.Current.LastColor = ColorTranslator.ToHtml(_color);
            AppSettings.Current.Save();
            UpdateColorSwatch();
            if (_selected != null)
            {
                PushUndo();
                _selected.Color = _color;
                _canvas.Invalidate();
            }
        }
    }

    // Semantic routes by the shared table: the recognizer reads the document,
    // never the frame around it.
    void RunOcr() => TextResultForm.RunOcrFlow(ForRoute(OverlayAction.Ocr));
    void RunTranslate() =>
        TextResultForm.RunOcrFlow(ForRoute(OverlayAction.Translate), autoTranslate: true);

    /// One freeze, two readings — which one an action gets is not decided
    /// here, it is looked up, so the editor and the review surface cannot
    /// drift apart on it.
    internal Bitmap ForRoute(OverlayAction action) =>
        RouteDecoration.UsesDecoration(action) ? Composed() : Flatten();

    static bool IsStrokeTool(Tool t) =>
        t is Tool.Arrow or Tool.Line or Tool.Rect or Tool.Oval or Tool.Pen;

    static bool IsStrokeAnnotation(Annotation a) =>
        a is PenAnnotation ||
        (a is ShapeAnnotation s && s.Shape != ShapeAnnotation.Kind.Highlight);

    internal bool CanAdjustStroke =>
        _selected != null ? IsStrokeAnnotation(_selected) : IsStrokeTool(_tool);

    static string ToolKeyFor(Annotation a) => a is ShapeAnnotation s
        ? s.Shape switch
        {
            ShapeAnnotation.Kind.Arrow => nameof(Tool.Arrow),
            ShapeAnnotation.Kind.Line => nameof(Tool.Line),
            ShapeAnnotation.Kind.Rect => nameof(Tool.Rect),
            ShapeAnnotation.Kind.Oval => nameof(Tool.Oval),
            _ => nameof(Tool.Highlight),
        }
        : nameof(Tool.Pen);

    float _previewWidth;
    Color _previewColor;
    DateTime _previewUntil = DateTime.MinValue;
    readonly System.Windows.Forms.Timer _previewTimer = new() { Interval = 1100 };

    internal void AdjustStrokeWidth(float step)
    {
        float width;
        Color color;
        if (_selected != null && IsStrokeAnnotation(_selected))
        {
            _selected.Width = Math.Clamp(_selected.Width + step, 1, 20);
            AppSettings.Current.SetToolWidth(ToolKeyFor(_selected), _selected.Width);
            width = _selected.Width;
            color = _selected.Color;
        }
        else
        {
            width = Math.Clamp(AppSettings.Current.GetToolWidth(_tool.ToString()) + step, 1, 20);
            AppSettings.Current.SetToolWidth(_tool.ToString(), width);
            color = _color;
        }
        _previewWidth = width;
        _previewColor = color;
        _previewUntil = DateTime.Now.AddSeconds(1);
        _previewTimer.Stop();
        _previewTimer.Start();
        UpdateWidthLabel();
        _canvas.Invalidate();
    }

    /// HUD sample: a line drawn at the actual width & color plus the number.
    internal void DrawStrokePreview(Graphics g)
    {
        if (DateTime.Now >= _previewUntil) return;
        int w = 200, h = 46;
        int x = -_canvas.Location.X + (_scroller.ClientSize.Width - w) / 2;
        int y = -_canvas.Location.Y + 16;
        using var bg = new SolidBrush(Color.FromArgb(210, 15, 17, 22));
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.FillRectangle(bg, x, y, w, h);
        using var pen = new Pen(_previewColor, _previewWidth)
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round,
        };
        g.DrawLine(pen, x + 16, y + h / 2, x + w - 70, y + h / 2);
        using var f = new Font("Segoe UI", 10f, FontStyle.Bold);
        g.DrawString($"{_previewWidth:0.#}", f, Brushes.White, x + w - 56, y + h / 2 - 10);
    }

    void UpdateWidthLabel()
    {
        _widthLabel.Text = $"{AppSettings.Current.GetToolWidth(_tool.ToString()):0.0} pt";
    }

    void SelectTool(Tool tool)
    {
        Diag.Click("editor", $"tool={tool}");
        CommitText();
        _tool = tool;
        foreach (var (t, b) in _toolButtons) b.Checked = t == tool;
        _actionHint?.HideNow();
        _toolHint?.HideNow();
        UpdateWidthLabel();
        _canvas.Cursor = tool switch
        {
            Tool.Select => Cursors.Default,
            Tool.Text => Cursors.IBeam,
            _ => Cursors.Cross,
        };
    }

    ToolStripButton? _backdropButton;
    readonly BackdropMenu _backdropMenu = new();

    /// One entry for every toolbar action, so what the catalog offers and what
    /// the editor does cannot drift apart.
    void Run(OverlayAction action)
    {
        Diag.Click("editor", $"action={action} tool={_tool} backdrop={_backdrop}");
        switch (action)
        {
            case OverlayAction.Backdrop:
                if (_backdropButton != null)
                    _backdropMenu.Show(
                        _actionBar,
                        new Point(
                            _backdropButton.Bounds.Left,
                            _backdropButton.Bounds.Bottom));
                break;
            case OverlayAction.Color: PickColor(); break;
            case OverlayAction.Undo: Undo(); break;
            case OverlayAction.Redo: Redo(); break;
            case OverlayAction.Copy: CopyAndClose(); break;
            case OverlayAction.Save: SaveWithDialog(); break;
            case OverlayAction.Pin: PinAndClose(); break;
            case OverlayAction.Ocr: RunOcr(); break;
            case OverlayAction.Translate: RunTranslate(); break;
            case OverlayAction.Close: Close(); break;
        }
    }

    void RefreshLabels()
    {
        // What the badge promises is what the export writes: with a frame on,
        // that is the OUTER picture, not the document inside it.
        var exported = BackdropSpec.OuterDimensions(
            _image.Width, _image.Height, _backdrop)
            ?? new Size(_image.Width, _image.Height);
        _sizeLabel.Text = $"{exported.Width}×{exported.Height}px";
        _zoomLabel.Text = $"{(int)Math.Round(_zoom * 100)}%  ";
    }

    // ---------- zoom ----------

    /// The frame's padding, in the view's own units.
    float PadView => _backdrop == BackdropPreset.None
        ? 0
        : new BackdropLayout(
            new Size(_image.Width, _image.Height), 1, _backdrop).Pad * _zoom;

    internal void ApplyZoom(float zoom)
    {
        _zoom = Math.Clamp(zoom, 0.1f, 8f);
        _canvas.Size = new Size(
            (int)(_image.Width * _zoom), (int)(_image.Height * _zoom));
        // What can be scrolled to is the whole picture, frame included. A
        // panel derives its scrollable extent from where its CHILDREN end, and
        // the frame is not a child — so without this the right and bottom
        // padding simply could not be reached on any capture bigger than the
        // window, which is most of them.
        var pad = (int)Math.Round(PadView);
        _scroller.AutoScrollMinSize = new Size(
            _canvas.Width + pad * 2, _canvas.Height + pad * 2);
        CenterCanvas();
        _canvas.Invalidate();
        _scroller.Invalidate();
        RefreshLabels();
    }

    /// Keeps the shot centered when it's smaller than the viewport.
    void CenterCanvas()
    {
        // What is centred is the whole PICTURE — the document and the frame
        // around it — so the padding is reserved rather than drawn over the
        // neighbouring chrome.
        var pad = (int)Math.Round(PadView);
        var vp = _scroller.ClientSize;
        int x = Math.Max(0, (vp.Width - (_canvas.Width + pad * 2)) / 2) + pad;
        int y = Math.Max(0, (vp.Height - (_canvas.Height + pad * 2)) / 2) + pad;
        var scroll = _scroller.AutoScrollPosition;
        _canvas.Location = new Point(x + scroll.X, y + scroll.Y);
    }

    /// The frame is drawn AROUND the canvas, by the view that owns the space
    /// around it — the same division the macOS build settled on, and the
    /// reason the document's own coordinates stay exactly what they were.
    void DrawBackdropAround(object? sender, PaintEventArgs e)
    {
        if (_backdrop == BackdropPreset.None) return;
        BackdropRender.DrawFrameForPreview(
            e.Graphics, _canvas.Bounds, _zoom, _backdrop,
            AppSettings.Current.CornerStyle);
    }

    internal void ZoomBy(float factor) => ApplyZoom(_zoom * factor);

    // ---------- undo ----------

    EditorState Snapshot() => new(
        _image, _annotations.Select(a => a.Clone()).ToList(), _backdrop);

    void PushUndo()
    {
        _history.Discarding ??= dropped =>
        {
            // States that just left the timeline for good. A bitmap in one of
            // them may still be the canvas' own, or still be reachable from
            // the other stack, so only the unreachable ones are released.
            var live = new HashSet<Bitmap>(ReferenceEqualityComparer.Instance) { _image };
            foreach (var state in dropped)
                if (!live.Contains(state.Image)) state.Image.Dispose();
        };
        _history.Push(Snapshot());
    }

    void Undo()
    {
        if (_history.TryUndo(Snapshot(), out var previous)) Restore(previous);
    }

    void Redo()
    {
        if (_history.TryRedo(Snapshot(), out var next)) Restore(next);
    }

    void Restore(EditorState state)
    {
        if (!ReferenceEquals(state.Image, _image))
        {
            _image = state.Image;
            _pixelated?.Dispose();
            _pixelated = null;
            InvalidateScaledCache();
        }
        _annotations.Clear();
        _annotations.AddRange(state.Annotations);
        _backdrop = state.Backdrop;
        _selected = null;
        ApplyZoom(_zoom);
    }

    /// Choosing a preset is ONE undo step, and choosing the one already in use
    /// is no step at all — a no-op that forked the redo branch would throw away
    /// a future the user never left.
    internal bool ApplyBackdrop(BackdropPreset preset)
    {
        if (preset == _backdrop) return false;
        PushUndo();
        _backdrop = preset;
        RefreshLabels();
        CenterCanvas();
        _scroller.Invalidate();
        _canvas.Invalidate();
        return true;
    }

    internal BackdropPreset BackdropPresetForTesting => _backdrop;

    // ---------- actions ----------

    /// The DOCUMENT: the crop the user selected with their marks on it, and
    /// no decoration. This is what the recognizer reads — a frame adds no text
    /// and would shift every box it finds off the source.
    internal Bitmap Flatten()
    {
        CommitText();
        bool needsPix = _annotations.Any(a => a is BlurAnnotation);
        return AnnotationRenderer.Flatten(_image, _annotations, needsPix ? Pixelated : null);
    }

    /// The PICTURE: the document inside its frame. Everything that produces an
    /// image for the user — Copy, Save, Pin — sends this, so what they get is
    /// what they were reviewing.
    internal Bitmap Composed()
    {
        var inner = Flatten();
        if (_backdrop == BackdropPreset.None) return inner;
        var composed = BackdropRender.Compose(
            inner, _backdrop, corners: AppSettings.Current.CornerStyle);
        if (composed == null || ReferenceEquals(composed, inner)) return inner;
        inner.Dispose();
        return composed;
    }

    Bitmap Pixelated => _pixelated ??= AnnotationRenderer.Pixelate(_image);

    Bitmap? _scaledCache;
    float _scaledCacheZoom = -1;

    /// Pre-scaled copy of the shot for painting: rescaling a multi-megapixel
    /// bitmap on every paint made scrolling and drawing feel sluggish, so it
    /// is done once per zoom level and then blitted.
    internal Bitmap ScaledImage
    {
        get
        {
            if (_scaledCache != null && Math.Abs(_scaledCacheZoom - _zoom) < 0.0005f)
                return _scaledCache;

            int w = Math.Max(1, (int)(_image.Width * _zoom));
            int h = Math.Max(1, (int)(_image.Height * _zoom));
            var scaled = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(scaled))
            {
                g.InterpolationMode = _zoom < 1
                    ? InterpolationMode.HighQualityBicubic
                    : InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(_image, new Rectangle(0, 0, w, h));
            }
            _scaledCache?.Dispose();
            _scaledCache = scaled;
            _scaledCacheZoom = _zoom;
            return scaled;
        }
    }

    void InvalidateScaledCache()
    {
        _scaledCache?.Dispose();
        _scaledCache = null;
        _scaledCacheZoom = -1;
    }

    void CopyAndClose()
    {
        using var flat = ForRoute(OverlayAction.Copy);
        // Clipboard.SetImage throws when another process holds the clipboard
        // (clipboard managers, RDP) — don't lose the shot behind a crash dialog
        try
        {
            Clipboard.SetImage(flat);
        }
        catch
        {
            ToastForm.Show("Clipboard đang bận — thử lại sau giây lát");
            return; // keep the editor open so the shot isn't lost
        }
        ToastForm.Show("Copied to clipboard");
        Close();
    }

    void SaveWithDialog()
    {
        using var flat = ForRoute(OverlayAction.Save);
        using var dlg = new SaveFileDialog
        {
            Filter = "PNG image|*.png|JPEG image|*.jpg",
            FileName = $"Snippr {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}.png",
            InitialDirectory = AppSettings.Current.SaveFolder,
        };
        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            bool jpeg = Path.GetExtension(dlg.FileName).ToLowerInvariant() is ".jpg" or ".jpeg";
            CaptureUtil.SaveAs(flat, dlg.FileName, jpeg);
            ToastForm.Show($"Saved {Path.GetFileName(dlg.FileName)}");
        }
    }

    void PinAndClose()
    {
        new PinForm(ForRoute(OverlayAction.Pin)).Show();
        Close();
    }

    // ---------- keyboard ----------

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_textBox != null && _textBox.Focused)
        {
            if (keyData == Keys.Escape) { CancelText(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        switch (keyData)
        {
            case Keys.Control | Keys.C: CopyAndClose(); return true;
            case Keys.Control | Keys.S: SaveWithDialog(); return true;
            case Keys.Control | Keys.P: PinAndClose(); return true;
            case Keys.Control | Keys.Z: Undo(); return true;
            case Keys.Control | Keys.Y:
            case Keys.Control | Keys.Shift | Keys.Z: Redo(); return true;
            case Keys.Control | Keys.D0: ApplyZoom(1f); return true;
            case Keys.Control | Keys.Oemplus: ZoomBy(1.25f); return true;
            case Keys.Control | Keys.OemMinus: ZoomBy(0.8f); return true;
            case Keys.Escape:
                // mirrors the macOS escCopy setting; turning it off makes Esc
                // a plain discard that leaves the clipboard alone
                if (AppSettings.Current.EscCopy) CopyAndClose(); else Close();
                return true;
            case Keys.Delete:
            case Keys.Back:
                if (_selected != null)
                {
                    PushUndo();
                    _annotations.Remove(_selected);
                    _selected = null;
                    _canvas.Invalidate();
                }
                return true;
            case Keys.V: SelectTool(Tool.Select); return true;
            case Keys.A: SelectTool(Tool.Arrow); return true;
            case Keys.L: SelectTool(Tool.Line); return true;
            case Keys.R: SelectTool(Tool.Rect); return true;
            case Keys.O: SelectTool(Tool.Oval); return true;
            case Keys.H: SelectTool(Tool.Highlight); return true;
            case Keys.P: SelectTool(Tool.Pen); return true;
            case Keys.T: SelectTool(Tool.Text); return true;
            case Keys.N: SelectTool(Tool.Counter); return true;
            case Keys.B: SelectTool(Tool.Blur); return true;
            case Keys.S: SelectTool(Tool.Spotlight); return true;
            case Keys.M: SelectTool(Tool.Magnifier); return true;
            case Keys.C: SelectTool(Tool.Crop); return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    // ---------- canvas events (called by CanvasControl) ----------

    Point ToPx(Point view) => new((int)(view.X / _zoom), (int)(view.Y / _zoom));

    internal void CanvasMouseDown(MouseEventArgs e)
    {
        CommitText();
        var px = ToPx(e.Location);
        _dragStartPx = px;

        switch (_tool)
        {
            case Tool.Select:
                _selected = _annotations.AsEnumerable().Reverse().FirstOrDefault(a => a.HitTest(px));
                _movingSelection = _selected != null;
                if (_movingSelection) PushUndo();
                _canvas.Invalidate();
                break;
            case Tool.Arrow or Tool.Line or Tool.Rect or Tool.Oval or Tool.Highlight:
                _draft = new ShapeAnnotation
                {
                    Shape = _tool switch
                    {
                        Tool.Arrow => ShapeAnnotation.Kind.Arrow,
                        Tool.Line => ShapeAnnotation.Kind.Line,
                        Tool.Rect => ShapeAnnotation.Kind.Rect,
                        Tool.Oval => ShapeAnnotation.Kind.Oval,
                        _ => ShapeAnnotation.Kind.Highlight,
                    },
                    Start = px,
                    End = px,
                    Color = _tool == Tool.Highlight && _color.ToArgb() == Color.Red.ToArgb()
                        ? Color.Gold : _color,
                    Width = AppSettings.Current.GetToolWidth(_tool.ToString()),
                };
                break;
            case Tool.Pen:
                _draft = new PenAnnotation
                {
                    Color = _color,
                    Width = AppSettings.Current.GetToolWidth(_tool.ToString()),
                    Points = { px },
                };
                break;
            case Tool.Blur:
                _draft = new BlurAnnotation { Rect = new Rectangle(px, Size.Empty) };
                break;
            case Tool.Spotlight:
                _draft = new SpotlightAnnotation
                {
                    Rect = new Rectangle(px, Size.Empty),
                    BaseBounds = new Rectangle(0, 0, _image.Width, _image.Height),
                };
                break;
            case Tool.Magnifier:
                // The drag picks the SOURCE. Where the callout ends up is
                // decided on release, and moved afterwards by dragging it —
                // re-aiming a callout would show pixels the user never chose.
                _draft = new MagnifierAnnotation
                {
                    SourceRect = new Rectangle(px, Size.Empty),
                    CalloutRect = new Rectangle(px, Size.Empty),
                };
                break;
            case Tool.Crop:
                _cropRectPx = new Rectangle(px, Size.Empty);
                break;
            case Tool.Text:
                BeginText(e.Location, px);
                break;
            case Tool.Counter:
                PushUndo();
                _annotations.Add(new CounterAnnotation
                {
                    Center = px,
                    Color = _color,
                    Number = _annotations.OfType<CounterAnnotation>()
                        .Select(c => c.Number).DefaultIfEmpty(0).Max() + 1,
                });
                _canvas.Invalidate();
                break;
        }
    }

    internal void CanvasMouseMove(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        var px = ToPx(e.Location);

        switch (_tool)
        {
            case Tool.Select when _movingSelection && _selected != null:
                _selected.Move(px.X - _dragStartPx.X, px.Y - _dragStartPx.Y);
                _dragStartPx = px;
                _canvas.Invalidate();
                break;
            case Tool.Arrow or Tool.Line or Tool.Rect or Tool.Oval or Tool.Highlight:
                if (_draft is ShapeAnnotation s) { s.End = px; _canvas.Invalidate(); }
                break;
            case Tool.Pen:
                if (_draft is PenAnnotation p) { p.Points.Add(px); _canvas.Invalidate(); }
                break;
            case Tool.Blur:
                if (_draft is BlurAnnotation blur)
                {
                    blur.Rect = RectFrom(_dragStartPx, px);
                    _canvas.Invalidate();
                }
                break;
            case Tool.Spotlight:
                if (_draft is SpotlightAnnotation spot)
                {
                    spot.Rect = RectFrom(_dragStartPx, px);
                    _canvas.Invalidate();
                }
                break;
            case Tool.Magnifier:
                if (_draft is MagnifierAnnotation mag)
                {
                    mag.SourceRect = RectFrom(_dragStartPx, px);
                    // While the drag is live the callout is only an outline,
                    // parked where it will land — not a 1:1 box on the source.
                    mag.CalloutRect = MagnifierAnnotation.PlaceCallout(
                        mag.SourceRect,
                        new Rectangle(0, 0, _image.Width, _image.Height),
                        MagnifierZoom);
                    _canvas.Invalidate();
                }
                break;
            case Tool.Crop:
                _cropRectPx = RectFrom(_dragStartPx, px);
                _canvas.Invalidate();
                break;
        }
    }

    /// Magnification the callout uses when it is first placed.
    const float MagnifierZoom = 2.5f;

    internal void CanvasMouseUp(MouseEventArgs e)
    {
        if (_draft is MagnifierAnnotation pending) FinishMagnifier(pending);
        if (_draft is SpotlightAnnotation lit)
        {
            // Exactly one spotlight: a second one would dim the first one's
            // lit area, which reads as a bug rather than as two lights.
            if (lit.Rect.Width > 2 && lit.Rect.Height > 2)
            {
                PushUndo();
                _annotations.RemoveAll(a => a is SpotlightAnnotation);
                _annotations.Add(lit);
            }
            _draft = null;
            _canvas.Invalidate();
        }
        if (_draft != null)
        {
            var b = _draft.Bounds;
            if (b.Width > 2 || b.Height > 2 || _draft is PenAnnotation)
            {
                PushUndo();
                _annotations.Add(_draft);
            }
            _draft = null;
            _canvas.Invalidate();
        }
        if (_tool == Tool.Crop && _cropRectPx is Rectangle crop)
        {
            _cropRectPx = null;
            if (crop.Width > 4 && crop.Height > 4) PerformCrop(crop);
            _canvas.Invalidate();
        }
        _movingSelection = false;
    }

    /// Samples the chosen source ONCE, after the redactions, and parks the
    /// callout beside it inside the document. A source that cannot be sampled
    /// — too small, or off the image — leaves no annotation at all rather than
    /// an empty loupe.
    void FinishMagnifier(MagnifierAnnotation mag)
    {
        _draft = null;
        var source = Rectangle.Intersect(
            mag.SourceRect, new Rectangle(0, 0, _image.Width, _image.Height));
        if (source.Width <= 4 || source.Height <= 4) { _canvas.Invalidate(); return; }
        mag.SourceRect = source;
        mag.Snapshot = AnnotationCompositor.MagnifierSnapshot(
            _image, source, _annotations.OfType<BlurAnnotation>());
        if (mag.Snapshot == null) { _canvas.Invalidate(); return; }

        // Same PlaceCallout the live drag already used: a callout parked
        // off the document could never be dragged back, and one parked on
        // the source is the overlap 1.2.11 showed the owner.
        mag.CalloutRect = MagnifierAnnotation.PlaceCallout(
            source, new Rectangle(0, 0, _image.Width, _image.Height), MagnifierZoom);
        PushUndo();
        _annotations.Add(mag);
        _canvas.Invalidate();
    }

    static Rectangle RectFrom(Point a, Point b) => Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));

    void PerformCrop(Rectangle cropPx)
    {
        cropPx.Intersect(new Rectangle(Point.Empty, _image.Size));
        if (cropPx.Width < 4 || cropPx.Height < 4) return;
        PushUndo();
        var cropped = _image.Clone(cropPx, _image.PixelFormat);
        _image = cropped;
        _pixelated?.Dispose();
        _pixelated = null;
        InvalidateScaledCache();
        foreach (var a in _annotations)
        {
            switch (a)
            {
                // A crop moves the whole document under the annotation, so a
                // loupe's SOURCE travels with its callout — moving only the
                // callout would leave it pointing at different pixels than the
                // ones the user picked.
                case MagnifierAnnotation mag:
                    mag.TranslateForDocumentChange(-cropPx.X, -cropPx.Y);
                    break;
                // The dimmed area is the document, and the document just
                // changed shape.
                case SpotlightAnnotation spot:
                    spot.Move(-cropPx.X, -cropPx.Y);
                    spot.BaseBounds = new Rectangle(0, 0, cropPx.Width, cropPx.Height);
                    break;
                default:
                    a.Move(-cropPx.X, -cropPx.Y);
                    break;
            }
        }
        _selected = null;
        ApplyZoom(_zoom);
    }

    // ---------- text tool ----------

    void BeginText(Point viewLoc, Point px)
    {
        CommitText();
        _editingText = new TextAnnotation { Origin = px, Color = _color };
        _textBox = new TextBox
        {
            Location = viewLoc,
            Width = 240,
            Font = new Font("Segoe UI", Math.Max(10, 20 * _zoom * 0.75f)),
            ForeColor = _color,
            BackColor = Color.FromArgb(40, 42, 50),
        };
        _textBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; CommitText(); }
        };
        _textBox.LostFocus += (_, _) => CommitText();
        _canvas.Controls.Add(_textBox);
        _textBox.Focus();
    }

    void CommitText()
    {
        if (_textBox == null || _editingText == null) return;
        var text = _textBox.Text.Trim();
        var ann = _editingText;
        var box = _textBox;
        _textBox = null;
        _editingText = null;
        _canvas.Controls.Remove(box);
        box.Dispose();
        if (text.Length > 0)
        {
            PushUndo();
            ann.Text = text;
            _annotations.Add(ann);
        }
        _canvas.Invalidate();
    }

    void CancelText()
    {
        if (_textBox == null) return;
        var box = _textBox;
        _textBox = null;
        _editingText = null;
        _canvas.Controls.Remove(box);
        box.Dispose();
    }

    // ---------- canvas control ----------

    sealed class CanvasControl : Control
    {
        readonly EditorForm _owner;

        public CanvasControl(EditorForm owner)
        {
            _owner = owner;
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            var o = _owner;
            // at 100% (the default) blit the original directly — building the
            // pre-scaled cache there just duplicated the shot's RAM for nothing.
            // Explicit pixel rects avoid any DPI-based rescale ambiguity.
            if (Math.Abs(o._zoom - 1f) < 0.0005f)
                g.DrawImage(o._image, new Rectangle(0, 0, o._image.Width, o._image.Height));
            else
            {
                var scaled = o.ScaledImage;
                g.DrawImage(scaled, new Rectangle(0, 0, scaled.Width, scaled.Height));
            }

            g.SmoothingMode = SmoothingMode.AntiAlias;
            var state = g.Save();
            g.ScaleTransform(o._zoom, o._zoom);
            bool needsPix = o._annotations.Any(a => a is BlurAnnotation) || o._draft is BlurAnnotation;
            var pix = needsPix ? o.Pixelated : null;
            // The SAME entry the export uses, with the SAME question about
            // what will survive: while a crop is being dragged, the pending
            // crop is what the export will contain, so a magnifier whose
            // source has fallen outside it stops being drawn here too.
            var marks = o._draft == null
                ? o._annotations
                : o._annotations.Concat([o._draft]);
            AnnotationCompositor.Draw(
                marks, g, o._image,
                o._cropRectPx ?? new Rectangle(0, 0, o._image.Width, o._image.Height),
                pix);

            // Straight after the document and its marks, and BEFORE any chrome:
            // the same place compose puts it.
            //
            // In DOCUMENT units, because the context is still scaled by the
            // zoom here: passing the canvas' pixel size and the zoom again
            // multiplied both by the zoom a second time, which at anything but
            // 100% drew the line off the edge of the document entirely.
            if (o._backdrop != BackdropPreset.None)
                BackdropRender.DrawPlateHairline(
                    g, new RectangleF(0, 0, o._image.Width, o._image.Height), 1f,
                    AppSettings.Current.CornerStyle);

            if (o._selected != null)
            {
                using var pen = new Pen(Color.DeepSkyBlue, 1.5f / o._zoom) { DashStyle = DashStyle.Dash };
                var b = Rectangle.Inflate(o._selected.Bounds, 5, 5);
                g.DrawRectangle(pen, b);
            }
            g.Restore(state);

            o.DrawStrokePreview(g);

            if (o._cropRectPx is Rectangle crop)
            {
                var view = new Rectangle(
                    (int)(crop.X * o._zoom), (int)(crop.Y * o._zoom),
                    (int)(crop.Width * o._zoom), (int)(crop.Height * o._zoom));
                using var dim = new SolidBrush(Color.FromArgb(110, Color.Black));
                var region = new Region(ClientRectangle);
                region.Exclude(view);
                g.FillRegion(dim, region);
                region.Dispose();
                g.DrawRectangle(Pens.White, view);
            }
        }

        protected override void OnMouseDown(MouseEventArgs e) { Focus(); _owner.CanvasMouseDown(e); }
        protected override void OnMouseMove(MouseEventArgs e) => _owner.CanvasMouseMove(e);
        protected override void OnMouseUp(MouseEventArgs e) => _owner.CanvasMouseUp(e);

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            // Ctrl+scroll zooms; plain scroll adjusts stroke width for
            // stroke-based shapes only — anything else scrolls the view
            if ((Control.ModifierKeys & Keys.Control) != 0)
            {
                _owner.ZoomBy(e.Delta > 0 ? 1.15f : 1 / 1.15f);
                if (e is HandledMouseEventArgs h1) h1.Handled = true;
            }
            else if (_owner.CanAdjustStroke)
            {
                _owner.AdjustStrokeWidth(e.Delta > 0 ? 0.5f : -0.5f);
                if (e is HandledMouseEventArgs h2) h2.Handled = true;
            }
            else
            {
                base.OnMouseWheel(e); // bubbles to the scroll panel
            }
        }
    }
}
