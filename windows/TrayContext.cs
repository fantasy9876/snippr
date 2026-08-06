namespace Snippr;

sealed class TrayContext : ApplicationContext
{
    readonly NotifyIcon _tray = new();
    readonly HotkeyWindow _hotkeys = new();
    const int HkFullscreen = 1, HkArea = 2, HkWindow = 3;

    public static TrayContext? Instance { get; private set; }

    public TrayContext()
    {
        Instance = this;
        _tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)
            ?? SystemIcons.Application;
        _tray.Text = $"Snippr {Application.ProductVersion.Split('+')[0]}";
        _tray.Visible = true;
        _tray.ContextMenuStrip = BuildMenu();
        _tray.DoubleClick += (_, _) => CaptureArea();

        _hotkeys.HotkeyPressed += OnHotkey;
        RegisterHotkeys();

        ToastForm.Show($"Snippr is running — {HotkeyUtil.Display(AppSettings.Current.HotkeyArea)} to capture");
        UpdateChecker.Check(manual: false);

        // warm the editor while the user is idle so the first capture opens fast
        var warm = new System.Windows.Forms.Timer { Interval = 800 };
        warm.Tick += (_, _) =>
        {
            warm.Stop();
            warm.Dispose();
            EditorForm.Prewarm();
        };
        warm.Start();
    }

    public void QuitApp() => Quit();

    void RegisterHotkeys()
    {
        var s = AppSettings.Current;
        Register(HkFullscreen, s.HotkeyFullscreen);
        Register(HkArea, s.HotkeyArea);
        Register(HkWindow, s.HotkeyWindow);

        void Register(int id, int combo)
        {
            if (combo == 0) return;
            var (mods, vk) = HotkeyUtil.Split(combo);
            if (!Native.RegisterHotKey(_hotkeys.Handle, id, mods, vk))
            {
                ToastForm.Show($"Hotkey {HotkeyUtil.Display(combo)} is taken by another app");
            }
        }
    }

    void UnregisterHotkeys()
    {
        Native.UnregisterHotKey(_hotkeys.Handle, HkFullscreen);
        Native.UnregisterHotKey(_hotkeys.Handle, HkArea);
        Native.UnregisterHotKey(_hotkeys.Handle, HkWindow);
    }

    /// Called by SettingsForm after the user changes hotkeys.
    public void ReloadHotkeys()
    {
        UnregisterHotkeys();
        RegisterHotkeys();
        _tray.ContextMenuStrip = BuildMenu();
    }

    ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();

        void Add(string text, Action onClick, string? shortcut = null)
        {
            var item = new ToolStripMenuItem(text) { ShortcutKeyDisplayString = shortcut };
            item.Click += (_, _) => onClick();
            menu.Items.Add(item);
        }

        var s = AppSettings.Current;
        Add("Capture Screen", CaptureFullscreen, HotkeyUtil.Display(s.HotkeyFullscreen));
        Add("Capture Area", CaptureArea, HotkeyUtil.Display(s.HotkeyArea));
        Add("Capture Active Window", CaptureWindow, HotkeyUtil.Display(s.HotkeyWindow));
        Add("Scrolling Capture", StartScrollShot);
        Add("Recognize Text (OCR)", RecognizeTextArea);
        Add("Delayed Screenshot (3s)", CaptureDelayed);
        Add("Repeat Area Capture", RepeatArea);
        menu.Items.Add(new ToolStripSeparator());
        Add("Open File…", OpenFile);
        Add("Load From Clipboard", LoadClipboard);
        menu.Items.Add(new ToolStripSeparator());
        Add("Settings…", () => new SettingsForm().ShowDialog());
        Add("Check for Updates", () => UpdateChecker.Check(manual: true));
        Add("About Snippr", () => System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo("https://snippr.pages.dev") { UseShellExecute = true }));
        menu.Items.Add(new ToolStripSeparator());
        Add("Quit", Quit);
        return menu;
    }

    void OnHotkey(int id)
    {
        switch (id)
        {
            case HkFullscreen: CaptureFullscreen(); break;
            case HkArea: CaptureArea(); break;
            case HkWindow: CaptureWindow(); break;
        }
    }

    // ---------- flows ----------

    void CaptureFullscreen() => HandleResult(CaptureUtil.ScreenUnderCursor());

    void CaptureArea()
    {
        var (shot, rect) = OverlayForm.SelectArea();
        if (shot == null) return;
        AppSettings.Current.LastArea = rect;
        AppSettings.Current.Save();
        HandleResult(shot);
    }

    void CaptureWindow()
    {
        var shot = CaptureUtil.ActiveWindow();
        if (shot == null) { ToastForm.Show("No window found"); return; }
        HandleResult(shot);
    }

    void StartScrollShot()
    {
        ScrollShotSession.Begin(bmp =>
        {
            if (bmp != null) HandleResult(bmp);
        });
    }

    void RecognizeTextArea()
    {
        var (shot, _) = OverlayForm.SelectArea();
        if (shot != null) TextResultForm.RunOcrFlow(shot);
    }

    void CaptureDelayed()
    {
        var timer = new System.Windows.Forms.Timer { Interval = 3000 };
        timer.Tick += (_, _) => { timer.Dispose(); CaptureFullscreen(); };
        timer.Start();
    }

    void RepeatArea()
    {
        if (AppSettings.Current.LastArea is not Rectangle rect)
        {
            CaptureArea();
            return;
        }
        var full = CaptureUtil.VirtualScreen(out var bounds);
        var shot = CaptureUtil.CropVirtual(full, bounds, rect);
        full.Dispose();
        HandleResult(shot);
    }

    void OpenFile()
    {
        using var dlg = new OpenFileDialog
        {
            Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tiff;*.webp",
        };
        if (dlg.ShowDialog() == DialogResult.OK)
        {
            try
            {
                using var loaded = new Bitmap(dlg.FileName);
                EditorForm.OpenWith(new Bitmap(loaded)); // detach from file lock
            }
            catch { ToastForm.Show("Could not open image"); }
        }
    }

    void LoadClipboard()
    {
        if (Clipboard.GetImage() is Image img)
        {
            EditorForm.OpenWith(new Bitmap(img));
        }
        else
        {
            ToastForm.Show("No image in clipboard");
        }
    }

    void HandleResult(Bitmap shot)
    {
        var s = AppSettings.Current;
        var actions = new List<string>();

        if (s.AfterCopy)
        {
            Clipboard.SetImage(shot);
            actions.Add("copied");
        }
        if (s.AfterSave && CaptureUtil.SaveToFolder(shot) is string path)
        {
            actions.Add($"saved {Path.GetFileName(path)}");
        }

        if (s.AfterShow)
        {
            EditorForm.OpenWith(shot);
        }
        else if (actions.Count > 0)
        {
            ToastForm.Show("Screenshot " + string.Join(" · ", actions));
            shot.Dispose();
        }
        else
        {
            Clipboard.SetImage(shot);
            ToastForm.Show("Screenshot copied to clipboard");
            shot.Dispose();
        }
    }

    void Quit()
    {
        UnregisterHotkeys();
        _hotkeys.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        Application.Exit();
    }
}
