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

/// Vertical stitcher (GDI+, top-left origin). Frames that can't be matched
/// confidently are rejected rather than guessed. Mirrors the macOS
/// VerticalStitcher constant-for-constant (Windows runs at scale 1).
sealed class WinStitcher : IDisposable
{
    readonly List<Bitmap> _slices = new();
    Bitmap _lastFrame;
    bool _ownsLastFrame; // first frame is owned by _slices, later ones by us
    Signatures? _lastSig; // cached signatures of _lastFrame
    Signatures? _firstSig; // reference for validating a claimed sticky footer
    public int Width { get; }
    public int TotalHeight { get; private set; }

    /// Sticky rows detected at the bottom of the viewport (fixed footer/chat
    /// bar). LATCHED on the first accepted append and constant for the whole
    /// session — per-pair estimates flap (blinking cursor in the bar) and
    /// slicing frames with different footer values baked bar fragments into
    /// the page mid-seam. Compose() re-attaches the footer once at the end.
    public int FooterRows { get; private set; }
    bool _footerLatched;

    public WinStitcher(Bitmap first)
    {
        _slices.Add(first);
        _lastFrame = first;
        _ownsLastFrame = false;
        Width = first.Width;
        TotalHeight = first.Height;
    }

    /// Most recently appended slice — consumed by the live preview.
    public Bitmap? LastSlice { get; private set; }

    public bool Append(Bitmap next)
    {
        if (next.Width != Width || next.Height != _lastFrame.Height) return false;
        var nextSig = RowSignatures(next);
        if (nextSig == null) return false;
        if (_lastSig == null)
        {
            _lastSig = RowSignatures(_lastFrame); // cache: rejected ticks must not redo this
            if (_lastSig == null) return false;
        }
        var prevSig = _lastSig;
        _firstSig ??= prevSig; // prev of the 1st append IS frame #1

        var match = FindOverlap(prevSig.Value, nextSig.Value, next.Height,
            _footerLatched ? FooterRows : null);
        if (match is not (int offset, int pairFooter)) return false;
        int footer = _footerLatched ? FooterRows : pairFooter;

        // A true sticky footer stays identical to the FIRST frame's bottom
        // band all session. Pitch-aligned scrolling content that merely
        // matched the previous frame drifts away from it — reject the frame
        // instead of silently dropping/duplicating page rows.
        if (footer > 0 && _firstSig is Signatures first)
        {
            int stable = 0;
            for (int y = next.Height - footer; y < next.Height; y++)
            {
                int b = y * 4;
                double d = (Math.Abs(first.Bands[b] - nextSig.Value.Bands[b])
                    + Math.Abs(first.Bands[b + 1] - nextSig.Value.Bands[b + 1])
                    + Math.Abs(first.Bands[b + 2] - nextSig.Value.Bands[b + 2])
                    + Math.Abs(first.Bands[b + 3] - nextSig.Value.Bands[b + 3])) / 4;
                if (d < 2.0) stable++; // tolerates a blinking cursor row
            }
            if (stable * 10 < footer * 7) return false; // <70% unchanged
        }

        int contentHeight = next.Height - footer;
        int rows = Math.Min(offset, contentHeight);
        if (rows <= 0) return false;
        // new content sits just above the (possibly empty) footer band
        var slice = next.Clone(
            new Rectangle(0, contentHeight - rows, Width, rows), next.PixelFormat);
        _slices.Add(slice);
        LastSlice = slice;
        TotalHeight += rows;
        FooterRows = footer;
        _footerLatched = true;

        if (_ownsLastFrame) _lastFrame.Dispose();
        _lastFrame = next;
        _ownsLastFrame = true;
        _lastSig = nextSig;
        return true;
    }

    public Bitmap Compose()
    {
        // A detected sticky footer was excluded from every appended slice, but
        // the FIRST frame still carries it — move it to the end of the page.
        Bitmap? trimmedFirst = null, footerBand = null;
        if (FooterRows > 0 && _slices.Count > 1
            && _slices[0].Height > FooterRows && _lastFrame.Height > FooterRows)
        {
            trimmedFirst = _slices[0].Clone(
                new Rectangle(0, 0, Width, _slices[0].Height - FooterRows), _slices[0].PixelFormat);
            footerBand = _lastFrame.Clone(
                new Rectangle(0, _lastFrame.Height - FooterRows, Width, FooterRows), _lastFrame.PixelFormat);
        }

        var result = new Bitmap(Width, TotalHeight, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(result))
        {
            int y = 0;
            for (int i = 0; i < _slices.Count; i++)
            {
                var s = i == 0 && trimmedFirst != null ? trimmedFirst : _slices[i];
                g.DrawImageUnscaled(s, 0, y);
                y += s.Height;
            }
            if (footerBand != null)
            {
                g.DrawImageUnscaled(footerBand, 0, y);
            }
        }
        trimmedFirst?.Dispose();
        footerBand?.Dispose();
        return result;
    }

    public void Dispose()
    {
        foreach (var s in _slices) s.Dispose();
        _slices.Clear();
        if (_ownsLastFrame) _lastFrame.Dispose();
        LastSlice = null;
        _lastSig = null;
    }

    /// Safeguards mirror the macOS matcher: 4-band row signatures, detail
    /// weighting, static-bottom (sticky footer) detection, and a two-pass
    /// uniqueness margin (the old single-pass second-best tracking was
    /// order-dependent: a chain of small improvements could swallow a real
    /// alias and accept a wrong offset on periodic content).
    static (int offset, int footer)? FindOverlap(Signatures prevS, Signatures nextS, int h,
        int? lockedFooter = null)
    {
        const int minHeight = 40;
        if (h <= minHeight) return null;
        if (prevS.Bands.Length != h * 4 || nextS.Bands.Length != h * 4) return null;

        // Per-row difference at offset 0: identifies rows that did NOT move.
        var rowDiff = new double[h];
        int changedRows = 0;
        const double changeEps = 1.5;
        for (int y = 0; y < h; y++)
        {
            int b = y * 4;
            double d = (Math.Abs(prevS.Bands[b] - nextS.Bands[b])
                + Math.Abs(prevS.Bands[b + 1] - nextS.Bands[b + 1])
                + Math.Abs(prevS.Bands[b + 2] - nextS.Bands[b + 2])
                + Math.Abs(prevS.Bands[b + 3] - nextS.Bands[b + 3])) / 4;
            rowDiff[y] = d;
            if (d > changeEps) changedRows++;
        }
        if (changedRows <= h / 20) return null; // essentially identical frames

        // Trailing static run at the bottom = sticky footer candidate. Once
        // the session latched a footer, that value is used verbatim so every
        // slice is cut with the same geometry.
        int footer;
        if (lockedFooter is int locked)
        {
            footer = Math.Min(locked, h / 3);
        }
        else
        {
            // Trailing static run, allowed to bridge ONE small dynamic band
            // (a blinking cursor / spinner inside the sticky bar would
            // otherwise truncate the detected footer on half the frame pairs).
            const double staticEps = 0.8;
            const int maxGap = 8;
            int limit = h / 3;
            footer = 0;
            int i = 0;
            bool gapUsed = false;
            while (i < limit)
            {
                if (rowDiff[h - 1 - i] < staticEps)
                {
                    i++;
                    footer = i;
                    continue;
                }
                int gap = 0;
                while (i + gap < limit && gap < maxGap && rowDiff[h - 1 - i - gap] >= staticEps)
                    gap++;
                if (!gapUsed && gap < maxGap && i + gap < limit && rowDiff[h - 1 - i - gap] < staticEps)
                {
                    gapUsed = true;
                    i += gap;
                    continue;
                }
                break;
            }
            const int minFooter = 6;
            if (footer < minFooter) footer = 0;
        }

        int hEff = h - footer;
        if (hEff <= minHeight) return null;

        int k = Math.Max(32, hEff / 4);
        if (hEff - k < 1) return null;

        var weights = new double[k];
        double weightSum = 0;
        for (int i = 0; i < k; i++)
        {
            double w = Math.Max(prevS.Energy[hEff - k + i], 0.5);
            weights[i] = w;
            weightSum += w;
        }
        if (weightSum <= 0) return null;

        // Pass 1: score every offset.
        int count = hEff - k + 1;
        var scores = new double[count];
        int bestOffset = -1;
        double bestScore = double.MaxValue;
        for (int s = 0; s < count; s++)
        {
            int start = hEff - k - s;
            double diff = 0;
            for (int i = 0; i < k; i++)
            {
                int a = (hEff - k + i) * 4;
                int b = (start + i) * 4;
                double d = (Math.Abs(prevS.Bands[a] - nextS.Bands[b])
                    + Math.Abs(prevS.Bands[a + 1] - nextS.Bands[b + 1])
                    + Math.Abs(prevS.Bands[a + 2] - nextS.Bands[b + 2])
                    + Math.Abs(prevS.Bands[a + 3] - nextS.Bands[b + 3])) / 4;
                diff += weights[i] * d;
            }
            diff /= weightSum;
            scores[s] = diff;
            if (diff < bestScore)
            {
                bestScore = diff;
                bestOffset = s;
            }
        }

        // Pass 2: runner-up must sit OUTSIDE the winner's plateau.
        const int exclusion = 6;
        double secondScore = double.MaxValue;
        for (int s = 0; s < count; s++)
        {
            if (Math.Abs(s - bestOffset) > exclusion && scores[s] < secondScore)
                secondScore = scores[s];
        }

        // ratio uniqueness (true overlap ≈ 0.0, line-pitch aliases ~0.4–2)
        // with an absolute-gap fallback for pages with animation noise
        if (bestOffset <= 0 || bestScore >= 2.0) return null;
        // no offsets outside the winner's plateau = zero uniqueness evidence
        // (tiny effective heights after footer subtraction) — don't guess
        if (secondScore == double.MaxValue) return null;
        bool unique = secondScore > bestScore * 3 + 0.15
            || secondScore - bestScore > 2.5;
        return unique ? (bestOffset, footer) : null;
    }

    readonly record struct Signatures(double[] Bands, double[] Energy);

    /// Per-row: mean gray of 4 horizontal bands + horizontal gradient energy.
    /// Gray uses Rec.601 luma (matching the macOS port's luminance-based gray)
    /// so the shared tuned thresholds mean the same thing on both platforms.
    static unsafe Signatures? RowSignatures(Bitmap bmp)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int w = bmp.Width, h = bmp.Height;
            int bandWidth = Math.Max(1, w / 4);
            int colStride = Math.Max(1, bandWidth / 24);
            var bands = new double[h * 4];
            var energy = new double[h];
            byte* basePtr = (byte*)data.Scan0;
            for (int y = 0; y < h; y++)
            {
                byte* row = basePtr + y * data.Stride;
                int grad = 0, gradCount = 0;
                for (int band = 0; band < 4; band++)
                {
                    int x0 = band * bandWidth;
                    int x1 = band == 3 ? w : (band + 1) * bandWidth;
                    int sum = 0, count = 0, prevPx = -1;
                    for (int x = x0; x < x1; x += colStride)
                    {
                        byte* px = row + x * 3; // 24bpp BGR
                        int g = (77 * px[2] + 150 * px[1] + 29 * px[0]) >> 8;
                        sum += g;
                        count++;
                        if (prevPx >= 0) { grad += Math.Abs(g - prevPx); gradCount++; }
                        prevPx = g;
                    }
                    bands[y * 4 + band] = (double)sum / Math.Max(1, count);
                }
                energy[y] = (double)grad / Math.Max(1, gradCount);
            }
            return new Signatures(bands, energy);
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }

    public static unsafe int QuickHash(Bitmap bmp)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int total = data.Stride * bmp.Height;
            int step = Math.Max(1, total / 4096);
            byte* p = (byte*)data.Scan0;
            var hash = new HashCode();
            for (int i = 0; i < total; i += step)
            {
                hash.Add(p[i]);
            }
            return hash.ToHashCode();
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }
}
