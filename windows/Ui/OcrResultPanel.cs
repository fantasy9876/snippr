using System.Drawing;
using System.Runtime.InteropServices;

namespace Snippr;

/// The recognized text, beside the pixels it came from.
///
/// Windows reading of macOS `OverlayOCRResultView`. Two differences that are
/// the platform, not the design:
///
/// - it is a CONTROL, not a hand-drawn view. WinForms routes the mouse and the
///   cursor to whichever control owns a point, so the whole class of macOS bug
///   where the host overwrites every cursor on every move cannot happen here.
///   The rule still applies and is still stated per control below: a live
///   button reads as pressable, a dead one does not, and text you can select
///   reads as text.
/// - the dark plate is pinned, not inherited. Overlay chrome is dark in both
///   Windows themes — the same contract `OverlayChrome` holds everywhere else
///   — so the panel names its own colours instead of taking whatever the
///   system theme hands a TextBox. macOS shipped a version that mixed a
///   hard-coded dark plate with a system-resolved text colour and the text
///   vanished in Light mode; naming both is what stops that.
sealed class OcrResultPanel : Control
{
    /// Names, not labels. A gate that finds a control by its visible text
    /// passes for the wrong reasons the day the text changes or is localised;
    /// these are the handles it looks the controls up by.
    public const string TextName = "ocr.panel.text";
    public const string CopyName = "ocr.panel.copy";
    public const string CloseName = "ocr.panel.close";
    public const string StatusName = "ocr.panel.status";
    public const string LanguageName = "ocr.panel.language";
    public const string RetryName = "ocr.panel.retry";

    /// DIP, mirroring macOS `OverlayOCRPanel.size` (300×176).
    public const int BaseWidth = 300;
    public const int BaseHeight = 176;
    /// Translate mode adds ONE row for the language chooser, and the panel
    /// grows instead of the text box shrinking: the text is the thing being
    /// read. Same choice as macOS `languageRowHeight`.
    public const int LanguageRowHeight = 26;
    const int Inset = 10;
    const int FooterHeight = 26;
    const int Gap = 8;

    readonly TextBox _text = new();
    readonly Button _copy = new();
    readonly Button _close = new();
    readonly Label _status = new();
    readonly Button _language = new();
    /// Built on first use, not in the constructor: a ContextMenuStrip created
    /// while the panel's own handle is being made crashes WinForms outright
    /// ("Dispose() cannot be called while doing CreateHandle()"), which took
    /// the whole smoke down rather than one step.
    ContextMenuStrip? _languages;
    readonly Button _retry = new();

    /// What the panel WANTS the optional row to look like, kept apart from
    /// `Control.Visible`.
    ///
    /// A child hidden before its handle exists does not stay hidden: WinForms
    /// creates the native window from the parent later and the control comes
    /// back visible. On the runner that showed up as Thử lại reappearing one
    /// millisecond after the code that hid it — `_retry.Visible` read False
    /// inside the panel and True from the gate, same instance, same thread,
    /// with no writer in between. So the wish is state, and the applier below
    /// runs again whenever a handle is created.
    bool _retryWanted;

    /// The language the panel last acted on, so choosing the one already on
    /// screen spends nothing.
    string _lastLanguage = "";
    int _selected;

    /// The last few state transitions, in memory, dumped by a gate when an
    /// assertion about this panel fails.
    ///
    /// Memory and not a log line on purpose: writing a line per transition
    /// perturbs the very ordering it is meant to describe. The race behind
    /// `ApplyRowVisibility` was invisible until this existed — and passed,
    /// misleadingly, on the run where the probe wrote to a file.
    internal readonly List<string> TraceForTesting = new();

    void Trace(string what)
    {
        if (TraceForTesting.Count > 64) TraceForTesting.RemoveAt(0);
        TraceForTesting.Add($"{what} want={_retryWanted} vis={_retry.Visible}"
            + $" mode={TranslateMode}");
    }

    /// What Copy would put on the clipboard. Held here rather than read back
    /// out of the TextBox so a later translation can replace it without the
    /// panel having to guess which of the two the user meant.
    public string RecognizedText { get; private set; } = "";

    /// The RECOGNITION, kept apart from what is on screen so a language change
    /// re-translates the original rather than a translation of a translation,
    /// and so a failure can fall back to it. Windows shipped the stacked-
    /// translation bug in the old window for want of exactly this field.
    public string SourceText { get; private set; } = "";

    /// Translate mode shows the language row and translates after every
    /// recognition; plain OCR does neither. The panel is reused across picks,
    /// so this is state rather than a construction-time choice.
    public bool TranslateMode { get; private set; }

    public event EventHandler? RetryRequested;
    /// The chosen language code, raised when the user picks a different one.
    public event EventHandler<string>? LanguageChanged;

    public event EventHandler? CopyRequested;
    public event EventHandler? CloseRequested;

    public OcrResultPanel()
    {
        SetStyle(
            ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque,
            true);
        BackColor = Theme.Chrome;
        // The panel body is not a control you press and not text you select.
        Cursor = Cursors.Default;

        _text.Name = TextName;
        _text.Multiline = true;
        _text.ScrollBars = ScrollBars.Vertical;
        _text.BorderStyle = BorderStyle.None;
        // Selectable but NOT editable: the user copies it, or edits it after
        // pasting somewhere that keeps the edit. An editable box here would
        // invite corrections the panel throws away when it closes.
        _text.ReadOnly = true;
        _text.BackColor = Color.FromArgb(18, 19, 23);
        _text.ForeColor = Color.White;
        _text.Font = new Font(FontFamily.GenericMonospace, 9f);
        _text.Cursor = Cursors.IBeam;
        Controls.Add(_text);
        // The handle exists only once the control is parented; ask again then,
        // because the panel's own handle may already be up by that point.
        _text.HandleCreated += (_, _) =>
            SetWindowTheme(_text.Handle, "DarkMode_Explorer", null);

        StyleButton(_copy, CopyName, "Copy");
        _copy.Click += (_, _) => CopyRequested?.Invoke(this, EventArgs.Empty);
        Controls.Add(_copy);

        StyleButton(_close, CloseName, "✕");
        _close.Click += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        Controls.Add(_close);

        _status.Name = StatusName;
        _status.AutoSize = false;
        _status.ForeColor = Theme.IconMuted;
        _status.BackColor = Color.Transparent;
        _status.TextAlign = ContentAlignment.MiddleLeft;
        // A label is not a control: pointing at it must not look like an offer.
        _status.Cursor = Cursors.Default;
        Controls.Add(_status);

        // A DropDownList ComboBox paints its field AND its arrow from the
        // Windows theme and ignores BackColor — the first CI shot of this row
        // came back as ~3000px of near-white down a dark plate, and owner-
        // drawing the items still left the arrow and the border system-
        // coloured (906px). So the chooser is a flat button plus the same
        // dark `ContextMenuStrip` the backdrop menu already uses: every pixel
        // of it comes from the app.
        StyleButton(_language, LanguageName, "");
        var savedCode = AppSettings.Current.TranslateTarget;
        var savedIndex = Array.FindIndex(
            TranslateService.Languages, l => l.Code == savedCode);
        _selected = savedIndex >= 0 ? savedIndex : 0;
        _lastLanguage = SelectedLanguage.Code;
        _language.Text = SelectedLanguage.Label + "  ▾";
        _language.Click += (_, _) => ShowLanguageMenu();
        _language.Visible = false;
        Controls.Add(_language);

        StyleButton(_retry, RetryName, "Thử lại");
        _retry.Click += (_, _) => RetryRequested?.Invoke(this, EventArgs.Empty);
        // Only after a failure. A retry button on a working translation is an
        // offer to redo something that already worked.
        Controls.Add(_retry);
        // The resurrection window: both of these are hidden before they have
        // handles, so both have to be told again once they get one.
        _retry.HandleCreated += (_, _) => ApplyRowVisibility();
        _language.HandleCreated += (_, _) => ApplyRowVisibility();
        _retry.VisibleChanged += (_, _) => ApplyRowVisibility();
        _language.VisibleChanged += (_, _) => ApplyRowVisibility();

        Size = new Size(BaseWidth, BaseHeight);
        Layout1();
    }

    void StyleButton(Button b, string name, string text)
    {
        b.Name = name;
        b.Text = text;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        // Named, not inherited — and `UseVisualStyleBackColor` turned OFF,
        // which is the half that bites: with visual styles on, a focused
        // button is painted by the Windows theme in the SYSTEM ACCENT and the
        // BackColor set right above it is ignored. That is how the first CI
        // shot of this panel came back with a bright blue ✕ on a dark plate.
        b.UseVisualStyleBackColor = false;
        b.BackColor = Theme.ChromeRaised;
        b.FlatAppearance.MouseOverBackColor = Theme.Hover;
        b.FlatAppearance.MouseDownBackColor = Theme.Pressed;
        b.ForeColor = Color.White;
        b.TabStop = false;
        // The pressable cursor, set once at construction. `Enabled = false`
        // makes WinForms ignore it, which is exactly the answer we want: a
        // dead button must not offer a press.
        b.Cursor = Cursors.Hand;
    }

    /// The text box's scrollbar is drawn by the WINDOWS THEME, not by us, so
    /// on a dark plate it arrived as a light grey strip — 1864 pixels of
    /// `SystemColors.Control` the first CI run of the colour gate counted.
    /// `DarkMode_Explorer` is the documented way to ask uxtheme for the dark
    /// non-client parts of a control; it is a request, not a guarantee, which
    /// is why the gate measures the result rather than trusting the call.
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hwnd, string? app, string? id);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (_text.IsHandleCreated) SetWindowTheme(_text.Handle, "DarkMode_Explorer", null);
        ApplyRowVisibility();
    }

    /// The wish is authoritative, and it is re-checked after every write.
    ///
    /// Two WinForms facts collide here. Hiding a child before its handle
    /// exists does not stick — the native window is created later and the
    /// control comes back. And assigning `Visible` PUMPS: `ShowWindow` sends
    /// messages synchronously, so a queued continuation can run inside the
    /// assignment and change the wish half way through. A re-entrancy flag
    /// made that worse rather than better — it swallowed the nested update
    /// and left Thử lại on screen after a successful translation, which is
    /// exactly the symptom the runner kept reporting.
    ///
    /// So: no flag, and a bounded re-read instead. Whoever wrote last, the
    /// loop leaves the controls agreeing with the CURRENT wish.
    void ApplyRowVisibility()
    {
        // Not while WinForms is still settling the tree: poking `Visible` on
        // a child before this panel has a handle is what made the flag
        // unreliable in BOTH directions on the runner — Thử lại staying after
        // a success one run, missing after a failure the next. The wish is
        // kept; `OnHandleCreated` applies it once there is something to apply
        // it to.
        if (!IsHandleCreated) return;
        for (int pass = 0; pass < 4; pass++)
        {
            var retry = _retryWanted && TranslateMode;
            if (_retry.Visible == retry && _language.Visible == TranslateMode) return;
            Trace($"apply->{retry}");
            _retry.Visible = retry;
            _language.Visible = TranslateMode;
        }
    }

    public (string Code, string Label) SelectedLanguage =>
        _selected >= 0 && _selected < TranslateService.Languages.Length
            ? TranslateService.Languages[_selected]
            : TranslateService.Languages[0];

    /// The one place a language is chosen, so the button caption, the stored
    /// preference and the translation cannot disagree. Choosing the language
    /// already on screen spends nothing: it is not a change.
    void ChooseLanguage(string code)
    {
        var index = Array.FindIndex(TranslateService.Languages, l => l.Code == code);
        if (index < 0) return;
        _selected = index;
        _language.Text = SelectedLanguage.Label + "  ▾";
        if (code == _lastLanguage) return;
        _lastLanguage = code;
        LanguageChanged?.Invoke(this, code);
    }

    void ShowLanguageMenu()
    {
        if (_languages == null)
        {
            var menu = new ContextMenuStrip
            {
                Renderer = new ToolbarRenderer(),
                BackColor = Theme.ChromeRaised,
                ForeColor = Color.White,
            };
            foreach (var (code, label) in TranslateService.Languages)
            {
                var item = new ToolStripMenuItem(label) { Tag = code };
                item.Click += (_, _) => ChooseLanguage((string)item.Tag!);
                menu.Items.Add(item);
            }
            _languages = menu;
        }
        _languages.Show(_language, new Point(0, _language.Height));
    }

    /// For the gate: choosing through the same path the menu item takes.
    internal void ChooseLanguageForTesting(string code) => ChooseLanguage(code);

    /// Switches the panel between plain OCR and OCR + Translate. Called BEFORE
    /// the panel is placed, because the placement is computed from its size.
    public void SetTranslateMode(bool on)
    {
        if (TranslateMode == on) return;
        TranslateMode = on;
        if (!on) _retryWanted = false;
        ApplyRowVisibility();
        Size = new Size(BaseWidth, on ? BaseHeight + LanguageRowHeight : BaseHeight);
        Layout1();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _languages?.Dispose();
        base.Dispose(disposing);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Layout1();
    }

    /// One place that knows where the pieces sit, so a later translate row
    /// cannot drift from this one.
    void Layout1()
    {
        var scale = DeviceDpi / 96f;
        int inset = (int)(Inset * scale);
        int footer = (int)(FooterHeight * scale);
        int gap = (int)(Gap * scale);
        int closeW = (int)(32 * scale);
        int copyW = (int)(72 * scale);

        int row = TranslateMode ? (int)(LanguageRowHeight * scale) + gap : 0;
        int retryW = (int)(78 * scale);
        _text.SetBounds(
            inset, inset,
            Math.Max(0, Width - inset * 2),
            Math.Max(0, Height - inset * 2 - footer - gap - row));
        if (TranslateMode)
        {
            int rowY = Height - inset - footer - gap - (int)(LanguageRowHeight * scale);
            _language.SetBounds(
                inset, rowY,
                Math.Max(0, Width - inset * 2 - retryW - gap),
                (int)(LanguageRowHeight * scale));
            _retry.SetBounds(
                Width - inset - retryW, rowY, retryW,
                (int)(LanguageRowHeight * scale));
        }
        _copy.SetBounds(inset, Height - inset - footer, copyW, footer);
        _close.SetBounds(Width - inset - closeW, Height - inset - footer, closeW, footer);
        _status.SetBounds(
            inset + copyW + gap, Height - inset - footer,
            Math.Max(0, Width - inset * 2 - copyW - closeW - gap * 2), footer);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using var back = new SolidBrush(BackColor);
        e.Graphics.FillRectangle(back, ClientRectangle);
        using var edge = new Pen(Theme.Hairline);
        e.Graphics.DrawRectangle(edge, 0, 0, Width - 1, Height - 1);
    }

    /// Recognition runs off the UI thread, so the panel opens EMPTY and fills
    /// when the result lands. Showing nothing at all until then leaves the
    /// user staring at the shot wondering whether the drag registered.
    public void ShowRecognizing()
    {
        RecognizedText = "";
        SourceText = "";
        _retryWanted = false;
        ApplyRowVisibility();
        _text.Text = "";
        _status.Text = "Đang nhận dạng…";
        _copy.Enabled = false;
    }

    public void ShowResult(string text)
    {
        RecognizedText = text;
        SourceText = text;
        _text.Text = text;
        _text.SelectionStart = 0;
        _text.SelectionLength = 0;
        if (text.Length == 0)
        {
            _status.Text = "Không thấy chữ";
            _copy.Enabled = false;
            return;
        }
        var lines = text.Split('\n').Length;
        _status.Text = lines == 1 ? "1 dòng" : $"{lines} dòng";
        _copy.Enabled = true;
    }

    /// The recognition is shown FIRST, even in translate mode: the user gets
    /// something readable while the round trip is still out, and if it never
    /// comes back this is what stays on screen.
    public void ShowTranslating(string label)
    {
        Trace($"translating:{label}");
        _status.Text = $"Đang dịch sang {label}…";
        _retryWanted = false;
        ApplyRowVisibility();
    }

    /// Copy follows what is on screen: after a translation lands, copying the
    /// recognition would hand back the thing the user did not ask for.
    public void ShowTranslated(string text, string label)
    {
        RecognizedText = text;
        _text.Text = text;
        _text.SelectionStart = 0;
        _text.SelectionLength = 0;
        Trace($"translated:{label}");
        _status.Text = $"Đã dịch sang {label}";
        _copy.Enabled = text.Length > 0;
        _retryWanted = false;
        ApplyRowVisibility();
    }

    /// Fail OPEN: a dead network leaves the recognition on screen and
    /// copyable, with the REASON rather than a shrug, and a way to try again
    /// that does not cost another capture.
    public void ShowTranslateFailed(string reason)
    {
        RecognizedText = SourceText;
        _text.Text = SourceText;
        Trace($"failed:{reason}");
        _status.Text = reason;
        _copy.Enabled = SourceText.Length > 0;
        // Fail open, and offer the way back: a retry that costs no capture.
        _retryWanted = true;
        ApplyRowVisibility();
    }

    public void ShowFailure(string message)
    {
        _status.Text = message;
        _copy.Enabled = RecognizedText.Length > 0;
    }

    internal string StatusForTesting => _status.Text;
    internal bool CopyEnabledForTesting => _copy.Enabled;
    internal string TextForTesting => _text.Text;

    /// Every control this panel owns, by name — the list a gate walks so a
    /// control added later is covered the day it lands rather than the day
    /// someone remembers to write a probe for it.
    internal IEnumerable<Control> ControlsForTesting =>
        TranslateMode
            ? [_text, _copy, _close, _status, _language, _retry]
            : [_text, _copy, _close, _status];

    internal bool RetryVisibleForTesting => _retry.Visible;
    internal bool LanguageVisibleForTesting => _language.Visible;
}
