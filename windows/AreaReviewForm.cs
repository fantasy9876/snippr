using System.Drawing;
using System.Drawing.Drawing2D;

namespace Snippr;

/// Review in place: the frozen desktop stays on screen, the selection stays
/// where it was dragged, and the toolbar appears beside it. Nothing here
/// decides what the user ends up with — that is `AreaReviewSession`. This is
/// the drawing and the routing.
sealed class AreaReviewForm : Form
{
    readonly AreaReviewSession _session;
    readonly Rectangle _virtualBounds;
    readonly OverlayToolbar _toolbar = new();

    Tool _tool = Tool.Select;
    Color _color = Color.Red;
    Annotation? _draft;
    Point _dragStartPx;
    Annotation? _selected;
    bool _movingSelection;
    TextBox? _textBox;
    TextAnnotation? _editingText;
    Bitmap? _pixelated;

    /// What the user asked for, and the picture that goes with it.
    public OverlayAction? ChosenAction { get; private set; }
    public Bitmap? Result { get; private set; }
    public Rectangle ResultVirtualRect { get; private set; }

    public static (OverlayAction? Action, Bitmap? Image, Rectangle Rect) Review(
        Bitmap frozen, Rectangle bounds, Rectangle selectionLocal)
    {
        using var form = new AreaReviewForm(frozen, bounds, selectionLocal);
        form.ShowDialog();
        return (form.ChosenAction, form.Result, form.ResultVirtualRect);
    }

    AreaReviewForm(Bitmap frozen, Rectangle bounds, Rectangle selectionLocal)
    {
        _session = new AreaReviewSession(frozen, selectionLocal);
        _virtualBounds = bounds;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        TopMost = true;
        ShowInTaskbar = false;
        KeyPreview = true;
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer, true);

        _toolbar.Dock = DockStyle.Fill;
        BindToolbar();
        Controls.Add(_toolbar);
        // The toolbar covers the whole surface, so its own mouse events ARE
        // the ones that land on the picture. Forwarding them is what keeps the
        // tools usable at all; `AreaReviewHitTest` decides which are chrome.
        _toolbar.MouseDown += (_, e) => ForwardIfCanvas(e, CanvasMouseDown);
        _toolbar.MouseMove += (_, e) => ForwardIfCanvas(e, CanvasMouseMove);
        _toolbar.MouseUp += (_, e) => ForwardIfCanvas(e, CanvasMouseUp);
        Shown += (_, _) => PlaceToolbar();
    }

    // ---------- toolbar ----------

    void BindToolbar()
    {
        _toolbar.SetTools(ToolCatalog.OverlayTools.Select(e => (e.IconKey, e.HintText)));
        _toolbar.SetActions(ToolCatalog.OverlayActions.Select(a => (a.IconKey, a.HintText)));
        _toolbar.SetColor(_color);
        _toolbar.ToolSelected += (_, key) =>
        {
            var entry = ToolCatalog.OverlayTools.FirstOrDefault(e => e.IconKey == key);
            if (entry.IconKey == key) SelectTool(entry.Tool);
        };
        _toolbar.ActionInvoked += (_, key) =>
        {
            // The backdrop menu forwards its preset ids through the same
            // event, so a preset arrives here as "ocean" rather than as an
            // action — try that reading first.
            if (Enum.TryParse<BackdropPreset>(key, ignoreCase: true, out var preset))
            {
                if (_session.ApplyBackdrop(preset)) Refresh(all: true);
                return;
            }
            var entry = ToolCatalog.OverlayActions.FirstOrDefault(a => a.IconKey == key);
            if (entry.IconKey == key) Invoke(entry.Action);
        };
        UpdateToolbarState();
    }

    void UpdateToolbarState()
    {
        var active = ToolCatalog.Entry(_tool)?.IconKey;
        _toolbar.SetActive(active);
        _toolbar.SetUndoRedo(_session.CanUndo, _session.CanRedo);
    }

    void PlaceToolbar() => _toolbar.Place(_session.Selection, ClientRectangle);

    /// The rail and the strip, in this form's coordinates — the only parts of
    /// the toolbar that are not the picture.
    (RectangleF Tool, RectangleF Action) ChromeFrames()
    {
        var metrics = OverlayToolbarLayout.Metrics.Standard.Scaled(DeviceDpi / 96f);
        var area = OverlayToolbarLayout.Compute(
            _session.Selection, ClientRectangle,
            ToolCatalog.OverlayTools.Count(), ToolCatalog.OverlayActions.Count(),
            Theme.HandleHit * DeviceDpi / 96f, metrics);
        return area is { } placed
            ? (placed.ToolFrame, placed.ActionFrame)
            : (RectangleF.Empty, RectangleF.Empty);
    }

    void ForwardIfCanvas(MouseEventArgs e, Action<MouseEventArgs> handler)
    {
        var (tool, action) = ChromeFrames();
        if (AreaReviewHitTest.IsCanvas(e.Location, tool, action, chromeVisible: true))
            handler(e);
    }

    // ---------- painting ----------

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.DrawImageUnscaled(_session.Frozen, 0, 0);
        var crop = _session.PixelRect;

        // The frame is drawn AROUND the crop, on the desktop, so the user sees
        // the picture the export will write rather than a bare selection.
        if (_session.Backdrop != BackdropPreset.None)
        {
            var layout = new BackdropLayout(crop.Size, 1, _session.Backdrop);
            var outer = new RectangleF(
                crop.X - layout.Pad, crop.Y - layout.Pad,
                layout.OuterSize.Width, layout.OuterSize.Height);
            var state = g.Save();
            g.TranslateTransform(outer.X, outer.Y);
            BackdropRender.DrawFrame(
                g, new SizeF(outer.Width, outer.Height),
                new RectangleF(layout.Pad, layout.Pad, crop.Width, crop.Height),
                _session.Backdrop, 1);
            g.Restore(state);
        }

        // Everything outside the crop is dimmed — with a frame on, the frame
        // is part of what survives, so the hole is the outer rect.
        using (var dim = new SolidBrush(Color.FromArgb(105, Color.Black)))
        {
            var region = new Region(ClientRectangle);
            region.Exclude(VisibleOuterRect());
            g.FillRegion(dim, region);
            region.Dispose();
        }

        var marks = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.SetClip(crop);
        var live = _draft == null
            ? _session.Annotations
            : _session.Annotations.Concat([_draft]);
        // The same entry, and the same question, the export asks.
        AnnotationCompositor.Draw(live, g, _session.Frozen, crop, Pixelated(live));
        g.Restore(marks);

        if (_session.Backdrop != BackdropPreset.None)
            BackdropRender.DrawPlateHairline(g, crop, 1);

        using (var pen = new Pen(Color.DeepSkyBlue, 1.6f))
            g.DrawRectangle(pen, crop);
        if (_selected != null)
        {
            using var sel = new Pen(Color.DeepSkyBlue, 1.5f) { DashStyle = DashStyle.Dash };
            g.DrawRectangle(sel, Rectangle.Inflate(_selected.Bounds, 5, 5));
        }
    }

    Rectangle VisibleOuterRect()
    {
        var crop = _session.PixelRect;
        if (_session.Backdrop == BackdropPreset.None) return crop;
        var layout = new BackdropLayout(crop.Size, 1, _session.Backdrop);
        return new Rectangle(
            crop.X - (int)layout.Pad, crop.Y - (int)layout.Pad,
            layout.OuterSize.Width, layout.OuterSize.Height);
    }

    Bitmap? Pixelated(IEnumerable<Annotation> marks)
    {
        var needs = marks.Any(a => a is BlurAnnotation);
        if (!needs) return null;
        return _pixelated ??= AnnotationRenderer.Pixelate(_session.Frozen);
    }

    void Refresh(bool all)
    {
        if (all) PlaceToolbar();
        UpdateToolbarState();
        Invalidate();
    }

    // ---------- tools ----------

    void SelectTool(Tool tool)
    {
        CommitText();
        _tool = tool;
        _toolbar.Hint.HideNow();
        UpdateToolbarState();
    }

    void CanvasMouseDown(MouseEventArgs e)
    {
        CommitText();
        _toolbar.Hint.HideNow();
        var px = e.Location;
        _dragStartPx = px;
        if (e.Button != MouseButtons.Left) return;
        // Drawing happens inside the crop; the surround is the picture's
        // outside, where a mark would be clipped away the moment it was made.
        if (!_session.PixelRect.Contains(px) && _tool != Tool.Select) return;

        switch (_tool)
        {
            case Tool.Select:
                _selected = _session.Annotations.AsEnumerable().Reverse()
                    .FirstOrDefault(a => a.HitTest(px));
                _movingSelection = _selected != null;
                if (_movingSelection) _session.PushUndo();
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
                    BaseBounds = _session.PixelRect,
                };
                break;
            case Tool.Magnifier:
                _draft = new MagnifierAnnotation
                {
                    SourceRect = new Rectangle(px, Size.Empty),
                    CalloutRect = new Rectangle(px, Size.Empty),
                };
                break;
            case Tool.Counter:
                _session.Add(new CounterAnnotation
                {
                    Center = px,
                    Color = _color,
                    Number = _session.Annotations.OfType<CounterAnnotation>()
                        .Select(c => c.Number).DefaultIfEmpty(0).Max() + 1,
                });
                break;
            case Tool.Text:
                BeginText(px);
                break;
        }
        Refresh(all: false);
    }

    void CanvasMouseMove(MouseEventArgs e)
    {
        var px = e.Location;
        if (_movingSelection && _selected != null)
        {
            _selected.Move(px.X - _dragStartPx.X, px.Y - _dragStartPx.Y);
            _dragStartPx = px;
            Invalidate();
            return;
        }
        switch (_draft)
        {
            case ShapeAnnotation s: s.End = px; break;
            case PenAnnotation p: p.Points.Add(px); break;
            case BlurAnnotation b: b.Rect = RectFrom(_dragStartPx, px); break;
            case SpotlightAnnotation spot: spot.Rect = RectFrom(_dragStartPx, px); break;
            case MagnifierAnnotation mag:
                mag.SourceRect = RectFrom(_dragStartPx, px);
                mag.CalloutRect = mag.SourceRect;
                break;
            default: return;
        }
        Invalidate();
    }

    void CanvasMouseUp(MouseEventArgs e)
    {
        if (_movingSelection) { _movingSelection = false; Refresh(all: false); return; }
        if (_draft is MagnifierAnnotation pending)
        {
            _draft = null;
            var made = _session.MakeMagnifier(pending.SourceRect);
            if (made != null) _session.Add(made);
            Refresh(all: false);
            return;
        }
        if (_draft != null)
        {
            var bounds = _draft.Bounds;
            if (bounds.Width > 2 || bounds.Height > 2 || _draft is PenAnnotation)
                _session.Add(_draft);
            _draft = null;
            Refresh(all: false);
        }
    }

    static Rectangle RectFrom(Point a, Point b) => Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));

    // ---------- text ----------

    void BeginText(Point px)
    {
        _editingText = new TextAnnotation { Origin = px, Color = _color };
        _textBox = new TextBox
        {
            Location = px,
            Width = 240,
            Font = new Font("Segoe UI", 15f),
            ForeColor = _color,
            BackColor = Color.FromArgb(40, 42, 50),
            BorderStyle = BorderStyle.FixedSingle,
        };
        _textBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; CommitText(); }
            if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; CancelText(); }
        };
        Controls.Add(_textBox);
        _textBox.BringToFront();
        _textBox.Focus();
    }

    void CommitText()
    {
        if (_textBox == null || _editingText == null) return;
        var text = _textBox.Text;
        var origin = _editingText.Origin;
        var colour = _editingText.Color;
        CancelText();
        if (text.Length == 0) return;
        _session.Add(new TextAnnotation { Origin = origin, Color = colour, Text = text });
        Refresh(all: false);
    }

    void CancelText()
    {
        if (_textBox != null)
        {
            Controls.Remove(_textBox);
            _textBox.Dispose();
            _textBox = null;
        }
        _editingText = null;
    }

    // ---------- actions ----------

    void Invoke(OverlayAction action)
    {
        CommitText();
        switch (action)
        {
            case OverlayAction.Undo:
                if (_session.Undo()) Refresh(all: true);
                return;
            case OverlayAction.Redo:
                if (_session.Redo()) Refresh(all: true);
                return;
            case OverlayAction.Color:
                PickColor();
                return;
            case OverlayAction.Backdrop:
                _toolbar.Menu.Show(_toolbar, PointToClient(MousePosition));
                return;
            case OverlayAction.Close:
                Close();
                return;
        }
        // Everything else produces a picture and ends the session. The image
        // is built BEFORE anything is torn down, and a failure leaves the
        // review exactly as it was rather than closing over a lost capture.
        Bitmap image;
        try
        {
            image = _session.ForRoute(action);
        }
        catch (Exception)
        {
            ToastForm.Show("Không dựng được ảnh — thử lại");
            return;
        }
        ChosenAction = action;
        Result = image;
        var crop = _session.PixelRect;
        ResultVirtualRect = new Rectangle(
            crop.X + _virtualBounds.X, crop.Y + _virtualBounds.Y, crop.Width, crop.Height);
        Close();
    }

    void PickColor()
    {
        using var dlg = new ColorDialog { Color = _color, FullOpen = true };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        _color = dlg.Color;
        _toolbar.SetColor(_color);
    }

    // ---------- keyboard ----------

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_textBox != null) return base.ProcessCmdKey(ref msg, keyData);
        switch (keyData)
        {
            case Keys.Escape: Close(); return true;
            case Keys.Control | Keys.Z:
                if (_session.Undo()) Refresh(all: true);
                return true;
            case Keys.Control | Keys.Y:
                if (_session.Redo()) Refresh(all: true);
                return true;
            case Keys.Control | Keys.C: Invoke(OverlayAction.Copy); return true;
            case Keys.Control | Keys.S: Invoke(OverlayAction.Save); return true;
            case Keys.Control | Keys.P: Invoke(OverlayAction.Pin); return true;
            case Keys.E: Invoke(OverlayAction.OpenEditor); return true;
        }
        // Tool keys, host-scoped: a letter that names a tool this surface does
        // not show must do nothing rather than select an invisible tool.
        var label = keyData.ToString();
        if (label.Length == 1
            && ToolCatalog.ToolForKey(label, inOverlay: true) is Tool tool)
        {
            SelectTool(tool);
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _pixelated?.Dispose();
            _toolbar.Dispose();
        }
        base.Dispose(disposing);
    }
}
