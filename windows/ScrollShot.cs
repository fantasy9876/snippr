using System.Drawing.Imaging;

namespace Snippr;

/// Manual scroll shot (Lark-style): the user scrolls the content themselves;
/// a timer watches the selected area and stitches every new frame. All chrome
/// is excluded from screen capture (SetWindowDisplayAffinity) and positioned
/// outside the capture rect whenever the layout allows, so it can never leak
/// into the result.
sealed class ScrollShotSession
{
    static ScrollShotSession? _active;

    /// True while a scroll session runs — lets hotkey handlers refuse
    /// re-entrant captures that would photograph our own chrome.
    public static bool IsActive => _active != null;

    readonly Rectangle _rect; // virtual-screen coords
    readonly Action<Bitmap?> _onFinish;
    readonly List<Form> _chrome = new();
    Form? _panel;
    bool _panelOverlapsRect;
    readonly Label _label = new()
    {
        AutoSize = false,
        TextAlign = ContentAlignment.MiddleLeft,
        ForeColor = Color.White,
        Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
    };
    readonly System.Windows.Forms.Timer _timer = new();
    LowLevelEscHook? _escHook;
    HotkeyWindow? _escHotkeyWindow;
    bool _escAvailable;
    Bitmap? _probe; // reused capture buffer — no per-tick allocation
    WinStitcher? _stitcher;
    int _lastHash;
    bool _finished;

    const int EscId = 99;
    const int MaxHeightPx = 20000;

    string StopHint => _escAvailable ? "✓ / Esc để xong" : "bấm ✓ để xong";

    public static void Begin(Action<Bitmap?> onFinish)
    {
        if (_active != null) return;
        var (shot, rect) = OverlayForm.SelectArea();
        shot?.Dispose(); // only the rect is needed; frames come from the timer
        if (rect.Width < 40 || rect.Height < 60)
        {
            onFinish(null);
            return;
        }
        _active = new ScrollShotSession(rect, onFinish);
    }

    ScrollShotSession(Rectangle rect, Action<Bitmap?> onFinish)
    {
        _rect = rect;
        _onFinish = onFinish;
        BuildChrome();

        // Preferred stop signal: a low-level keyboard hook that OBSERVES Esc
        // without consuming it, so the app the user is scrolling still gets
        // the keypress. Falls back to a global hotkey (which does consume Esc)
        // only when the hook can't be installed.
        var sync = SynchronizationContext.Current;
        _escHook = LowLevelEscHook.TryInstall(() =>
        {
            if (sync != null) sync.Post(_ => Finish(), null);
            else Finish();
        });
        if (_escHook != null)
        {
            _escAvailable = true;
        }
        else
        {
            _escHotkeyWindow = new HotkeyWindow();
            _escHotkeyWindow.HotkeyPressed += id => { if (id == EscId) Finish(); };
            _escAvailable = Native.RegisterHotKey(_escHotkeyWindow.Handle, EscId, 0, 0x1B /* VK_ESCAPE */);
        }
        _label.Text = $"  Cuộn từ từ — ảnh ghép hiện bên dưới · {StopHint}";

        _timer.Interval = 180;
        _timer.Tick += (_, _) => CaptureTick();
        _timer.Start();
    }

    void CaptureTick()
    {
        if (_finished) return;
        _probe ??= new Bitmap(_rect.Width, _rect.Height, PixelFormat.Format24bppRgb);

        // Last-resort safety: when the panel had to overlap the rect (tiny
        // working area) hide it around the blit — SetWindowDisplayAffinity
        // behaviour under plain BitBlt capture is not guaranteed on every
        // Windows build. ShowWindow with SW_SHOWNOACTIVATE so the panel never
        // steals focus from the app the user is scrolling.
        bool hidePanel = _panel != null && _panelOverlapsRect;
        if (hidePanel) Native2.ShowWindow(_panel!.Handle, 0 /* SW_HIDE */);
        using (var g = Graphics.FromImage(_probe))
        {
            g.CopyFromScreen(_rect.X, _rect.Y, 0, 0, _rect.Size);
        }
        if (hidePanel) Native2.ShowWindow(_panel!.Handle, 4 /* SW_SHOWNOACTIVATE */);

        int hash = WinStitcher.QuickHash(_probe);
        if (hash == _lastHash) return; // unchanged — probe is reused, nothing allocated
        _lastHash = hash;

        var bmp = _probe.Clone(new Rectangle(Point.Empty, _probe.Size), PixelFormat.Format24bppRgb);
        if (_stitcher == null)
        {
            _stitcher = new WinStitcher(bmp);
            AddPreviewSlice(bmp);
            _label.Text = $"  Cuộn từ từ — ảnh ghép hiện bên dưới · {StopHint}";
        }
        else if (_stitcher.Append(bmp))
        {
            AddPreviewSlice(_stitcher.LastSlice);
            _label.Text = $"  Đã ghép {_stitcher.TotalHeight}px — {StopHint}";
            if (_stitcher.TotalHeight >= MaxHeightPx) Finish();
        }
        else
        {
            _label.Text = "  Chưa khớp được — cuộn chậm lại một chút";
            bmp.Dispose();
        }
    }

    // ----- live preview: the user watches the stitched page grow -----
    // Rolling window: only the most recent PreviewMaxHeight rows are kept,
    // matching what the bottom-aligned panel can show. O(1) per frame instead
    // of recompositing every slice captured so far.

    const int PreviewWidth = 200;
    const int PreviewMaxHeight = 1200;
    Bitmap? _previewComposite;
    readonly ScrollPreviewControl _preview = new();

    void AddPreviewSlice(Bitmap? slice)
    {
        if (slice == null) return;
        float sc = PreviewWidth / (float)slice.Width;
        int h = Math.Max(1, (int)(slice.Height * sc));
        using var scaled = new Bitmap(PreviewWidth, h);
        using (var g = Graphics.FromImage(scaled))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
            g.DrawImage(slice, new Rectangle(0, 0, PreviewWidth, h));
        }

        int prevH = _previewComposite?.Height ?? 0;
        int newH = Math.Min(PreviewMaxHeight, prevH + h);
        var composite = new Bitmap(PreviewWidth, newH);
        using (var g = Graphics.FromImage(composite))
        {
            // newest slice at the bottom; older content above, clipped at the top
            int sliceY = newH - h;
            if (_previewComposite != null)
                g.DrawImageUnscaled(_previewComposite, 0, sliceY - prevH);
            g.DrawImageUnscaled(scaled, 0, sliceY);
        }
        _previewComposite?.Dispose();
        _previewComposite = composite;
        _preview.Composite = composite;
        _preview.Invalidate();
    }

    void Finish()
    {
        if (_finished) return;
        _finished = true;
        _timer.Stop();
        _timer.Dispose();
        _escHook?.Dispose();
        _escHook = null;
        if (_escHotkeyWindow != null)
        {
            Native.UnregisterHotKey(_escHotkeyWindow.Handle, EscId);
            _escHotkeyWindow.Dispose();
            _escHotkeyWindow = null;
        }
        foreach (var f in _chrome) f.Close();
        _chrome.Clear();
        _panel = null;
        _active = null;

        var result = _stitcher?.Compose();
        _stitcher?.Dispose();
        _stitcher = null;
        _probe?.Dispose();
        _probe = null;
        _previewComposite?.Dispose();
        _previewComposite = null;
        _preview.Composite = null;
        _onFinish(result);
    }

    void BuildChrome()
    {
        Form Strip(int x, int y, int w, int h)
        {
            var f = new Form
            {
                FormBorderStyle = FormBorderStyle.None,
                StartPosition = FormStartPosition.Manual,
                ShowInTaskbar = false,
                TopMost = true,
                BackColor = Color.DodgerBlue,
                Bounds = new Rectangle(x, y, Math.Max(1, w), Math.Max(1, h)),
            };
            f.Show();
            _chrome.Add(f);
            return f;
        }

        const int t = 3; // strip thickness, fully outside the capture rect
        Strip(_rect.X - t, _rect.Y - t, _rect.Width + t * 2, t);          // top
        Strip(_rect.X - t, _rect.Bottom, _rect.Width + t * 2, t);         // bottom
        Strip(_rect.X - t, _rect.Y, t, _rect.Height);                     // left
        Strip(_rect.Right, _rect.Y, t, _rect.Height);                     // right

        // live preview panel beside the area — the user watches the stitched
        // page grow while scrolling ("vừa chụp vừa xem")
        var wa = Screen.FromRectangle(_rect).WorkingArea;
        var (panelBounds, overlaps) = PickPanelPlacement(wa);
        _panelOverlapsRect = overlaps;
        int panelW = panelBounds.Width;
        int panelH = panelBounds.Height;

        var panel = new Form
        {
            FormBorderStyle = FormBorderStyle.None,
            StartPosition = FormStartPosition.Manual,
            ShowInTaskbar = false,
            TopMost = true,
            BackColor = Color.FromArgb(24, 26, 31),
            Bounds = panelBounds,
        };
        _label.Bounds = new Rectangle(6, 6, panelW - 12, 40);
        var done = new Button
        {
            Text = "✓ Xong",
            ForeColor = Color.White,
            BackColor = Color.FromArgb(0, 120, 212),
            FlatStyle = FlatStyle.Flat,
            Bounds = new Rectangle(10, 50, 92, 30),
            Font = new Font("Segoe UI", 10f, FontStyle.Bold),
        };
        done.FlatAppearance.BorderSize = 0;
        done.Click += (_, _) => Finish();
        _preview.Bounds = new Rectangle(10, 88, panelW - 20, panelH - 98);
        panel.Controls.Add(_label);
        panel.Controls.Add(done);
        panel.Controls.Add(_preview);
        panel.Show();
        _chrome.Add(panel);
        _panel = panel;

        // Exclude every chrome window from screen capture (best effort — the
        // overlap case additionally hides the panel around each blit, since
        // affinity behaviour under plain BitBlt varies across Windows builds).
        foreach (var f in _chrome)
        {
            Native.SetWindowDisplayAffinity(f.Handle, Native.WDA_EXCLUDEFROMCAPTURE);
        }
    }

    /// Panel placement cascade: right of the rect → left → another monitor →
    /// below → above → (true last resort) overlapping but fully on-screen.
    /// The overlap case is flagged so CaptureTick hides the panel around each
    /// blit — it must never end up inside the stitched output.
    (Rectangle bounds, bool overlaps) PickPanelPlacement(Rectangle wa)
    {
        const int t = 3, gap = 14, w = 230, minH = 220;
        int h = Math.Min((int)(wa.Height * 0.72), 580);
        int y = Math.Clamp(_rect.Y - t, wa.Top + 8, Math.Max(wa.Top + 8, wa.Bottom - h - 8));

        int right = _rect.Right + t + gap;
        if (right + w <= wa.Right - 8)
            return (new Rectangle(right, y, w, h), false);

        int left = _rect.X - t - w - gap;
        if (left >= wa.Left + 8)
            return (new Rectangle(left, y, w, h), false);

        foreach (var screen in Screen.AllScreens)
        {
            var other = screen.WorkingArea;
            if (other.IntersectsWith(Rectangle.Inflate(_rect, t + gap, t + gap))) continue;
            // size against the OTHER screen's working area — a panel sized for
            // the capture screen can overhang a shorter secondary monitor
            int oh = Math.Min(Math.Min(h, (int)(other.Height * 0.72)), other.Height - 16);
            int oy = Math.Clamp(y, other.Top + 8, Math.Max(other.Top + 8, other.Bottom - oh - 8));
            return (new Rectangle(Math.Max(other.Left + 8, other.Right - w - 8), oy, w, oh), false);
        }

        int x = Math.Clamp(_rect.X, wa.Left + 8, Math.Max(wa.Left + 8, wa.Right - w - 8));
        int below = wa.Bottom - 8 - (_rect.Bottom + t + gap);
        if (below >= minH)
            return (new Rectangle(x, _rect.Bottom + t + gap, w, Math.Min(h, below)), false);

        int above = (_rect.Y - t - gap) - (wa.Top + 8);
        if (above >= minH)
        {
            int h2 = Math.Min(h, above);
            return (new Rectangle(x, _rect.Y - t - gap - h2, w, h2), false);
        }

        int lastX = Math.Max(wa.Left + 8, Math.Min(right, wa.Right - w - 8));
        return (new Rectangle(lastX, y, w, h), true);
    }
}

/// Low-level keyboard hook that fires on Esc WITHOUT consuming the keystroke,
/// so the application being scrolled still receives it.
sealed class LowLevelEscHook : IDisposable
{
    IntPtr _hook;
    readonly Native.LowLevelKeyboardProc _proc; // field keeps the delegate alive
    readonly Action _onEsc;

    LowLevelEscHook(Action onEsc)
    {
        _onEsc = onEsc;
        _proc = Callback;
    }

    public static LowLevelEscHook? TryInstall(Action onEsc)
    {
        var hook = new LowLevelEscHook(onEsc);
        hook._hook = Native.SetWindowsHookExW(
            Native.WH_KEYBOARD_LL, hook._proc, Native.GetModuleHandleW(null), 0);
        return hook._hook != IntPtr.Zero ? hook : null;
    }

    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (wParam == (IntPtr)Native.WM_KEYDOWN
            || wParam == (IntPtr)Native.WM_SYSKEYDOWN))
        {
            int vk = System.Runtime.InteropServices.Marshal.ReadInt32(lParam);
            if (vk == 0x1B /* VK_ESCAPE */) _onEsc();
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }
}

/// Shows the stitched page scaled to the panel width, pinned to the bottom
/// so the newest content is always visible.
sealed class ScrollPreviewControl : Control
{
    public Bitmap? Composite;

    public ScrollPreviewControl()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
            | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Color.FromArgb(24, 26, 31));
        if (Composite == null)
        {
            using var f = new Font("Segoe UI", 9f);
            g.DrawString("Chờ khung hình đầu tiên…", f, Brushes.Gray, 4, Height / 2f);
            return;
        }
        float sc = Width / (float)Composite.Width;
        int dh = Math.Max(1, (int)(Composite.Height * sc));
        int y = Height - dh; // bottom-aligned: newest slice always on screen
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
        g.DrawImage(Composite, new Rectangle(0, y, Width, dh));
        using var pen = new Pen(Color.FromArgb(90, Color.White));
        g.DrawRectangle(pen, 0, Math.Max(0, y), Width - 1, Math.Min(dh, Height) - 1);
    }
}

