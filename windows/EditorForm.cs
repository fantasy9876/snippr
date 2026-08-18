using System.Drawing.Drawing2D;

namespace Snippr;

sealed class EditorForm : Form
{
    Bitmap _image;
    Bitmap? _pixelated;
    readonly List<Annotation> _annotations = new();
    readonly Stack<(Bitmap img, List<Annotation> anns)> _undo = new();
    readonly Stack<(Bitmap img, List<Annotation> anns)> _redo = new();

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
    static readonly Bitmap IconSlot = new(20, 20);
    TextBox? _textBox;
    TextAnnotation? _editingText;

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
        MinimumSize = new Size((int)Theme.EditorMinW, (int)(Theme.EditorChromeH + Theme.EditorMinViewportH));

        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        ClientSize = new Size(
            Math.Min(Math.Max(image.Width, (int)Theme.EditorMinW), (int)(wa.Width * 0.9)),
            Math.Min(image.Height, (int)(wa.Height * 0.85)) + (int)Theme.EditorChromeH);

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
        foreach (var (img, _) in _undo) seen.Add(img);
        foreach (var (img, _) in _redo) seen.Add(img);
        _undo.Clear();
        _redo.Clear();
        foreach (var bmp in seen) bmp.Dispose();
    }

    // ---------- toolbar ----------

    void BuildToolbar()
    {
        _chrome.Dock = DockStyle.Top;
        _chrome.Height = (int)Theme.EditorChromeH;
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
                Image = IconSlot,
                ImageScaling = ToolStripItemImageScaling.None,
                AutoSize = false,
                Size = new Size((int)Theme.EditorBtnW, (int)Theme.EditorBtnH),
                Margin = new Padding((int)Theme.Spacing, 3, (int)Theme.Spacing, 3),
                Padding = Padding.Empty,
                ToolTipText = tip,
                Tag = new IconRef(key),
            };
            b.Click += onClick;
            strip.Items.Add(b);
            return b;
        }

        IconBtn(_actionBar, "copy", "Copy to clipboard (Ctrl+C)", (_, _) => CopyAndClose());
        IconBtn(_actionBar, "save", "Save as… (Ctrl+S)", (_, _) => SaveWithDialog());
        IconBtn(_actionBar, "pin", "Pin to screen (Ctrl+P)", (_, _) => PinAndClose());
        IconBtn(_actionBar, "ocr", "Recognize text", (_, _) => RunOcr());
        IconBtn(_actionBar, "translate", "Recognize + translate", (_, _) => RunTranslate());
        _actionBar.Items.Add(new ToolStripSeparator { AutoSize = false, Size = new Size(8, 18) });

        _colorButton = IconBtn(_actionBar, "color", "Annotation color", (_, _) => PickColor());
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

        (Tool Tool, string Key, string Tip)[] tools =
        [
            (Tool.Select, "select", "Select / move (V)"),
            (Tool.Arrow, "arrow", "Arrow (A)"),
            (Tool.Line, "line", "Line (L)"),
            (Tool.Rect, "rect", "Rectangle (R)"),
            (Tool.Oval, "oval", "Oval (O)"),
            (Tool.Highlight, "highlight", "Highlighter (H)"),
            (Tool.Pen, "pen", "Pen (P)"),
            (Tool.Text, "text", "Text (T)"),
            (Tool.Counter, "counter", "Counter (N)"),
            (Tool.Blur, "pixelate", "Pixelate (B)"),
            (Tool.Crop, "crop", "Crop (C)"),
        ];
        foreach (var (tool, key, tip) in tools)
            _toolButtons[tool] = IconBtn(_toolBar, key, tip, (_, _) => SelectTool(tool));

        // Last-docked Top wins the top edge: add tools first, then actions.
        _chrome.Controls.Add(_toolBar);
        _chrome.Controls.Add(_actionBar);
        _actionBar.Height = (int)Theme.EditorRowH;
        _toolBar.Height = (int)Theme.EditorRowH;

        _actionHint = HoverHint.Attach(_actionBar, pt => _actionBar.GetItemAt(pt)?.ToolTipText);
        _toolHint = HoverHint.Attach(_toolBar, pt => _toolBar.GetItemAt(pt)?.ToolTipText);

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
        strip.CanOverflow = false;
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

    void RunOcr() => TextResultForm.RunOcrFlow(Flatten());
    void RunTranslate() => TextResultForm.RunOcrFlow(Flatten(), autoTranslate: true);

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

    void RefreshLabels()
    {
        _sizeLabel.Text = $"{_image.Width}×{_image.Height}px";
        _zoomLabel.Text = $"{(int)Math.Round(_zoom * 100)}%  ";
    }

    // ---------- zoom ----------

    internal void ApplyZoom(float zoom)
    {
        _zoom = Math.Clamp(zoom, 0.1f, 8f);
        _canvas.Size = new Size(
            (int)(_image.Width * _zoom), (int)(_image.Height * _zoom));
        CenterCanvas();
        _canvas.Invalidate();
        RefreshLabels();
    }

    /// Keeps the shot centered when it's smaller than the viewport.
    void CenterCanvas()
    {
        var vp = _scroller.ClientSize;
        int x = Math.Max(0, (vp.Width - _canvas.Width) / 2);
        int y = Math.Max(0, (vp.Height - _canvas.Height) / 2);
        var scroll = _scroller.AutoScrollPosition;
        _canvas.Location = new Point(x + scroll.X, y + scroll.Y);
    }

    internal void ZoomBy(float factor) => ApplyZoom(_zoom * factor);

    // ---------- undo ----------

    void PushUndo()
    {
        _undo.Push((_image, _annotations.Select(a => a.Clone()).ToList()));
        // bitmaps dropped from the redo stack are unreachable from now on —
        // dispose the ones not still referenced by the undo stack or the canvas
        if (_redo.Count > 0)
        {
            var live = new HashSet<Bitmap>(ReferenceEqualityComparer.Instance) { _image };
            foreach (var (img, _) in _undo) live.Add(img);
            foreach (var (img, _) in _redo)
            {
                if (!live.Contains(img)) img.Dispose();
            }
            _redo.Clear();
        }
    }

    void Undo()
    {
        if (_undo.Count == 0) return;
        _redo.Push((_image, _annotations.Select(a => a.Clone()).ToList()));
        Restore(_undo.Pop());
    }

    void Redo()
    {
        if (_redo.Count == 0) return;
        _undo.Push((_image, _annotations.Select(a => a.Clone()).ToList()));
        Restore(_redo.Pop());
    }

    void Restore((Bitmap img, List<Annotation> anns) state)
    {
        if (!ReferenceEquals(state.img, _image))
        {
            _image = state.img;
            _pixelated?.Dispose();
            _pixelated = null;
            InvalidateScaledCache();
        }
        _annotations.Clear();
        _annotations.AddRange(state.anns);
        _selected = null;
        ApplyZoom(_zoom);
    }

    // ---------- actions ----------

    Bitmap Flatten()
    {
        CommitText();
        bool needsPix = _annotations.Any(a => a is BlurAnnotation);
        return AnnotationRenderer.Flatten(_image, _annotations, needsPix ? Pixelated : null);
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
        using var flat = Flatten();
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
        using var flat = Flatten();
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
        new PinForm(Flatten()).Show();
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
            case Tool.Crop:
                _cropRectPx = RectFrom(_dragStartPx, px);
                _canvas.Invalidate();
                break;
        }
    }

    internal void CanvasMouseUp(MouseEventArgs e)
    {
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
        foreach (var a in _annotations) a.Move(-cropPx.X, -cropPx.Y);
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
            foreach (var a in o._annotations) a.Draw(g, pix);
            o._draft?.Draw(g, pix);

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
