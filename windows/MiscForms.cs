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
        FormClosed += (_, _) => _image.Dispose();
    }

    Size FitSize() => new((int)(_image.Width * _scale), (int)(_image.Height * _scale));

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        e.Graphics.DrawImage(_image, ClientRectangle);
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
            Clipboard.SetImage(_image);
            ToastForm.Show("Copied to clipboard");
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
        bool isFKey = code is >= Keys.F1 and <= Keys.F12;
        if (!hasModifier && !isFKey) return true; // require a modifier (except F-keys)
        Combo = (int)keyData;
        RefreshText();
        return true;
    }
}

sealed class SettingsForm : Form
{
    readonly TextBox _folder = new();
    readonly ComboBox _format = new();
    readonly CheckBox _show = new() { Text = "Show editor" };
    readonly CheckBox _copy = new() { Text = "Copy to clipboard" };
    readonly CheckBox _save = new() { Text = "Save to folder" };
    readonly CheckBox _startup = new() { Text = "Launch Snippr at startup" };
    readonly HotkeyBox _hkFullscreen = new();
    readonly HotkeyBox _hkArea = new();
    readonly HotkeyBox _hkWindow = new();

    public SettingsForm()
    {
        Text = "Snippr Settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(460, 484);
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
        y += 36;

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
