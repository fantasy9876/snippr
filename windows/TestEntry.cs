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
    /// painted into a bitmap, and asked to run what its buttons run.
    ///
    /// Two things it deliberately does NOT press. A terminal action (Copy,
    /// Save, Pin, OCR, Open editor) closes the surface and reaches for a
    /// clipboard or a file dialog the runner has not got — pressing Copy and
    /// then anything else is an `ObjectDisposedException` caused by the test,
    /// not by the app. And the colour button opens a modal dialog, which on a
    /// runner means waiting until the job times out. The terminal routes are
    /// still checked, by asking them for their picture instead of pressing
    /// them: same code, no clipboard, no dialog, no teardown.
    ///
    /// Every step is separate. One failing step is recorded and the rest still
    /// run, because a smoke run that stops at the first problem hides the ones
    /// behind it. The exit code is the number of steps that failed.
    static void Shot(string dir, string? imagePath)
    {
        Directory.CreateDirectory(dir);
        using var picture = Load(imagePath);
        int failures = 0;

        void Step(string name, Action body)
        {
            try
            {
                body();
                Diag.Click("test", $"step ok: {name}");
            }
            catch (Exception ex)
            {
                failures++;
                Diag.Crash($"test-step:{name}", ex);
            }
        }

        using (var editor = EditorForm.CreateForTesting(new Bitmap(picture)))
        {
            Step("editor-layout", () =>
            {
                editor.Size = new Size(1400, 900);
                Reveal(editor);
            });
            Step("editor-shot", () => Capture(editor, Path.Combine(dir, "editor.png")));
            // Safe presses: nothing modal, nothing that closes the form.
            Step("editor-undo", () => editor.PressForTesting(OverlayAction.Undo));
            Step("editor-redo", () => editor.PressForTesting(OverlayAction.Redo));
            Step("editor-backdrop-menu", () =>
            {
                editor.PressForTesting(OverlayAction.Backdrop);
                editor.CloseMenusForTesting();
            });
            // The terminal routes, asked rather than pressed.
            foreach (var action in RouteDecoration.VisualRoutes
                .Concat(RouteDecoration.SemanticRoutes))
            {
                var route = action;
                Step($"editor-route-{route}", () =>
                {
                    using var image = editor.RouteImageForTesting(route);
                    Diag.Click("test", $"editor route {route} -> {image.Width}x{image.Height}");
                });
            }
        }

        var bounds = new Rectangle(0, 0, picture.Width, picture.Height);
        var selection = new Rectangle(
            picture.Width / 6, picture.Height / 6,
            picture.Width * 2 / 3, picture.Height * 2 / 3);
        using (var review = AreaReviewForm.CreateForTesting(
            new Bitmap(picture), bounds, selection))
        {
            Step("review-layout", () =>
            {
                Reveal(review);
                review.PlaceToolbarForTesting();
                review.Refresh();
            });
            Step("review-shot", () => Capture(review, Path.Combine(dir, "review.png")));
            Step("review-tool-magnifier", () => review.PressToolForTesting("magnifier"));
            Step("review-tool-select", () => review.PressToolForTesting("select"));
            Step("review-preset-ocean", () =>
            {
                review.ApplyPresetForTesting("ocean");
                review.Refresh();
                Application.DoEvents();
            });
            Step("review-shot-ocean",
                () => Capture(review, Path.Combine(dir, "review-ocean.png")));
            Step("review-undo", () => review.PressActionForTesting("undo"));
            foreach (var action in RouteDecoration.VisualRoutes
                .Concat(RouteDecoration.SemanticRoutes))
            {
                var route = action;
                Step($"review-route-{route}", () =>
                {
                    using var image = review.RouteImageForTesting(route);
                    Diag.Click("test", $"review route {route} -> {image.Width}x{image.Height}");
                });
            }
        }

        // The summary goes in BEFORE the copy, or the artifact's log stops one
        // line short of the answer — the first run's did.
        Diag.Click("test", $"shot finished failures={failures} dir={dir}");
        Step("collect-logs", () =>
        {
            if (File.Exists(Diag.ClickLogPath))
                File.Copy(Diag.ClickLogPath, Path.Combine(dir, "click.log"), overwrite: true);
            if (File.Exists(Diag.CrashLogPath))
                File.Copy(Diag.CrashLogPath, Path.Combine(dir, "crash.log"), overwrite: true);
        });
        // The job can read this without parsing a log.
        Environment.ExitCode = failures;
    }

    /// Puts the form on screen — off the side of every monitor — so it lays
    /// out and paints. `DrawToBitmap` on a form that was never shown gives
    /// back an empty rectangle: the first smoke run's `editor.png` was a slab
    /// of background with no toolbar in it, which says nothing about anything.
    static void Reveal(Form form)
    {
        form.StartPosition = FormStartPosition.Manual;
        form.ShowInTaskbar = false;
        form.Location = new Point(-32000, -32000);
        form.Show();
        form.Refresh();
        Application.DoEvents();
    }

    static void Capture(Form form, string path)
    {
        using var bmp = new Bitmap(Math.Max(1, form.Width), Math.Max(1, form.Height));
        form.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
        bmp.Save(path, ImageFormat.Png);
        var colours = DistinctColours(bmp);
        Diag.Click(
            "test",
            $"captured {Path.GetFileName(path)} {bmp.Width}x{bmp.Height} colours={colours}");
        // A picture of nothing passes every check that only asks whether a file
        // was written. Three colours is a low bar and a blank capture is under
        // it.
        if (colours < 3)
            throw new InvalidOperationException(
                $"{Path.GetFileName(path)} is blank ({colours} colours)");
    }

    static int DistinctColours(Bitmap bmp)
    {
        var seen = new HashSet<int>();
        for (int y = 0; y < bmp.Height; y += 4)
            for (int x = 0; x < bmp.Width; x += 4)
            {
                seen.Add(bmp.GetPixel(x, y).ToArgb());
                if (seen.Count >= 16) return seen.Count;
            }
        return seen.Count;
    }
}
