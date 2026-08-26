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
    readonly OcrRegionPick _pick = new();
    OcrResultPanel? _panel;

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

    internal Cursor CursorForTesting
    {
        get => Cursor;
        set => Cursor = value;
    }

    internal Rectangle SelectionForTesting => _session.PixelRect;

    internal BackdropMenu BackdropMenuForTesting => _toolbar.Menu;

    /// The chrome control itself. The smoke asks Windows who owns a point and
    /// what a real message does with it, which is the half of the input path
    /// no direct-invoke hook can stand in for.
    internal Control ChromeForTesting => _toolbar;
    internal HoverHint HintForTesting => _toolbar.Hint;
    internal int AnnotationCountForTesting => _session.Annotations.Count;
    internal BackdropCornerStyle CornersForTesting => _session.Corners;
    /// The rectangle the surface was ASKED to cover. Comparing the client
    /// area with the form's own bounds proves nothing: Windows clamps both
    /// together, so they agree while the window is short.
    internal Rectangle RequestedBoundsForTesting => _virtualBounds;

    /// Drives the real key router, so a gate can prove a key the toolbar
    /// ADVERTISES is a key the surface routes.
    internal bool PressKeyForTesting(Keys key)
    {
        var msg = new Message();
        return ProcessCmdKey(ref msg, key);
    }

    /// The region pick, for the smoke: whether the mode is on, what it has
    /// cut, and the panel it opened. Read-only — the smoke arms it through the
    /// real key and the real button, never through here.
    internal bool ArmedForTesting => _pick.Armed;
    internal Rectangle? PickedRegionForTesting => _pick.Region;
    internal OcrResultPanel? PanelForTesting =>
        _panel is { Visible: true } panel ? panel : null;

    internal (int Rail, int Strip) ChromeCountsForTesting =>
        (_toolbar.RailCount, _toolbar.StripCount);

    /// Where the rail and the strip ended up, so the smoke can look at the
    /// pixels inside them rather than at the whole desktop.
    internal (Rectangle Rail, Rectangle Strip) ChromeRectsForTesting
    {
        get
        {
            var (rail, strip) = _toolbar.ChromeFrames;
            return (Rectangle.Round(rail), Rectangle.Round(strip));
        }
    }

    /// Smoke parks this form off-screen (`Reveal` at -32000), so it cannot
    /// place the machine cursor and still round-trip through `PointToClient`.
    /// Production always reads `Cursor.Position`; tests set this instead.
    internal Point? PointerClientForTesting { get; set; }

    /// Presses Magnifier and leaves the drag live, so smoke can photograph
    /// the source frame and the dashed callout before a snapshot exists.
    internal void DragMagnifierForTesting(Point from, Point to)
    {
        SelectTool(Tool.Magnifier);
        CanvasMouseDown(new MouseEventArgs(MouseButtons.Left, 1, from.X, from.Y, 0));
        CanvasMouseMove(new MouseEventArgs(MouseButtons.Left, 1, to.X, to.Y, 0));
    }

    internal void PressActionForTesting(string iconKey) =>
        _toolbar.RaiseActionForTesting(iconKey);

    internal void ApplyPresetForTesting(string presetId) =>
        _toolbar.RaiseActionForTesting(presetId);

    /// The picture a terminal route would hand over — without handing it over.
    /// Pressing Copy for real closes the surface and reaches for a clipboard
    /// the runner does not have.
    internal Bitmap RouteImageForTesting(OverlayAction action) => _session.ForRoute(action);

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
        // WinForms clamps Form.Size to SystemInformation.MaxWindowTrackSize.
        // That metric is the whole desktop, so asking for the virtual screen
        // is within it; the ceiling is set anyway, before the bounds, so the
        // window is never the thing that trims itself.
        MaximumSize = bounds.Size;
        Bounds = bounds;
        TopMost = true;
        ShowInTaskbar = false;
        KeyPreview = true;
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer, true);

        _toolbar.Dock = DockStyle.Fill;
        // The toolbar covers every pixel of this form, so it — not this form —
        // is what the user sees. Handing it the surface painter is what makes
        // ONE render per frame: it used to fake transparency, which re-ran this
        // form's paint inside its own, unbuffered, on top of the invisible
        // render the form had just done for nobody.
        _toolbar.PaintSurface = PaintSurface;
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
        _toolbar.SetActions(
            ToolCatalog.RailActions.Select(a => (a.IconKey, a.HintText)),
            ToolCatalog.StripActions.Select(a => (a.IconKey, a.HintText)));
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
        _toolbar.CornerChosen += (_, style) =>
        {
            // The session snapshotted the setting when it opened, so both have
            // to move or the next repaint puts the old radius back.
            _session.Corners = style;
            AppSettings.Current.BackdropCorners = style.ToString();
            AppSettings.Current.Save();
            Diag.Click("review", $"corners={style}");
            RefreshSurface(all: true);
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

    string _lastChromeLog = "";

    void PlaceToolbar()
    {
        _toolbar.Place(_session.Selection, ClientRectangle);
        // Where the chrome ended up, so "the buttons do nothing" can be told
        // apart from "the buttons are not where the hit test thinks".
        //
        // Said only when it CHANGES. A crop drag re-places the toolbar on
        // every mouse move, and every one of these was a directory create, a
        // size check and a file append on the UI thread — the drag stutter
        // that got blamed on the drawing.
        var (tool, action) = ChromeFrames();
        var line =
            $"toolbar rail={Rectangle.Round(tool)} strip={Rectangle.Round(action)} "
            + $"client={ClientRectangle} selection={_session.Selection}";
        if (line == _lastChromeLog) return;
        _lastChromeLog = line;
        Diag.Click("review", line);
    }

    /// The rail and the strip, in this form's coordinates — the only parts of
    /// the toolbar that are not the picture.
    ///
    /// Read from the toolbar rather than recomputed. `Compute` searches four
    /// placements against seven alignments on each side and eight forbidden
    /// handle rects; the hit test asks this question on EVERY mouse event, and
    /// the answer cannot have changed since the last Place.
    (RectangleF Tool, RectangleF Action) ChromeFrames() => _toolbar.ChromeFrames;

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
                chromeVisible: _toolbar.ChromeVisible,
                dragInProgress: DragInProgress))
            handler(e);
    }

    // ---------- painting ----------

    protected override void OnPaint(PaintEventArgs e) =>
        PaintSurface(e.Graphics, Rectangle.Intersect(e.ClipRectangle, ClientRectangle));

    /// The whole surface, into whatever is asking and clipped to
    /// <paramref name="clip"/>. The toolbar calls this from its own paint —
    /// see the note where it is wired up — and this form's OnPaint calls it
    /// too, so `DrawToBitmap` and the smoke's captures see the same picture.
    void PaintSurface(Graphics g, Rectangle clip)
    {
        if (clip.Width <= 0 || clip.Height <= 0) return;
        g.DrawImageUnscaled(_session.Frozen, 0, 0);
        var crop = _session.PixelRect;

        // The frame is drawn AROUND the crop, on the desktop, so the user sees
        // the picture the export will write rather than a bare selection.
        // Frame first, document back on top — the order compose uses, and the
        // reason it looks right there. Drawing the frame over the desktop and
        // stopping left the user reviewing a rectangle of gradient.
        AreaReviewPreview.Paint(
            g, _session.Frozen, crop, _session.Backdrop, _session.Corners);

        // Everything outside the crop is dimmed — with a frame on, the frame
        // is part of what survives, so the hole is the outer rect.
        using (var dim = new SolidBrush(Color.FromArgb(105, Color.Black)))
        {
            // Built from the clip, not the whole surface: a partial repaint
            // asks GDI+ to fill a region the size of the desktop otherwise,
            // and then throws all but the damaged part of it away.
            var region = new Region(clip);
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
        // what the user grabs is what they can see. On a rounded plate the
        // corner centres sit on the arc; shrinkToArc keeps the 8 px square
        // from covering the cut on a small crop.
        using (var fill = new SolidBrush(Color.White))
        using (var edge = new Pen(Color.DeepSkyBlue, 1.2f))
            foreach (var handle in OverlayToolbarLayout.HandleRects(
                crop, 8f, ReviewCornerRadius, shrinkToArc: true))
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
        InvalidateSurface(null);
    }

    /// Repaints the picture — which means repainting the TOOLBAR, because it
    /// covers this form and draws the surface inside its own paint.
    ///
    /// Never `Invalidate(true)` on the form. That invalidated this form (whose
    /// paint nothing can see under a child covering every pixel), the toolbar,
    /// and recursively all twenty-one buttons — so a single undo repainted the
    /// whole desktop twice and every button once, which is the flicker.
    /// <paramref name="area"/> null means the whole surface.
    void InvalidateSurface(Rectangle? area)
    {
        if (!_toolbar.IsHandleCreated) { Invalidate(); return; }
        if (area is not Rectangle rect) { _toolbar.Invalidate(); return; }
        rect.Intersect(_toolbar.ClientRectangle);
        if (rect.Width > 0 && rect.Height > 0) _toolbar.Invalidate(rect);
    }

    /// Room around a live mark for its stroke, its arrow head and the
    /// antialiasing, so a damage-limited repaint cannot clip what it redraws.
    int DirtyMargin => Theme.Px(32f, DeviceDpi);

    /// What a mark that moved can have changed. Spotlight dims everything
    /// outside itself and the magnifier parks its callout anywhere in the
    /// picture, so neither is bounded by its own rectangle — those two ask for
    /// the crop. An empty rectangle means "no idea", and asks for it too.
    Rectangle Dirty(Annotation mark, Rectangle before, Rectangle after) =>
        mark is SpotlightAnnotation or MagnifierAnnotation
            || before.IsEmpty || after.IsEmpty
            ? Rectangle.Inflate(_session.PixelRect, DirtyMargin, DirtyMargin)
            : Rectangle.Inflate(
                Rectangle.Union(before, after), DirtyMargin, DirtyMargin);

    // ---------- tools ----------

    void SelectTool(Tool tool)
    {
        CommitText();
        // Choosing a tool states a DIFFERENT intent, so it ends an armed
        // pick. macOS left the mode up: the toolbar lit the new tool, the
        // cursor could not tell a pen from an armed pick — both are a cross —
        // and the drag still cut a region. This is the authoritative point
        // every route lands on, so cancelling here closes the keyboard, the
        // button and the programmatic routes at once.
        _pick.Cancel();
        _tool = tool;
        _toolbar.Hint.HideNow();
        UpdateToolbarState();
        // Re-evaluate immediately at the pointer: switching back to Select
        // while the pointer is inside the crop must be SizeAll, not Cross
        // until the next move. Drawing tools stay Cross regardless of hit.
        ApplyCursor(CurrentPointerClient());
    }

    Point CurrentPointerClient() =>
        PointerClientForTesting ?? PointToClient(Cursor.Position);

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
            "review",
            $"window asked={_virtualBounds.Size} got={Size} client={ClientSize}");
    }

    void CanvasMouseDown(MouseEventArgs e)
    {
        CommitText();
        _toolbar.Hint.HideNow();
        var px = e.Location;
        _dragStartPx = px;
        if (e.Button != MouseButtons.Left) return;
        // Armed answers FIRST, and it answers everywhere: the crop, its
        // handles and the surround are all places a region drag may begin.
        // Asking the tool first is how macOS ended up resizing the crop from
        // inside a mode whose whole purpose was to cut a rectangle out of it.
        if (_pick.Armed)
        {
            _pick.Begin(px, _session.PixelRect);
            InvalidateSurface(_session.PixelRect);
            return;
        }
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
                _grip = AreaReviewCrop.GripAt(
                    px, _session.PixelRect, HandleSize, ReviewCornerRadius);
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

    /// Radius the plate actually draws. No plate (or style None) keeps the
    /// handles on the geometric corners — same as the overlay, which has no
    /// preset.
    float ReviewCornerRadius =>
        _session.Backdrop == BackdropPreset.None
            ? 0
            : BackdropSpec.CornerRadius(_session.PixelRect.Size, _session.Corners);

    /// The pointer shape that matches (tool, hit). The table lives in
    /// `AreaReviewCursor` so the parity gate can read it; this is only the
    /// WinForms mapping.
    static Cursor CursorFor(Tool tool, CropGrip grip, bool armed = false) =>
        AreaReviewCursor.For(tool, grip, armed) switch
    {
        ReviewCursorKind.IBeam => Cursors.IBeam,
        ReviewCursorKind.SizeNWSE => Cursors.SizeNWSE,
        ReviewCursorKind.SizeNESW => Cursors.SizeNESW,
        ReviewCursorKind.SizeNS => Cursors.SizeNS,
        ReviewCursorKind.SizeWE => Cursors.SizeWE,
        ReviewCursorKind.SizeAll => Cursors.SizeAll,
        _ => Cursors.Cross,
    };

    void ApplyCursor(Point px)
    {
        var grip = _tool == Tool.Select
            ? AreaReviewCrop.GripAt(px, _session.PixelRect, HandleSize, ReviewCornerRadius)
            : CropGrip.None;
        Cursor = CursorFor(_tool, grip, _pick.Armed);
    }

    // ---------- region OCR ----------

    /// Arms the pick. Not a terminal route and not an edit: nothing is
    /// committed, no undo entry is added, and the review stays open — the
    /// whole reason the old `TextResultForm` flow was replaced.
    void BeginRegionPick(bool translates)
    {
        HidePanel();
        _pick.Arm(translates);
        ApplyCursor(CurrentPointerClient());
        InvalidateSurface(_session.PixelRect);
    }

    /// Recognizes one region and shows it beside itself.
    ///
    /// Reads `Semantic(region)` — the document with its marks — and never a
    /// crop of the frozen desktop. Cutting the freeze would read straight
    /// through a pixelation the user drew over something private.
    async void RecognizeRegion(Rectangle region)
    {
        // `ShowPanel` empties the panel before showing it, so the generation
        // read below is taken after every synchronous step that could move it.
        var panel = ShowPanel(region);
        if (panel == null) return;
        var generation = _pick.Generation;
        string text;
        try
        {
            using var source = _session.Semantic(region);
            var result = await OcrService.RecognizeAsync(source);
            text = result.Text;
        }
        catch (Exception ex)
        {
            Diag.Click("review", $"region ocr failed: {ex.GetType().Name}");
            text = "";
        }
        // Every await needs its own generation check, not just the first: a
        // recognition that lands after the user has picked somewhere else
        // would otherwise fill the panel with text describing other pixels,
        // with nothing on screen to explain it.
        if (generation != _pick.Generation) return;
        if (_panel != panel || panel.IsDisposed) return;
        panel.ShowResult(text);
        if (panel.TranslateMode && text.Length > 0) await TranslateInPanel(panel, generation);
    }

    /// The SECOND async hop, and it needs its own generation check — not just
    /// the first. A translation that comes back after the user has picked a
    /// new region would otherwise land in a panel describing other pixels,
    /// with nothing on screen to explain it.
    ///
    /// Always translates `SourceText`: running a translation through a second
    /// language compounds its errors, which is the stacked-translation bug the
    /// old Windows window shipped until #21.
    async Task TranslateInPanel(OcrResultPanel panel, int generation)
    {
        var (code, label) = panel.SelectedLanguage;
        var source = panel.SourceText;
        if (source.Length == 0) return;
        panel.ShowTranslating(label);
        string? translated = null;
        string reason = "";
        try
        {
            translated = await TranslateService.TranslateAsync(source, code);
        }
        catch (Exception error)
        {
            // The reason, not a shrug. One classifier shared with the old
            // window and with macOS, so a screenshot triages the same way
            // whichever surface it came from.
            reason = TranslateService.Failure.Classify(error).UserMessage;
        }
        if (generation != _pick.Generation) return;
        if (_panel != panel || panel.IsDisposed || !panel.Visible) return;
        if (translated is { Length: > 0 }) panel.ShowTranslated(translated, label);
        else
            panel.ShowTranslateFailed(
                reason.Length > 0
                    ? reason
                    : TranslateService.Failure.Payload(null).UserMessage);
    }

    OcrResultPanel? ShowPanel(Rectangle region)
    {
        if (_panel == null)
        {
            var panel = new OcrResultPanel();
            panel.CopyRequested += (_, _) => CopyPanelText();
            panel.CloseRequested += (_, _) => HidePanel();
            // Retry and a language change take the SAME path a fresh
            // recognition takes — one call site, so the three cannot drift
            // into three different ideas of what gets translated.
            panel.RetryRequested += (_, _) => RetryTranslation();
            panel.LanguageChanged += (_, code) =>
            {
                AppSettings.Current.TranslateTarget = code;
                AppSettings.Current.Save();
                RetryTranslation();
            };
            // A child of the chrome control, which is what covers the surface:
            // WinForms then routes this panel's own clicks and its own cursor
            // to it, and `AreaReviewHitTest` never sees them at all.
            _toolbar.Controls.Add(panel);
            _panel = panel;
        }
        // BEFORE the placement: translate mode is a taller panel, and the
        // placement is computed from its size.
        _panel.SetTranslateMode(_pick.Translates);
        if (!PlacePanel(region)) { HidePanel(); return null; }
        // Emptied BEFORE it is shown. Made visible first, the panel wears the
        // previous region's text for the frame it takes the caller to clear
        // it — text that belongs to pixels the user is no longer pointing at.
        _panel.ShowRecognizing();
        _panel.Visible = true;
        _panel.BringToFront();
        return _panel;
    }

    /// True when a placement exists. When none does — a region that fills the
    /// screen, chrome in every candidate — the panel does not appear at all
    /// rather than covering the very pixels it describes.
    bool PlacePanel(Rectangle region)
    {
        if (_panel == null) return false;
        var (rail, strip) = ChromeFrames();
        var placed = OcrPanelPlacement.Place(
            _panel.Size, region, ClientRectangle, rail, strip);
        if (placed is not { } frame) return false;
        _panel.Bounds = frame;
        return true;
    }

    bool HidePanel()
    {
        if (_panel is not { Visible: true } panel) return false;
        panel.Visible = false;
        // Closing the panel abandons the recognition it was opened for. The
        // comment on `RecognizeRegion` promises a late result cannot land in a
        // panel describing other pixels; without this bump the promise held
        // for a new PICK and not for a close, which is the same window with a
        // different door.
        _pick.DropPending();
        return true;
    }

    /// Re-runs the translation for the text already on screen. Moves the
    /// generation first, so a request still in flight cannot land afterwards
    /// and overwrite the newer one.
    async void RetryTranslation()
    {
        if (_panel is not { Visible: true } panel || !panel.TranslateMode) return;
        _pick.DropPending();
        await TranslateInPanel(panel, _pick.Generation);
    }

    void CopyPanelText()
    {
        if (_panel?.RecognizedText is not { Length: > 0 } text) return;
        try { Clipboard.SetText(text, TextDataFormat.UnicodeText); } catch { }
        // Copy closes the panel and says so — but the SESSION lives on. The
        // shot surviving the copy is the point of the whole flow.
        HidePanel();
        ToastForm.Show("Text copied");
    }

    void CanvasMouseMove(MouseEventArgs e)
    {
        var px = e.Location;
        if (_pick.Armed)
        {
            // The cursor is re-derived on every move, so the armed answer has
            // to come from the table rather than from a one-off set when the
            // mode began — that is precisely the frame-long crosshair macOS
            // shipped.
            if (e.Button == MouseButtons.None) ApplyCursor(px);
            if (_pick.Drag(px, _session.PixelRect))
                InvalidateSurface(_session.PixelRect);
            return;
        }
        if (_grip != CropGrip.None)
        {
            _session.SetSelection(
                AreaReviewCrop.Drag(_grip, _gripOriginal, _dragStartPx, px));
            // The toolbar follows the crop DURING the drag: waiting for the
            // release leaves it behind and makes the whole thing jump.
            RefreshSurface(all: true);
            return;
        }
        if (e.Button == MouseButtons.None)
            ApplyCursor(px);
        if (_movingSelection && _selected is { } mark)
        {
            var moved = mark.Bounds;
            mark.Move(px.X - _dragStartPx.X, px.Y - _dragStartPx.Y);
            _dragStartPx = px;
            InvalidateSurface(Dirty(mark, moved, mark.Bounds));
            return;
        }
        if (_draft is not { } draft) return;
        var was = draft.Bounds;
        switch (draft)
        {
            case ShapeAnnotation s: s.End = px; break;
            case PenAnnotation p: p.Points.Add(px); break;
            case BlurAnnotation b: b.Rect = RectFrom(_dragStartPx, px); break;
            case SpotlightAnnotation spot: spot.Rect = RectFrom(_dragStartPx, px); break;
            case MagnifierAnnotation mag:
                mag.SourceRect = RectFrom(_dragStartPx, px);
                // Same region MakeMagnifier will commit: a drag that leaves
                // the crop must not park the dashed outline somewhere the
                // loupe will not land.
                mag.CalloutRect = MagnifierAnnotation.PlaceCallout(
                    Rectangle.Intersect(mag.SourceRect, _session.PixelRect),
                    _session.PixelRect,
                    MagnifierAnnotation.DefaultZoom);
                break;
            default: return;
        }
        // Only what the mark touched. Repainting the whole virtual desktop per
        // mouse move is what made drawing feel like it was catching up.
        InvalidateSurface(Dirty(draft, was, draft.Bounds));
    }

    void CanvasMouseUp(MouseEventArgs e)
    {
        if (_pick.Armed)
        {
            var region = _pick.Finish(e.Location, _session.PixelRect);
            InvalidateSurface(_session.PixelRect);
            // Null is a stray click, and the mode stays armed on purpose (see
            // `OcrRegionPick.Finish`): the toolbar shows no sign the mode is
            // on, so dropping the user out of it silently reads as a dead
            // button. They simply drag again.
            if (region is { } picked) RecognizeRegion(picked);
            ApplyCursor(e.Location);
            return;
        }
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
            // Not terminal any more: both arm a region pick and the review
            // stays open. Falling through to the export below is the 1.2.15
            // behaviour — recognize the whole crop, tear the session down.
            case OverlayAction.Ocr:
                BeginRegionPick(translates: false);
                return;
            case OverlayAction.Translate:
                BeginRegionPick(translates: true);
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
            // One layer at a time: the panel, then the pick, then the
            // session. Closing the shot while its text is still on screen is
            // exactly what this flow exists to stop doing.
            case Keys.Escape:
                if (HidePanel()) return true;
                if (_pick.Cancel()) { ApplyCursor(CurrentPointerClient()); return true; }
                Close();
                return true;
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
            // Read from the SAME catalog rows the buttons and their hints use
            // — a key that routes but is advertised nowhere is undiscoverable,
            // and a hint naming a key nothing routes is a broken promise.
            case Keys.X: Invoke(OverlayAction.Ocr); return true;
            case Keys.G: Invoke(OverlayAction.Translate); return true;
        }
        // Tool keys, host-scoped: a letter that names a tool this surface does
        // not show must do nothing rather than select an invisible tool.
        var label = keyData.ToString();
        // D opens the backdrop menu, as it does on macOS. It is checked
        // before the tool map because Backdrop is an ACTION: choosing a
        // preset must not displace the tool the user is drawing with.
        if (string.Equals(label, "D", StringComparison.OrdinalIgnoreCase))
        {
            _toolbar.OpenBackdropMenu();
            return true;
        }
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
