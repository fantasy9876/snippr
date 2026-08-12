using System.Drawing.Imaging;

namespace Snippr;

static class CaptureUtil
{
    // Captures use premultiplied ARGB: GDI+ blits PArgb with a fast opaque
    // path, while plain 32bppArgb goes through per-pixel alpha conversion —
    // that difference alone made the selection overlay repaint ~5-10x slower.

    /// Screenshot of the entire virtual desktop (all monitors).
    public static Bitmap VirtualScreen(out Rectangle bounds)
    {
        bounds = SystemInformation.VirtualScreen;
        var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(bounds.X, bounds.Y, 0, 0, bounds.Size);
        return bmp;
    }

    /// Screenshot of the monitor under the mouse cursor.
    public static Bitmap ScreenUnderCursor()
    {
        var screen = Screen.FromPoint(Cursor.Position);
        var b = screen.Bounds;
        var bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size);
        return bmp;
    }

    /// Screenshot of a virtual-screen rect, captured directly (no full-desktop
    /// intermediate). Returns null when the rect is off-screen.
    public static Bitmap? Rect(Rectangle rect)
    {
        rect.Intersect(SystemInformation.VirtualScreen);
        if (rect.Width < 1 || rect.Height < 1) return null;
        var bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(rect.X, rect.Y, 0, 0, rect.Size);
        return bmp;
    }

    /// Screenshot of the foreground window (extended frame = no invisible resize borders).
    public static Bitmap? ActiveWindow()
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;

        Native.RECT r;
        if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS,
                out r, System.Runtime.InteropServices.Marshal.SizeOf<Native.RECT>()) != 0)
        {
            if (!Native.GetWindowRect(hwnd, out r)) return null;
        }

        var rect = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        if (rect.Width < 10 || rect.Height < 10) return null;

        var bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(rect.X, rect.Y, 0, 0, rect.Size);
        return bmp;
    }

    /// Crop a rect (virtual-screen coords) out of a virtual-screen bitmap.
    /// Returns null when the rect no longer intersects the shot (e.g. a saved
    /// area from a monitor that has been unplugged) — Bitmap.Clone throws on
    /// an empty rectangle.
    public static Bitmap? CropVirtual(Bitmap virtualShot, Rectangle virtualBounds, Rectangle rect)
    {
        var local = new Rectangle(rect.X - virtualBounds.X, rect.Y - virtualBounds.Y, rect.Width, rect.Height);
        local.Intersect(new Rectangle(Point.Empty, virtualShot.Size));
        if (local.Width < 1 || local.Height < 1) return null;
        return virtualShot.Clone(local, virtualShot.PixelFormat);
    }

    // ---- saving ----

    public static string? SaveToFolder(Bitmap bmp)
    {
        var s = AppSettings.Current;
        try
        {
            Directory.CreateDirectory(s.SaveFolder);
            bool jpeg = s.Format == "auto" && LooksLikePhoto(bmp);
            string name = $"Snippr {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}.{(jpeg ? "jpg" : "png")}";
            string path = Path.Combine(s.SaveFolder, name);
            SaveAs(bmp, path, jpeg);
            return path;
        }
        catch
        {
            return null;
        }
    }

    public static void SaveAs(Bitmap bmp, string path, bool jpeg)
    {
        if (jpeg)
        {
            var codec = ImageCodecInfo.GetImageEncoders()
                .First(c => c.FormatID == ImageFormat.Jpeg.Guid);
            using var p = new EncoderParameters(1);
            p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 90L);
            bmp.Save(path, codec, p);
        }
        else
        {
            bmp.Save(path, ImageFormat.Png);
        }
    }

    /// Photo-like images (many distinct colors) → JPEG; UI shots → PNG.
    /// Scans via LockBits — the old GetPixel loop crossed the managed/GDI+
    /// boundary 4096 times (~4-15 ms on the UI thread per auto-format save).
    public static unsafe bool LooksLikePhoto(Bitmap bmp)
    {
        using var small = new Bitmap(64, 64, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(small))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
            g.DrawImage(bmp, new Rectangle(0, 0, 64, 64));
        }
        var data = small.LockBits(new Rectangle(0, 0, 64, 64),
            ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            var colors = new HashSet<int>();
            byte* basePtr = (byte*)data.Scan0;
            for (int y = 0; y < 64; y++)
            {
                byte* row = basePtr + y * data.Stride;
                for (int x = 0; x < 64; x++)
                {
                    byte* px = row + x * 3; // BGR
                    colors.Add((px[2] >> 4 << 8) | (px[1] >> 4 << 4) | (px[0] >> 4));
                }
            }
            return colors.Count > 1100;
        }
        finally
        {
            small.UnlockBits(data);
        }
    }
}
