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

        _timer.Interval = 250;
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
            _label.Text = "  Cuộn trang từ từ — Snippr tự ghép ảnh";
        }
        else if (_stitcher.Append(bmp))
        {
            _label.Text = $"  Đã ghép {_stitcher.TotalHeight}px — cuộn tiếp, xong bấm ✓ / Esc";
            if (_stitcher.TotalHeight >= MaxHeightPx) Finish();
        }
        else
        {
            _label.Text = "  Chưa khớp được — cuộn chậm lại một chút";
            bmp.Dispose();
        }
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

        // control bar above (below if no room)
        var wa = Screen.FromRectangle(_rect).WorkingArea;
        int barW = Math.Min(520, Math.Max(360, _rect.Width));
        int barH = 40;
        int barY = _rect.Y - t - barH - 8;
        if (barY < wa.Top) barY = _rect.Bottom + t + 8;
        int barX = Math.Clamp(_rect.X + (_rect.Width - barW) / 2, wa.Left + 4, wa.Right - barW - 4);

        var bar = new Form
        {
            FormBorderStyle = FormBorderStyle.None,
            StartPosition = FormStartPosition.Manual,
            ShowInTaskbar = false,
            TopMost = true,
            BackColor = Color.FromArgb(24, 26, 31),
            Bounds = new Rectangle(barX, barY, barW, barH),
        };
        _label.Bounds = new Rectangle(4, 0, barW - 108, barH);
        _label.Text = "  Cuộn trang từ từ — Snippr tự ghép ảnh";
        var done = new Button
        {
            Text = "✓ Xong",
            ForeColor = Color.White,
            BackColor = Color.FromArgb(0, 120, 212),
            FlatStyle = FlatStyle.Flat,
            Bounds = new Rectangle(barW - 96, 5, 88, barH - 10),
            Font = new Font("Segoe UI", 10f, FontStyle.Bold),
        };
        done.FlatAppearance.BorderSize = 0;
        done.Click += (_, _) => Finish();
        bar.Controls.Add(_label);
        bar.Controls.Add(done);
        bar.Show();
        _chrome.Add(bar);
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

    public bool Append(Bitmap next)
    {
        if (next.Width != Width) return false;
        var offset = FindOverlap(_lastFrame, next);
        if (offset is not int rows || rows <= 0) return false;

        rows = Math.Min(rows, next.Height);
        var slice = next.Clone(
            new Rectangle(0, next.Height - rows, Width, rows), next.PixelFormat);
        _slices.Add(slice);
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

    static int? FindOverlap(Bitmap prev, Bitmap next)
    {
        int h = prev.Height;
        if (h != next.Height || prev.Width != next.Width || h <= 40) return null;
        var prevG = GrayRows(prev);
        var nextG = GrayRows(next);
        if (prevG == null || nextG == null) return null;

        int k = Math.Max(24, h / 5);
        int bestOffset = -1;
        double bestScore = double.MaxValue;
        for (int s = 0; s <= h - k; s++)
        {
            int start = h - k - s;
            double diff = 0;
            for (int i = 0; i < k; i++)
            {
                diff += Math.Abs(prevG[h - k + i] - nextG[start + i]);
            }
            diff /= k;
            if (diff < bestScore)
            {
                bestScore = diff;
                bestOffset = s;
            }
        }
        return bestOffset >= 0 && bestScore < 6.0 ? bestOffset : null;
    }

    /// Mean gray per row, sampling ~96 columns (fast row signature).
    static unsafe double[]? GrayRows(Bitmap bmp)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int w = bmp.Width, h = bmp.Height;
            int colStride = Math.Max(1, w / 96);
            var rows = new double[h];
            byte* basePtr = (byte*)data.Scan0;
            for (int y = 0; y < h; y++)
            {
                byte* row = basePtr + y * data.Stride;
                int sum = 0, count = 0;
                for (int x = 0; x < w; x += colStride)
                {
                    byte* px = row + x * 3;
                    sum += (px[0] + px[1] + px[2]) / 3;
                    count++;
                }
                rows[y] = (double)sum / Math.Max(1, count);
            }
            return rows;
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
