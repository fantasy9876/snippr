using System.Drawing.Imaging;

namespace Snippr;

static class CaptureUtil
{
    /// Screenshot of the entire virtual desktop (all monitors).
    public static Bitmap VirtualScreen(out Rectangle bounds)
    {
        bounds = SystemInformation.VirtualScreen;
        var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(bounds.X, bounds.Y, 0, 0, bounds.Size);
        return bmp;
    }

    /// Screenshot of the monitor under the mouse cursor.
    public static Bitmap ScreenUnderCursor()
    {
        var screen = Screen.FromPoint(Cursor.Position);
        var b = screen.Bounds;
        var bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size);
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

        var bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(rect.X, rect.Y, 0, 0, rect.Size);
        return bmp;
    }

    /// Crop a rect (virtual-screen coords) out of a virtual-screen bitmap.
    public static Bitmap CropVirtual(Bitmap virtualShot, Rectangle virtualBounds, Rectangle rect)
    {
        var local = new Rectangle(rect.X - virtualBounds.X, rect.Y - virtualBounds.Y, rect.Width, rect.Height);
        local.Intersect(new Rectangle(Point.Empty, virtualShot.Size));
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
    public static bool LooksLikePhoto(Bitmap bmp)
    {
        using var small = new Bitmap(bmp, new Size(64, 64));
        var colors = new HashSet<int>();
        for (int y = 0; y < 64; y++)
            for (int x = 0; x < 64; x++)
            {
                var c = small.GetPixel(x, y);
                colors.Add((c.R >> 4 << 8) | (c.G >> 4 << 4) | (c.B >> 4));
            }
        return colors.Count > 1100;
    }
}
