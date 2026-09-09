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
    readonly Action<ScrollShotFinish> _onFinish;
    readonly ScrollStopMachine _stop;
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
    readonly SynchronizationContext? _sync;
    LowLevelScrollStopHook? _stopHook;
    HotkeyWindow? _hotkeyWindow;
    readonly List<int> _registeredHotkeyIds = new();
    bool _hotkeysRegistered;
    Bitmap? _probe; // reused capture buffer — no per-tick allocation
    WinStitcher? _stitcher;
    int _lastHash;

    const int MaxHeightPx = 20000;

    string StopHint => ScrollSessionStop.SessionStopHint(_hotkeysRegistered);

    public static void Begin(Action<ScrollShotFinish> onFinish)
    {
        if (_active != null) return;
        var s = AppSettings.Current;
        var snapshot = (s.AfterCopy, s.AfterShow, s.AfterSave);
        var (shot, rect) = OverlayForm.SelectArea();
        shot?.Dispose(); // only the rect is needed; frames come from the timer
        if (rect.Width < 40 || rect.Height < 60)
        {
            onFinish(new ScrollShotFinish { AfterCopy = snapshot.AfterCopy, AfterShow = snapshot.AfterShow, AfterSave = snapshot.AfterSave });
            return;
        }
        _active = new ScrollShotSession(rect, onFinish, snapshot);
    }

    /// Skip the area picker. Used by `--test-shot` on the Windows runner.
    internal static void BeginForTesting(
        Rectangle rect,
        (bool AfterCopy, bool AfterShow, bool AfterSave) snapshot,
        Action<ScrollShotFinish> onFinish)
    {
        if (_active != null)
            throw new InvalidOperationException("a scroll session is already active");
        _active = new ScrollShotSession(rect, onFinish, snapshot);
    }

    internal static ScrollShotSession? ActiveForTesting => _active;

    /// Same path as `WM_HOTKEY`: id → ForHotkeyId → ApplyStop(UiMarshals).
    internal void DeliverHotkeyForTesting(int id) => HandleSessionHotkey(id);

    void HandleSessionHotkey(int id)
    {
        if (ScrollSessionStop.ForHotkeyId(id) is { } action)
            ApplyStop(action, ScrollStopInvoke.UiMarshals);
    }

    ScrollShotSession(
        Rectangle rect,
        Action<ScrollShotFinish> onFinish,
        (bool AfterCopy, bool AfterShow, bool AfterSave) snapshot)
    {
        _rect = rect;
        _onFinish = onFinish;
        _stop = new ScrollStopMachine(snapshot.AfterCopy, snapshot.AfterShow, snapshot.AfterSave);
        _sync = SynchronizationContext.Current;
        BuildChrome();
        InstallStop();
        _label.Text = $"  Cuộn từ từ — ảnh ghép hiện bên dưới · {StopHint}";

        _timer.Interval = 180;
        _timer.Tick += (_, _) => CaptureTick();
        _timer.Start();
    }

    void InstallStop()
    {
        // Consume, not observe: focus sits in the app being scrolled, so
        // Enter/Ctrl+C/Esc must not also fire there. RegisterHotKey swallows
        // the chord (same job as macOS Carbon). A consuming LL hook fills
        // any ID that failed to register.
        _hotkeyWindow = new HotkeyWindow();
        _hotkeyWindow.HotkeyPressed += HandleSessionHotkey;
        foreach (var spec in ScrollSessionStop.Specs)
        {
            if (Native.RegisterHotKey(_hotkeyWindow.Handle, spec.Id, spec.Mods, spec.Vk))
                _registeredHotkeyIds.Add(spec.Id);
        }
        var failedIds = ScrollStopHookPolicy.FailedSpecIds(_registeredHotkeyIds);
        if (failedIds.Length > 0)
        {
            _stopHook = LowLevelScrollStopHook.TryInstall(
                ApplyStop, failedIds, Native.GetAsyncKeyState);
        }
        _hotkeysRegistered = _registeredHotkeyIds.Count > 0 || _stopHook != null;
    }

    void ApplyStop(ScrollStopAction action, bool marshal)
    {
        void go()
        {
            if (!_stop.ApplyStop(action)) return;
            End();
        }
        ScrollStopInvoke.Run(marshal, _sync, go);
    }

    void CaptureTick()
    {
        if (_stop.Flags.Finished) return;
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
            _label.Text = "  " + ScrollSessionStop.StitchingProgressText(
                _stitcher.TotalHeight, _hotkeysRegistered);
            if (_stitcher.TotalHeight >= MaxHeightPx)
                ApplyStop(ScrollStopAction.Finish, ScrollStopInvoke.UiMarshals);
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

    void End()
    {
        if (!_stop.Flags.Finished) return;
        _timer.Stop();
        _timer.Dispose();
        _stopHook?.Dispose();
        _stopHook = null;
        if (_hotkeyWindow != null)
        {
            foreach (var id in _registeredHotkeyIds)
                Native.UnregisterHotKey(_hotkeyWindow.Handle, id);
            _registeredHotkeyIds.Clear();
            _hotkeyWindow.Dispose();
            _hotkeyWindow = null;
        }
        foreach (var f in _chrome) f.Close();
        _chrome.Clear();
        _panel = null;
        _active = null;

        Bitmap? result = null;
        if (_stop.ShouldCompose)
            result = _stitcher?.Compose();
        _stitcher?.Dispose();
        _stitcher = null;
        _probe?.Dispose();
        _probe = null;
        _previewComposite?.Dispose();
        _previewComposite = null;
        _preview.Composite = null;
        _onFinish(new ScrollShotFinish
        {
            Image = result,
            Cancelled = _stop.Flags.Cancelled,
            QuickCopy = _stop.Flags.QuickCopy,
            AfterCopy = _stop.AfterCopy,
            AfterShow = _stop.AfterShow,
            AfterSave = _stop.AfterSave,
        });
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
        done.Click += (_, _) => ApplyStop(ScrollStopAction.Finish, ScrollStopInvoke.UiMarshals);
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

/// Result of a scroll session. Windows Ends on the first key, so Cancelled
/// and QuickCopy are not both set in one session (unlike macOS, where flags
/// can race before finalize).
sealed class ScrollShotFinish
{
    public Bitmap? Image;
    public bool Cancelled;
    public bool QuickCopy;
    public bool AfterCopy;
    public bool AfterShow;
    public bool AfterSave;
}

/// Low-level keyboard hook that CONSUMES matching session keys (returns 1)
/// so the scrolled app does not also submit / copy / dismiss. Installed only
/// for specs `RegisterHotKey` failed; modifiers come from GetAsyncKeyState.
sealed class LowLevelScrollStopHook : IDisposable
{
    IntPtr _hook;
    readonly Native.LowLevelKeyboardProc _proc; // field keeps the delegate alive
    readonly Action<ScrollStopAction> _onAction;
    readonly int[] _hookedIds;
    readonly Func<int, short> _getAsyncKeyState;

    LowLevelScrollStopHook(
        Action<ScrollStopAction> onAction,
        int[] hookedIds,
        Func<int, short> getAsyncKeyState)
    {
        _onAction = onAction;
        _hookedIds = hookedIds;
        _getAsyncKeyState = getAsyncKeyState;
        _proc = Callback;
    }

    /// Always binds `HookMarshals` — the caller cannot pick UiMarshals (N7w).
    public static LowLevelScrollStopHook? TryInstall(
        Action<ScrollStopAction, bool> applyStop,
        int[] hookedIds,
        Func<int, short> getAsyncKeyState)
    {
        if (hookedIds.Length == 0) return null;
        var onAction = ScrollStopInvoke.Bind(applyStop, ScrollStopInvoke.HookMarshals);
        var hook = new LowLevelScrollStopHook(onAction, hookedIds, getAsyncKeyState);
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
            uint mods = ScrollStopHookPolicy.ModsFromKeyState(_getAsyncKeyState);
            if (ScrollStopHookPolicy.Interpret((uint)vk, mods, _hookedIds) is { } action)
            {
                _onAction(action);
                return (IntPtr)1; // consume
            }
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
