using System.Drawing.Imaging;

namespace Snippr;

/// Manual scroll shot (Lark-style): the user scrolls the content themselves;
/// a timer watches the selected area and stitches every new frame. All chrome
/// (border strips + control bar) sits OUTSIDE the capture rect, so it can
/// never leak into the result.
sealed class ScrollShotSession
{
    static ScrollShotSession? _active;

    readonly Rectangle _rect; // virtual-screen coords
    readonly Action<Bitmap?> _onFinish;
    readonly List<Form> _chrome = new();
    readonly Label _label = new()
    {
        AutoSize = false,
        TextAlign = ContentAlignment.MiddleLeft,
        ForeColor = Color.White,
        Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
    };
    readonly System.Windows.Forms.Timer _timer = new();
    readonly HotkeyWindow _esc = new();
    WinStitcher? _stitcher;
    int _lastHash;
    bool _finished;

    const int EscId = 99;
    const int MaxHeightPx = 20000;

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

        _esc.HotkeyPressed += id => { if (id == EscId) Finish(); };
        Native.RegisterHotKey(_esc.Handle, EscId, 0, 0x1B /* VK_ESCAPE */);

        _timer.Interval = 180;
        _timer.Tick += (_, _) => CaptureTick();
        _timer.Start();
    }

    void CaptureTick()
    {
        if (_finished) return;
        var bmp = new Bitmap(_rect.Width, _rect.Height, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(_rect.X, _rect.Y, 0, 0, _rect.Size);
        }
        int hash = WinStitcher.QuickHash(bmp);
        if (hash == _lastHash)
        {
            bmp.Dispose();
            return;
        }
        _lastHash = hash;

        if (_stitcher == null)
        {
            _stitcher = new WinStitcher(bmp);
            AddPreviewSlice(bmp);
            _label.Text = "  Cuộn từ từ — ảnh ghép hiện bên dưới";
        }
        else if (_stitcher.Append(bmp))
        {
            AddPreviewSlice(_stitcher.LastSlice);
            _label.Text = $"  Đã ghép {_stitcher.TotalHeight}px — ✓ / Esc để xong";
            if (_stitcher.TotalHeight >= MaxHeightPx) Finish();
        }
        else
        {
            _label.Text = "  Chưa khớp được — cuộn chậm lại một chút";
            bmp.Dispose();
        }
    }

    // ----- live preview: the user watches the stitched page grow -----

    const int PreviewWidth = 200;
    readonly List<Bitmap> _previewSlices = new();
    Bitmap? _previewComposite;
    readonly ScrollPreviewControl _preview = new();

    void AddPreviewSlice(Bitmap? slice)
    {
        if (slice == null) return;
        float sc = PreviewWidth / (float)slice.Width;
        int h = Math.Max(1, (int)(slice.Height * sc));
        var scaled = new Bitmap(PreviewWidth, h);
        using (var g = Graphics.FromImage(scaled))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
            g.DrawImage(slice, new Rectangle(0, 0, PreviewWidth, h));
        }
        _previewSlices.Add(scaled);

        int total = 0;
        foreach (var s in _previewSlices) total += s.Height;
        var composite = new Bitmap(PreviewWidth, total);
        using (var g = Graphics.FromImage(composite))
        {
            int y = 0;
            foreach (var s in _previewSlices)
            {
                g.DrawImageUnscaled(s, 0, y);
                y += s.Height;
            }
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
        Native.UnregisterHotKey(_esc.Handle, EscId);
        _esc.Dispose();
        foreach (var f in _chrome) f.Close();
        _chrome.Clear();
        _active = null;
        _onFinish(_stitcher?.Compose());
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
        int panelW = 230;
        int panelH = Math.Min((int)(wa.Height * 0.72), 580);
        int panelX = _rect.Right + t + 14;
        if (panelX + panelW > wa.Right - 8) panelX = _rect.X - t - panelW - 14;
        panelX = Math.Max(panelX, wa.Left + 8);
        int panelY = Math.Clamp(_rect.Y - t, wa.Top + 8, wa.Bottom - panelH - 8);

        var panel = new Form
        {
            FormBorderStyle = FormBorderStyle.None,
            StartPosition = FormStartPosition.Manual,
            ShowInTaskbar = false,
            TopMost = true,
            BackColor = Color.FromArgb(24, 26, 31),
            Bounds = new Rectangle(panelX, panelY, panelW, panelH),
        };
        _label.Bounds = new Rectangle(6, 6, panelW - 12, 40);
        _label.Text = "  Cuộn từ từ — ảnh ghép hiện bên dưới";
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
/// confidently are rejected rather than guessed.
sealed class WinStitcher
{
    readonly List<Bitmap> _slices = new();
    Bitmap _lastFrame;
    bool _ownsLastFrame; // first frame is owned by _slices, later ones by us
    public int Width { get; }
    public int TotalHeight { get; private set; }

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
        if (next.Width != Width) return false;
        var offset = FindOverlap(_lastFrame, next);
        if (offset is not int rows || rows <= 0) return false;

        rows = Math.Min(rows, next.Height);
        var slice = next.Clone(
            new Rectangle(0, next.Height - rows, Width, rows), next.PixelFormat);
        _slices.Add(slice);
        LastSlice = slice;
        TotalHeight += rows;

        if (_ownsLastFrame) _lastFrame.Dispose();
        _lastFrame = next;
        _ownsLastFrame = true;
        return true;
    }

    public Bitmap Compose()
    {
        var result = new Bitmap(Width, TotalHeight, PixelFormat.Format24bppRgb);
        using var g = Graphics.FromImage(result);
        int y = 0;
        foreach (var s in _slices)
        {
            g.DrawImageUnscaled(s, 0, y);
            y += s.Height;
        }
        return result;
    }

    /// Two safeguards mirror the macOS matcher: 4-band row signatures (a bare
    /// per-row mean confuses repetitive UI rows → duplicated blocks) and a
    /// uniqueness margin (near-tied second-best ⇒ self-similar content ⇒ skip
    /// the frame instead of corrupting the seam).
    static int? FindOverlap(Bitmap prev, Bitmap next)
    {
        int h = prev.Height;
        if (h != next.Height || prev.Width != next.Width || h <= 40) return null;
        var prevSig = RowSignatures(prev);
        var nextSig = RowSignatures(next);
        if (prevSig == null || nextSig == null) return null;
        var prevS = prevSig.Value;
        var nextS = nextSig.Value;

        int k = Math.Max(32, h / 4);
        // detail-weighted rows: misaligned text dominates the score, empty
        // background (which matches everywhere) can't hide or fake a match
        var weights = new double[k];
        double weightSum = 0;
        for (int i = 0; i < k; i++)
        {
            double w = Math.Max(prevS.Energy[h - k + i], 0.5);
            weights[i] = w;
            weightSum += w;
        }
        if (weightSum <= 0) return null;

        int bestOffset = -1;
        double bestScore = double.MaxValue;
        double secondScore = double.MaxValue;
        for (int s = 0; s <= h - k; s++)
        {
            int start = h - k - s;
            double diff = 0;
            for (int i = 0; i < k; i++)
            {
                int a = (h - k + i) * 4;
                int b = (start + i) * 4;
                double d = (Math.Abs(prevS.Bands[a] - nextS.Bands[b])
                    + Math.Abs(prevS.Bands[a + 1] - nextS.Bands[b + 1])
                    + Math.Abs(prevS.Bands[a + 2] - nextS.Bands[b + 2])
                    + Math.Abs(prevS.Bands[a + 3] - nextS.Bands[b + 3])) / 4;
                diff += weights[i] * d;
            }
            diff /= weightSum;
            if (diff < bestScore)
            {
                if (bestOffset >= 0 && Math.Abs(s - bestOffset) > 6) secondScore = bestScore;
                bestScore = diff;
                bestOffset = s;
            }
            else if (diff < secondScore && Math.Abs(s - bestOffset) > 6)
            {
                secondScore = diff;
            }
        }
        // ratio uniqueness (true overlap ≈ 0.0, line-pitch aliases ~0.4–2)
        // with an absolute-gap fallback for pages with animation noise
        if (bestOffset <= 0 || bestScore >= 2.0) return null;
        bool unique = secondScore > bestScore * 3 + 0.15
            || secondScore - bestScore > 2.5;
        return unique ? bestOffset : null;
    }

    readonly record struct Signatures(double[] Bands, double[] Energy);

    /// Per-row: mean gray of 4 horizontal bands + horizontal gradient energy.
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
                        byte* px = row + x * 3;
                        int g = (px[0] + px[1] + px[2]) / 3;
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
