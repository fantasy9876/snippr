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
    CropGrip _grip = CropGrip.None;
    Rectangle _gripOriginal;
    TextBox? _textBox;
    TextAnnotation? _editingText;
    Bitmap? _pixelated;

    /// What the user asked for, and the picture that goes with it.
    public OverlayAction? ChosenAction { get; private set; }
    public Bitmap? Result { get; private set; }
    public Rectangle ResultVirtualRect { get; private set; }

    /// The same surface, unshown, for the headless smoke entry.
    internal static AreaReviewForm CreateForTesting(
        Bitmap frozen, Rectangle bounds, Rectangle selectionLocal) =>
        new(frozen, bounds, selectionLocal);

    internal void PlaceToolbarForTesting() => PlaceToolbar();

    /// Presses a toolbar button the way the control does: by raising the same
    /// key the button raises, through the same binding.
    internal void PressToolForTesting(string iconKey) =>
        _toolbar.RaiseToolForTesting(iconKey);

    internal void PressActionForTesting(string iconKey) =>
        _toolbar.RaiseActionForTesting(iconKey);

    internal void ApplyPresetForTesting(string presetId) =>
        _toolbar.RaiseActionForTesting(presetId);

    public static (OverlayAction? Action, Bitmap? Image, Rectangle Rect) Review(
        Bitmap frozen, Rectangle bounds, Rectangle selectionLocal)
    {
        using var form = new AreaReviewForm(frozen, bounds, selectionLocal);
        form.ShowDialog();
        return (form.ChosenAction, form.Result, form.ResultVirtualRect);
    }

    AreaReviewForm(Bitmap frozen, Rectangle bounds, Rectangle selectionLocal)
    {
        Diag.Click("review", $"open bounds={bounds} selection={selectionLocal}");
        _session = new AreaReviewSession(frozen, selectionLocal)
        {
            Corners = AppSettings.Current.CornerStyle,
        };
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
        // Always: a release ENDS whatever is in flight, wherever the pointer
        // happens to be. Filtering it would leave the surface believing a drag
        // is still going after the button came up over a button.
        _toolbar.MouseUp += (_, e) => ForwardIfCanvas(e, CanvasMouseUp, always: true);
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
            // The key is logged whether or not it matched: an unmatched key is
            // silent by design, and silence is what a user reports as "the
            // button does nothing".
            Diag.Click("review", $"tool key={key} matched={entry.IconKey == key}");
            if (entry.IconKey == key) SelectTool(entry.Tool);
        };
        _toolbar.ActionInvoked += (_, key) =>
        {
            // The backdrop menu forwards its preset ids through the same
            // event, so a preset arrives here as "ocean" rather than as an
            // action — try that reading first.
            if (Enum.TryParse<BackdropPreset>(key, ignoreCase: true, out var preset))
            {
                Diag.Click("review", $"preset={preset}");
                if (_session.ApplyBackdrop(preset)) RefreshSurface(all: true);
                return;
            }
            var entry = ToolCatalog.OverlayActions.FirstOrDefault(a => a.IconKey == key);
            Diag.Click("review", $"action key={key} matched={entry.IconKey == key}");
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

    /// A gesture is under way: a crop being dragged, a mark being drawn, or a
    /// mark being moved.
    bool DragInProgress =>
        _grip != CropGrip.None || _draft != null || _movingSelection;

    void ForwardIfCanvas(
        MouseEventArgs e, Action<MouseEventArgs> handler, bool always = false)
    {
        var (tool, action) = ChromeFrames();
        if (always
            || AreaReviewHitTest.IsCanvas(
                e.Location, tool, action,
                chromeVisible: true, dragInProgress: DragInProgress))
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
            // The same entry the editor's preview uses, so there is one
            // description of a frame and one of its corners. It places itself
            // AROUND the document rect it is given, so what it needs is the
            // crop — the padding is its own business.
            BackdropRender.DrawFrameForPreview(
                g, new RectangleF(crop.X, crop.Y, crop.Width, crop.Height), 1f,
                _session.Backdrop, _session.Corners);
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
            BackdropRender.DrawPlateHairline(g, crop, 1, _session.Corners);

        using (var pen = new Pen(Color.DeepSkyBlue, 1.6f))
            g.DrawRectangle(pen, crop);
        // The handles are drawn from the same helper the hit test reads, so
        // what the user grabs is what they can see.
        using (var fill = new SolidBrush(Color.White))
        using (var edge = new Pen(Color.DeepSkyBlue, 1.2f))
            foreach (var handle in OverlayToolbarLayout.HandleRects(crop, 8f))
            {
                g.FillRectangle(fill, handle);
                g.DrawRectangle(
                    edge, handle.X, handle.Y, handle.Width, handle.Height);
            }
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

    void RefreshSurface(bool all)
    {
        if (all) PlaceToolbar();
        UpdateToolbarState();
        // The toolbar is a CHILD covering the entire surface, and a child is
        // not repainted when its parent is invalidated — the picture under it
        // would keep showing what it showed before the mark was made. It is
        // transparent, so invalidating it is what renders this form's drawing
        // again underneath it.
        Invalidate(true);
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
                if (_movingSelection) { _session.PushUndo(); break; }
                // No mark under the pointer: the crop itself is what Select
                // grabs. Adjusting it is not an edit of the document — the
                // marks stay where they were put, and what changes is how much
                // of them the picture contains.
                _grip = AreaReviewCrop.GripAt(px, _session.PixelRect, HandleSize);
                _gripOriginal = _session.PixelRect;
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
        RefreshSurface(all: false);
    }

    float HandleSize => Theme.HandleHit * DeviceDpi / 96f;

    /// The pointer shape that matches the grip, so the crop advertises what a
    /// drag there will do before the user commits to it. It lives here rather
    /// than beside the arithmetic because `Cursor` is WinForms, and the
    /// arithmetic has to compile into a gate that has no windows at all.
    static Cursor CursorFor(CropGrip grip) => grip switch
    {
        CropGrip.TopLeft or CropGrip.BottomRight => Cursors.SizeNWSE,
        CropGrip.TopRight or CropGrip.BottomLeft => Cursors.SizeNESW,
        CropGrip.Top or CropGrip.Bottom => Cursors.SizeNS,
        CropGrip.Left or CropGrip.Right => Cursors.SizeWE,
        CropGrip.Inside => Cursors.SizeAll,
        _ => Cursors.Cross,
    };

    void CanvasMouseMove(MouseEventArgs e)
    {
        var px = e.Location;
        if (_grip != CropGrip.None)
        {
            _session.SetSelection(
                AreaReviewCrop.Drag(_grip, _gripOriginal, _dragStartPx, px));
            // The toolbar follows the crop DURING the drag: waiting for the
            // release leaves it behind and makes the whole thing jump.
            RefreshSurface(all: true);
            return;
        }
        if (_tool == Tool.Select && e.Button == MouseButtons.None)
            Cursor = CursorFor(
                AreaReviewCrop.GripAt(px, _session.PixelRect, HandleSize));
        if (_movingSelection && _selected != null)
        {
            _selected.Move(px.X - _dragStartPx.X, px.Y - _dragStartPx.Y);
            _dragStartPx = px;
            Invalidate(true);
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
        Invalidate(true);
    }

    void CanvasMouseUp(MouseEventArgs e)
    {
        if (_grip != CropGrip.None)
        {
            _grip = CropGrip.None;
            RefreshSurface(all: true);
            return;
        }
        if (_movingSelection) { _movingSelection = false; RefreshSurface(all: false); return; }
        if (_draft is MagnifierAnnotation pending)
        {
            _draft = null;
            var made = _session.MakeMagnifier(pending.SourceRect);
            if (made != null) _session.Add(made);
            RefreshSurface(all: false);
            return;
        }
        if (_draft != null)
        {
            var bounds = _draft.Bounds;
            if (bounds.Width > 2 || bounds.Height > 2 || _draft is PenAnnotation)
                _session.Add(_draft);
            _draft = null;
            RefreshSurface(all: false);
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
        RefreshSurface(all: false);
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
        Diag.Click("review", $"invoke={action} tool={_tool} crop={_session.PixelRect}");
        CommitText();
        switch (action)
        {
            case OverlayAction.Undo:
                if (_session.Undo()) RefreshSurface(all: true);
                return;
            case OverlayAction.Redo:
                if (_session.Redo()) RefreshSurface(all: true);
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
                if (_session.Undo()) RefreshSurface(all: true);
                return true;
            case Keys.Control | Keys.Y:
                if (_session.Redo()) RefreshSurface(all: true);
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
