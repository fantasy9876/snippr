using System.Drawing.Drawing2D;

namespace Snippr;

// ---------- toast notification ----------

sealed class ToastForm : Form
{
    static ToastForm? _current;
    readonly System.Windows.Forms.Timer _timer = new();

    public static void Show(string message)
    {
        _current?.Close();
        var t = new ToastForm(message);
        _current = t;
        t.ShowInactive();
    }

    ToastForm(string message)
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(24, 26, 31);

        var label = new Label
        {
            Text = "✓  " + message,
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
            AutoSize = true,
            Padding = new Padding(16, 10, 16, 10),
        };
        Controls.Add(label);
        Size = label.PreferredSize;

        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(wa.Left + (wa.Width - Width) / 2, wa.Bottom - Height - 48);

        using var path = Rounded(new Rectangle(Point.Empty, Size), 10);
        Region = new Region(path);

        _timer.Interval = 2200;
        _timer.Tick += (_, _) => Close();
        _timer.Start();
        FormClosed += (_, _) => { _timer.Dispose(); if (_current == this) _current = null; };
    }

    void ShowInactive()
    {
        // show without stealing focus
        Native2.ShowWindow(Handle, 4 /* SW_SHOWNOACTIVATE */);
    }

    protected override bool ShowWithoutActivation => true;

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

static class Native2
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    public const int WM_NCLBUTTONDOWN = 0xA1;
    public const int HTCAPTION = 0x2;
}

// ---------- pinned screenshot ----------

sealed class PinForm : Form
{
    readonly Bitmap _image;
    Bitmap? _scaledCache; // rebuilt once per size change; paints are cheap blits
    float _scale = 1f;

    public PinForm(Bitmap image)
    {
        _image = image;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;

        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        var size = FitSize();
        Location = new Point(wa.Left + (wa.Width - size.Width) / 2, wa.Top + (wa.Height - size.Height) / 2);
        ClientSize = size;
        KeyPreview = true;
        FormClosed += (_, _) => { _image.Dispose(); _scaledCache?.Dispose(); };
    }

    Size FitSize() => new((int)(_image.Width * _scale), (int)(_image.Height * _scale));

    protected override void OnPaint(PaintEventArgs e)
    {
        // the old path re-ran a full-resolution bicubic rescale on EVERY paint
        // (each wheel notch, each expose) — cache the scaled copy instead
        if (_scaledCache == null || _scaledCache.Size != ClientSize)
        {
            _scaledCache?.Dispose();
            var scaled = new Bitmap(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height),
                System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(scaled))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(_image, new Rectangle(Point.Empty, scaled.Size));
            }
            _scaledCache = scaled;
        }
        // explicit destination rect: cache size == ClientSize so this is a 1:1
        // blit with no DPI-dependent rescale ambiguity on mixed-DPI monitors
        e.Graphics.DrawImage(_scaledCache, ClientRectangle);
        e.Graphics.DrawRectangle(Pens.DimGray,
            new Rectangle(0, 0, ClientSize.Width - 1, ClientSize.Height - 1));
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Clicks == 2) { Close(); return; }
        if (e.Button == MouseButtons.Left)
        {
            Native2.ReleaseCapture();
            Native2.SendMessage(Handle, Native2.WM_NCLBUTTONDOWN, Native2.HTCAPTION, IntPtr.Zero);
        }
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        _scale = Math.Clamp(_scale * (e.Delta > 0 ? 1.1f : 1 / 1.1f), 0.2f, 4f);
        var center = new Point(Location.X + Width / 2, Location.Y + Height / 2);
        ClientSize = FitSize();
        Location = new Point(center.X - Width / 2, center.Y - Height / 2);
        Invalidate();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) Close();
        else if (e.Control && e.KeyCode == Keys.C)
        {
            try
            {
                Clipboard.SetImage(_image);
                ToastForm.Show("Copied to clipboard");
            }
            catch
            {
                ToastForm.Show("Clipboard đang bận — thử lại sau giây lát");
            }
        }
    }
}

// ---------- settings ----------

/// Click the box, then press a key combo (e.g. Ctrl+Alt+S). Esc clears.
sealed class HotkeyBox : TextBox
{
    public int Combo { get; set; }

    public HotkeyBox()
    {
        ReadOnly = true;
        BackColor = Color.White;
        Cursor = Cursors.Hand;
        TextAlign = HorizontalAlignment.Center;
    }

    public void RefreshText() => Text = HotkeyUtil.Display(Combo);

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        var code = keyData & Keys.KeyCode;
        if (code == Keys.Escape)
        {
            Combo = 0;
            RefreshText();
            return true;
        }
        // ignore bare modifier presses
        if (code is Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.None)
            return true;
        bool hasModifier = (keyData & (Keys.Control | Keys.Shift | Keys.Alt)) != 0;
        bool standalone = code is (>= Keys.F1 and <= Keys.F12) or Keys.PrintScreen;
        if (!hasModifier && !standalone) return true; // require a modifier (except F-keys/PrtScn)
        Combo = (int)keyData;
        RefreshText();
        return true;
    }

    // PrintScreen never generates a KeyDown message — catch it on KeyUp
    protected override void OnKeyUp(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.PrintScreen)
        {
            Combo = (int)e.KeyData;
            RefreshText();
            e.Handled = true;
            return;
        }
        base.OnKeyUp(e);
    }
}

sealed class SettingsForm : Form
{
    /// The OCR picker's order, in one place. Building the list and reading the
    /// user's choice back out used to be two hand-written switches; a preset
    /// added to one and not the other silently rewrites the choice on Save,
    /// and nothing in the UI shows it happened.
    internal static readonly (string Label, OcrLanguagePreference Pref)[] OcrChoices =
    [
        ("English+", OcrLanguagePreference.EnglishPlus),
        ("Vietnamese+", OcrLanguagePreference.VietnamesePlus),
        ("Chinese+", OcrLanguagePreference.ChinesePlus),
        ("Auto", OcrLanguagePreference.Auto),
    ];

    internal static int OcrIndexFor(OcrLanguagePreference pref)
    {
        var i = Array.FindIndex(OcrChoices, c => c.Pref == pref);
        return i < 0 ? 0 : i;
    }

    /// An out-of-range index falls back to `Auto`, matching the new default:
    /// the wrong answer to "I don't know" is a preset that silently excludes
    /// whatever script the picture is written in.
    internal static OcrLanguagePreference OcrPrefForIndex(int index) =>
        index >= 0 && index < OcrChoices.Length
            ? OcrChoices[index].Pref
            : OcrLanguagePreference.Auto;

    readonly TextBox _folder = new();
    readonly ComboBox _format = new();
    readonly CheckBox _show = new() { Text = "Show editor" };
    readonly CheckBox _copy = new() { Text = "Copy to clipboard" };
    readonly CheckBox _save = new() { Text = "Save to folder" };
    readonly CheckBox _startup = new() { Text = "Launch Snippr at startup" };
    readonly CheckBox _escCopy = new() { Text = "Esc in editor copies image, then closes" };
    readonly ComboBox _corners = new();
    readonly ComboBox _ocrLang = new();
    readonly HotkeyBox _hkFullscreen = new();
    readonly HotkeyBox _hkArea = new();
    readonly HotkeyBox _hkWindow = new();

    public SettingsForm()
    {
        Text = $"Snippr Settings — v{Application.ProductVersion.Split('+')[0]}";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(460, 518);
        Font = new Font("Segoe UI", 9.5f);

        var s = AppSettings.Current;
        int y = 20;

        Label L(string text)
        {
            var l = new Label { Text = text, Location = new Point(20, y + 3), AutoSize = true };
            Controls.Add(l);
            return l;
        }

        L("Screenshots folder");
        _folder.Text = s.SaveFolder;
        _folder.SetBounds(160, y, 210, 24);
        var browse = new Button { Text = "…", Bounds = new Rectangle(378, y - 1, 40, 26) };
        browse.Click += (_, _) =>
        {
            using var dlg = new FolderBrowserDialog { SelectedPath = _folder.Text };
            if (dlg.ShowDialog(this) == DialogResult.OK) _folder.Text = dlg.SelectedPath;
        };
        Controls.Add(_folder);
        Controls.Add(browse);
        y += 40;

        L("Save format");
        _format.DropDownStyle = ComboBoxStyle.DropDownList;
        _format.Items.AddRange(new object[] { "Auto (PNG/JPEG)", "Always PNG" });
        _format.SelectedIndex = s.Format == "png" ? 1 : 0;
        _format.SetBounds(160, y, 210, 24);
        Controls.Add(_format);
        y += 40;

        L("After screenshot");
        _show.Checked = s.AfterShow;
        _copy.Checked = s.AfterCopy;
        _save.Checked = s.AfterSave;
        _show.SetBounds(160, y, 260, 24);
        _copy.SetBounds(160, y + 26, 260, 24);
        _save.SetBounds(160, y + 52, 260, 24);
        Controls.AddRange(new Control[] { _show, _copy, _save });
        y += 92;

        _startup.Checked = s.LaunchAtStartup;
        _startup.SetBounds(160, y, 280, 24);
        Controls.Add(_startup);
        y += 30;

        _escCopy.Checked = s.EscCopy;
        _escCopy.SetBounds(160, y, 290, 24);
        Controls.Add(_escCopy);
        y += 32;

        L("Backdrop corners");
        _corners.DropDownStyle = ComboBoxStyle.DropDownList;
        _corners.Items.AddRange(new object[] { "Square", "Small", "Medium", "Large" });
        _corners.SelectedIndex = s.CornerStyle switch
        {
            BackdropCornerStyle.None => 0,
            BackdropCornerStyle.Small => 1,
            BackdropCornerStyle.Large => 3,
            _ => 2,
        };
        _corners.SetBounds(160, y, 210, 24);
        Controls.Add(_corners);
        y += 34;

        // Same four choices as macOS, same names and same order. Windows ships
        // no Vietnamese recognizer, so Vietnamese+ falls back to English and
        // the OCR flow says so — the setting is what lets someone ASK, and
        // being told is the point. Chinese+ and Auto depend on an installed
        // language pack the same way; the warning path covers both.
        L("OCR language");
        _ocrLang.DropDownStyle = ComboBoxStyle.DropDownList;
        _ocrLang.Items.AddRange(OcrChoices.Select(c => (object)c.Label).ToArray());
        _ocrLang.SelectedIndex = OcrIndexFor(s.OcrPreference);
        _ocrLang.SetBounds(160, y, 210, 24);
        Controls.Add(_ocrLang);
        y += 34;

        y += 8;
        var hotkeyHeader = new Label
        {
            Text = "Hotkeys — click a box, then press the new combo (Esc = disable)",
            Location = new Point(20, y),
            AutoSize = true,
            ForeColor = Color.Gray,
        };
        Controls.Add(hotkeyHeader);
        y += 28;

        void HotkeyRow(string label, HotkeyBox box, int combo)
        {
            L(label);
            box.Combo = combo;
            box.RefreshText();
            box.SetBounds(160, y, 160, 24);
            Controls.Add(box);
            var clear = new Button { Text = "✕", Bounds = new Rectangle(328, y - 1, 30, 26) };
            clear.Click += (_, _) => { box.Combo = 0; box.RefreshText(); };
            Controls.Add(clear);
            y += 34;
        }

        HotkeyRow("Fullscreen screenshot", _hkFullscreen, s.HotkeyFullscreen);
        HotkeyRow("Area screenshot", _hkArea, s.HotkeyArea);
        HotkeyRow("Window screenshot", _hkWindow, s.HotkeyWindow);

        var ok = new Button { Text = "Save", DialogResult = DialogResult.OK, Bounds = new Rectangle(250, 440, 80, 28) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Bounds = new Rectangle(340, 440, 80, 28) };
        AcceptButton = ok;
        CancelButton = cancel;
        Controls.Add(ok);
        Controls.Add(cancel);

        ok.Click += (_, _) => Apply();
    }

    void Apply()
    {
        var s = AppSettings.Current;
        s.SaveFolder = _folder.Text;
        s.Format = _format.SelectedIndex == 1 ? "png" : "auto";
        s.AfterShow = _show.Checked;
        s.AfterCopy = _copy.Checked;
        s.AfterSave = _save.Checked;
        s.LaunchAtStartup = _startup.Checked;
        s.EscCopy = _escCopy.Checked;
        s.BackdropCorners = _corners.SelectedIndex switch
        {
            0 => nameof(BackdropCornerStyle.None),
            1 => nameof(BackdropCornerStyle.Small),
            3 => nameof(BackdropCornerStyle.Large),
            _ => nameof(BackdropCornerStyle.Medium),
        };
        s.OcrLanguage = OcrPrefForIndex(_ocrLang.SelectedIndex).ToString();
        s.HotkeyFullscreen = _hkFullscreen.Combo;
        s.HotkeyArea = _hkArea.Combo;
        s.HotkeyWindow = _hkWindow.Combo;
        s.Save();
        ApplyStartup(s.LaunchAtStartup);
        TrayContext.Instance?.ReloadHotkeys();
    }

    static void ApplyStartup(bool enabled)
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
            if (key == null) return;
            if (enabled) key.SetValue("Snippr", $"\"{Application.ExecutablePath}\"");
            else key.DeleteValue("Snippr", throwOnMissingValue: false);
        }
        catch { }
    }
}
