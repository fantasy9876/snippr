using System.Drawing.Imaging;

namespace Snippr;

/// One back buffer, kept for as long as the surface using it is on screen.
///
/// WinForms' own `DoubleBuffered` / `OptimizedDoubleBuffer` asks
/// `BufferedGraphicsContext` for a buffer the size of the CLIENT rectangle,
/// and the shared context only caches buffers up to 225x96. Every surface in
/// this app is the size of the desktop, so every one of those paints went down
/// the temporary-manager path: allocate a full-screen DIB, paint, free it.
/// Once per mouse move, on a 4K desktop, that is a 33 MB allocation and
/// release per frame of a drag — which the machine feels as both the
/// allocation and the page faults that follow it.
///
/// So the surfaces here buffer themselves through this. It grows to the
/// largest paint asked of it and then stops allocating; the memory goes back
/// when the surface closes, which for an overlay is a few seconds later and
/// for the tray is the whole point.
sealed class PaintBuffer : IDisposable
{
    Bitmap? _bmp;

    /// A bitmap at least <paramref name="need"/> big, or null if one cannot be
    /// had — the caller should then paint straight to the screen, because a
    /// torn frame beats a missing one.
    public Bitmap? For(Size need)
    {
        if (need.Width <= 0 || need.Height <= 0) return null;
        if (_bmp is not null && _bmp.Width >= need.Width && _bmp.Height >= need.Height)
            return _bmp;
        int width = Math.Max(need.Width, _bmp?.Width ?? 0);
        int height = Math.Max(need.Height, _bmp?.Height ?? 0);
        _bmp?.Dispose();
        _bmp = null;
        try
        {
            // Premultiplied: GDI+ blits PArgb through its fast opaque path,
            // the same reason the captures use it.
            _bmp = new Bitmap(width, height, PixelFormat.Format32bppPArgb);
        }
        catch (Exception ex)
        {
            Diag.Crash("paint-buffer", ex);
        }
        return _bmp;
    }

    public void Dispose()
    {
        _bmp?.Dispose();
        _bmp = null;
    }
}
