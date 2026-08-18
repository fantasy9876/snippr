using System.Drawing.Imaging;

namespace Snippr;

/// Command-line ways into the two surfaces nobody on this team can reach.
///
/// The app is developed on a Mac and gated on a runner with no desktop, so the
/// review surface and the editor have never been opened by anyone but the
/// owner. These entries let CI — and the owner, without hunting for a hotkey —
/// go straight to the surface in question with a picture from disk instead of a
/// screen capture.
///
///   Snippr.exe --test-review &lt;png&gt;   open the review surface over that picture
///   Snippr.exe --test-editor &lt;png&gt;   open the editor with that picture
///   Snippr.exe --test-shot &lt;dir&gt; [--image &lt;png&gt;]
///                                    headless: build both surfaces off-screen,
///                                    press their buttons in code, write PNGs
///                                    and exit — no interactive desktop needed
static class TestEntry
{
    /// True when the arguments asked for a test entry and it has run.
    public static bool Handle(string[] args)
    {
        var review = Value(args, "--test-review");
        var editor = Value(args, "--test-editor");
        var shot = Value(args, "--test-shot");
        if (review is null && editor is null && shot is null) return false;

        Diag.Click("test", $"args={string.Join(' ', args.Skip(1))}");
        try
        {
            if (shot is not null) { Shot(shot, Value(args, "--image")); return true; }
            if (review is not null) { Review(review, Value(args, "--test-out")); return true; }
            Editor(editor!);
            return true;
        }
        catch (Exception ex)
        {
            Diag.Crash("test-entry", ex);
            throw;
        }
    }

    static string? Value(string[] args, string flag)
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (string.Equals(args[i], flag, StringComparison.OrdinalIgnoreCase))
                return args[i + 1];
        return null;
    }

    static Bitmap Load(string? path)
    {
        if (path is not null && File.Exists(path))
        {
            using var loaded = new Bitmap(path);
            return new Bitmap(loaded);
        }
        // A picture with structure in it, so a screenshot of the surface shows
        // whether the document is drawn, cropped and rounded.
        var bmp = new Bitmap(1280, 800, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        using var back = new SolidBrush(Color.FromArgb(255, 245, 245, 245));
        g.FillRectangle(back, 0, 0, bmp.Width, bmp.Height);
        using var ink = new SolidBrush(Color.FromArgb(255, 40, 90, 190));
        for (int y = 0; y < bmp.Height; y += 80)
            for (int x = 0; x < bmp.Width; x += 80)
                if (((x / 80) + (y / 80)) % 2 == 0) g.FillRectangle(ink, x, y, 80, 80);
        return bmp;
    }

    static void Review(string path, string? outPath)
    {
        using var desktop = Load(path);
        var bounds = new Rectangle(0, 0, desktop.Width, desktop.Height);
        var selection = new Rectangle(
            desktop.Width / 6, desktop.Height / 6,
            desktop.Width * 2 / 3, desktop.Height * 2 / 3);
        var (action, image, rect) = AreaReviewForm.Review(desktop, bounds, selection);
        Diag.Click("test", $"review returned action={action} rect={rect}");
        if (image is null) return;
        if (outPath is not null) image.Save(outPath, ImageFormat.Png);
        image.Dispose();
    }

    static void Editor(string path)
    {
        var image = Load(path);
        EditorForm.OpenWith(image);
        Application.Run();
    }

    /// No desktop, no clicks, no waiting: each surface is built, laid out,
    /// painted into a bitmap, and asked to run the actions its buttons run.
    /// What comes out is a picture of the chrome and a log of what happened —
    /// which is what "the buttons do nothing" needs in order to be answered.
    static void Shot(string dir, string? imagePath)
    {
        Directory.CreateDirectory(dir);
        using var picture = Load(imagePath);

        using (var editor = EditorForm.CreateForTesting(new Bitmap(picture)))
        {
            editor.Size = new Size(1400, 900);
            editor.CreateControl();
            editor.PerformLayout();
            Capture(editor, Path.Combine(dir, "editor.png"));
            editor.PressForTesting(OverlayAction.Copy);
            editor.PressForTesting(OverlayAction.Undo);
        }

        var bounds = new Rectangle(0, 0, picture.Width, picture.Height);
        var selection = new Rectangle(
            picture.Width / 6, picture.Height / 6,
            picture.Width * 2 / 3, picture.Height * 2 / 3);
        using (var review = AreaReviewForm.CreateForTesting(
            new Bitmap(picture), bounds, selection))
        {
            review.CreateControl();
            review.PerformLayout();
            review.PlaceToolbarForTesting();
            Capture(review, Path.Combine(dir, "review.png"));
            review.PressToolForTesting("magnifier");
            review.PressActionForTesting("backdrop");
            review.ApplyPresetForTesting("ocean");
            Capture(review, Path.Combine(dir, "review-ocean.png"));
        }

        File.Copy(Diag.ClickLogPath, Path.Combine(dir, "click.log"), overwrite: true);
        if (File.Exists(Diag.CrashLogPath))
            File.Copy(Diag.CrashLogPath, Path.Combine(dir, "crash.log"), overwrite: true);
    }

    static void Capture(Form form, string path)
    {
        using var bmp = new Bitmap(Math.Max(1, form.Width), Math.Max(1, form.Height));
        form.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
        bmp.Save(path, ImageFormat.Png);
        Diag.Click("test", $"captured {Path.GetFileName(path)} {bmp.Width}x{bmp.Height}");
    }
}
