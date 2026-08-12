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

    /// True while the selection overlay or a scroll session owns the screen.
    /// The modal overlay still pumps WM_HOTKEY, so without this guard a second
    /// hotkey press captured the dimmed overlay (or the scroll chrome) itself.
    static bool CaptureBusy => OverlayForm.IsActive || ScrollShotSession.IsActive;

    void OnHotkey(int id)
    {
        if (CaptureBusy) return;
        switch (id)
        {
            case HkFullscreen: CaptureFullscreen(); break;
            case HkArea: CaptureArea(); break;
            case HkWindow: CaptureWindow(); break;
        }
    }

    // ---------- flows ----------

    void CaptureFullscreen()
    {
        if (CaptureBusy) return;
        HandleResult(CaptureUtil.ScreenUnderCursor());
    }

    void CaptureArea()
    {
        if (CaptureBusy) return;
        var (shot, rect) = OverlayForm.SelectArea();
        if (shot == null) return;
        AppSettings.Current.LastArea = rect;
        AppSettings.Current.Save();
        HandleResult(shot);
    }

    void CaptureWindow()
    {
        if (CaptureBusy) return;
        var shot = CaptureUtil.ActiveWindow();
        if (shot == null) { ToastForm.Show("No window found"); return; }
        HandleResult(shot);
    }

    void StartScrollShot()
    {
        if (CaptureBusy) return;
        ScrollShotSession.Begin(bmp =>
        {
            if (bmp != null) HandleResult(bmp);
        });
    }

    void RecognizeTextArea()
    {
        if (CaptureBusy) return;
        var (shot, _) = OverlayForm.SelectArea();
        if (shot != null) TextResultForm.RunOcrFlow(shot);
    }

    void CaptureDelayed()
    {
        var timer = new System.Windows.Forms.Timer { Interval = 3000 };
        timer.Tick += (_, _) =>
        {
            // an overlay/scroll session may be up when the timer fires — retry
            // shortly instead of silently dropping the delayed shot
            if (CaptureBusy)
            {
                timer.Interval = 1000;
                return;
            }
            timer.Dispose();
            CaptureFullscreen();
        };
        timer.Start();
    }

    void RepeatArea()
    {
        if (CaptureBusy) return;
        if (AppSettings.Current.LastArea is not Rectangle rect)
        {
            CaptureArea();
            return;
        }
        // capture just the remembered rect (the old path grabbed the whole
        // virtual desktop to crop a fraction of it); null = the saved area is
        // no longer on any monitor — used to crash inside Bitmap.Clone
        if (CaptureUtil.Rect(rect) is not Bitmap shot)
        {
            ToastForm.Show("Vùng đã lưu không còn trên màn hình — chọn lại nhé");
            CaptureArea();
            return;
        }
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

    /// Clipboard.SetImage throws when another process holds the clipboard
    /// (clipboard managers, Office, RDP) — a routine condition that must not
    /// crash the app or lose the capture.
    static bool TryCopyImage(Bitmap bmp)
    {
        try
        {
            Clipboard.SetImage(bmp);
            return true;
        }
        catch
        {
            return false;
        }
    }

    void HandleResult(Bitmap shot)
    {
        var s = AppSettings.Current;
        var actions = new List<string>();
        bool preserved = false; // the shot reached the clipboard, a file, or the editor

        if (s.AfterCopy)
        {
            if (TryCopyImage(shot)) { actions.Add("copied"); preserved = true; }
            else actions.Add("clipboard busy");
        }
        if (s.AfterSave)
        {
            if (CaptureUtil.SaveToFolder(shot) is string path)
            {
                actions.Add($"saved {Path.GetFileName(path)}");
                preserved = true;
            }
            else
            {
                actions.Add("save failed"); // don't hide a partial failure
            }
        }

        if (s.AfterShow)
        {
            EditorForm.OpenWith(shot);
            return;
        }

        if (!preserved)
        {
            // every configured action failed (or none configured) — rescue the
            // shot instead of disposing it behind a toast
            if (actions.Count == 0 && TryCopyImage(shot))
            {
                ToastForm.Show("Screenshot copied to clipboard");
                shot.Dispose();
                return;
            }
            if (CaptureUtil.SaveToFolder(shot) is string saved)
            {
                ToastForm.Show($"Clipboard bận — đã lưu {Path.GetFileName(saved)}");
                shot.Dispose();
                return;
            }
            // absolute last resort: clipboard AND disk failed — open the
            // editor so the capture is never destroyed with no artifact
            ToastForm.Show("Không copy/lưu được — mở editor");
            EditorForm.OpenWith(shot);
            return;
        }

        ToastForm.Show("Screenshot " + string.Join(" · ", actions));
        shot.Dispose();
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
