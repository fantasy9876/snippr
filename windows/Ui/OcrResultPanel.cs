using System.Drawing;

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

    /// DIP, mirroring macOS `OverlayOCRPanel.size` (300×176).
    public const int BaseWidth = 300;
    public const int BaseHeight = 176;
    const int Inset = 10;
    const int FooterHeight = 26;
    const int Gap = 8;

    readonly TextBox _text = new();
    readonly Button _copy = new();
    readonly Button _close = new();
    readonly Label _status = new();

    /// What Copy would put on the clipboard. Held here rather than read back
    /// out of the TextBox so a later translation can replace it without the
    /// panel having to guess which of the two the user meant.
    public string RecognizedText { get; private set; } = "";

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

        Size = new Size(BaseWidth, BaseHeight);
        Layout1();
    }

    void StyleButton(Button b, string name, string text)
    {
        b.Name = name;
        b.Text = text;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.BackColor = Theme.ChromeRaised;
        b.ForeColor = Color.White;
        b.TabStop = false;
        // The pressable cursor, set once at construction. `Enabled = false`
        // makes WinForms ignore it, which is exactly the answer we want: a
        // dead button must not offer a press.
        b.Cursor = Cursors.Hand;
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

        _text.SetBounds(
            inset, inset,
            Math.Max(0, Width - inset * 2),
            Math.Max(0, Height - inset * 2 - footer - gap));
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
        _text.Text = "";
        _status.Text = "Đang nhận dạng…";
        _copy.Enabled = false;
    }

    public void ShowResult(string text)
    {
        RecognizedText = text;
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
        [_text, _copy, _close, _status];
}
