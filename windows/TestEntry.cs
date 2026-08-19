using System.Drawing.Imaging;
using System.Runtime.InteropServices;

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
    [DllImport("user32.dll")]
    static extern IntPtr WindowFromPoint(Point point);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    const int WmMouseMove = 0x0200;
    const int WmLButtonDown = 0x0201;
    const int WmLButtonUp = 0x0202;
    const int GwlExStyle = -20;
    const long WsExTopmost = 0x00000008;

    /// lParam for a mouse message: y in the high word, x in the low word,
    /// both as *signed* 16-bit values — the review surface lives at negative
    /// client coordinates while the smoke keeps it off-screen.
    static IntPtr MouseLParam(Point p) =>
        (IntPtr)(((p.Y & 0xFFFF) << 16) | (p.X & 0xFFFF));

    static void SendMouse(Control target, int message, Point clientPoint) =>
        SendMessage(target.Handle, message, IntPtr.Zero, MouseLParam(clientPoint));

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

        // Production hands the review surface the VIRTUAL SCREEN and a frozen
        // capture of exactly that, so the smoke does the same. Asking for a
        // fixture-sized window instead made the runner clamp it — the desktop
        // there is smaller than the fixture — and sent us hunting a
        // multi-monitor bug that the clamp's own definition rules out
        // (MaxWindowTrackSize is the whole desktop, not the primary monitor).
        var desktop = SystemInformation.VirtualScreen;
        var bounds = new Rectangle(0, 0, desktop.Width, desktop.Height);
        using var frozen = new Bitmap(bounds.Width, bounds.Height);
        using (var g = Graphics.FromImage(frozen))
            g.DrawImage(picture, 0, 0, bounds.Width, bounds.Height);
        var selection = new Rectangle(
            bounds.Width / 6, bounds.Height / 6,
            bounds.Width * 2 / 3, bounds.Height * 2 / 3);
        using (var review = AreaReviewForm.CreateForTesting(
            new Bitmap(frozen), bounds, selection))
        {
            Step("review-layout", () =>
            {
                Reveal(review);
                review.PlaceToolbarForTesting();
                review.Refresh();
            });
            Step("review-shot", () => Capture(review, Path.Combine(dir, "review.png")));
            Step("review-tool-magnifier", () =>
            {
                // A leftover SizeAll is the bug: SelectTool must reset it.
                review.CursorForTesting = Cursors.SizeAll;
                review.PressToolForTesting("magnifier");
                if (review.CursorForTesting != Cursors.Cross)
                    throw new InvalidOperationException(
                        $"magnifier cursor is {review.CursorForTesting} want Cross");
            });
            Step("review-magnifier-drag", () =>
            {
                var crop = review.SelectionForTesting;
                review.DragMagnifierForTesting(
                    new Point(crop.X + 24, crop.Y + 24),
                    new Point(crop.X + 88, crop.Y + 64));
                review.Refresh();
                Application.DoEvents();
            });
            Step("review-shot-magnifier-drag",
                () => Capture(review, Path.Combine(dir, "review-magnifier-drag.png")));
            Step("review-tool-select", () =>
            {
                var crop = review.SelectionForTesting;
                // Two directions, both premises set by the test: inside the
                // crop must become SizeAll (CropGrip.None would still pass a
                // one-way "not SizeAll outside"), and outside must not keep
                // the leftover SizeAll. The form is parked at -32000, so the
                // machine cursor cannot be the premise.
                review.PointerClientForTesting = new Point(crop.X + 24, crop.Y + 24);
                review.PressToolForTesting("select");
                if (review.CursorForTesting != Cursors.SizeAll)
                    throw new InvalidOperationException(
                        $"select inside crop is {review.CursorForTesting} want SizeAll");

                review.PointerClientForTesting = new Point(crop.X - 24, crop.Y - 24);
                review.PressToolForTesting("magnifier");
                review.PressToolForTesting("select");
                if (review.CursorForTesting == Cursors.SizeAll)
                    throw new InvalidOperationException(
                        "select outside crop kept SizeAll");
                review.PointerClientForTesting = null;
            });
            Step("review-covers-requested-bounds", () =>
            {
                // Against the rectangle the surface was ASKED for, not against
                // its own bounds. Windows clamps the window and its client
                // area TOGETHER, so client-vs-bounds agrees while the window
                // is short — this check passed on a run whose log showed the
                // clamp happening (asked 1280x800, client 1044x788). The
                // runner's screen is smaller than the picture, so this is the
                // The surface must cover the desktop it asked for. Size only:
                // where the window sits is the caller's business, and the
                // smoke parks this one off-screen on purpose.
                var want = review.RequestedBoundsForTesting.Size;
                if (review.Size != want)
                    throw new InvalidOperationException(
                        $"window {review.Size} != requested {want}");
                if (review.ClientSize != want)
                    throw new InvalidOperationException(
                        $"client {review.ClientSize} != requested {want}");
            });
            Step("review-canvas-click-reaches-tool", () =>
            {
                // Two halves, and they prove different things.
                //
                // First: who does WINDOWS say owns a point over the picture?
                // The chrome is docked over the whole surface and forwards
                // what lands on it; when it answered HTTRANSPARENT the press
                // fell to a form with no mouse handlers and nothing drew.
                // Posting a message cannot catch that — posting skips hit
                // testing entirely — so ask the OS with the form on-screen.
                var home = review.Location;
                review.Location = Point.Empty;
                Application.DoEvents();
                var crop = review.SelectionForTesting;
                var centre = new Point(
                    crop.X + crop.Width / 2, crop.Y + crop.Height / 2);
                var owner = WindowFromPoint(review.PointToScreen(centre));
                var chrome = review.ChromeForTesting;
                if (owner != chrome.Handle)
                    throw new InvalidOperationException(
                        $"point in the crop belongs to {owner}, not the chrome {chrome.Handle}");
                review.Location = home;
                Application.DoEvents();

                // Second: the forwarding itself. An Arrow dragged across the
                // crop has to leave exactly one mark behind.
                review.PressToolForTesting("arrow");
                int before = review.AnnotationCountForTesting;
                var from = new Point(crop.X + 40, crop.Y + 40);
                var to = new Point(crop.X + 160, crop.Y + 120);
                SendMouse(chrome, WmLButtonDown, from);
                SendMouse(chrome, WmMouseMove, to);
                SendMouse(chrome, WmLButtonUp, to);
                Application.DoEvents();
                int after = review.AnnotationCountForTesting;
                if (after != before + 1)
                    throw new InvalidOperationException(
                        $"arrow drag left {after - before} marks, want 1");
                review.PressToolForTesting("select");
            });
            Step("review-hint-visible-and-topmost", () =>
            {
                // The hint was created with CreateHandle + SWP_SHOWWINDOW, so
                // WinForms never knew it was visible (HideNow was a no-op) and
                // it sat in the normal band UNDER its own TopMost host — the
                // overlay could not show a hint at all.
                // On screen first. The hint clamps itself to the display its
                // anchor is on, intersected with the host's client rect — and
                // the smoke parks this form at -32000, where that intersection
                // is empty and the hint correctly refuses to appear. Hovering
                // off-screen tested the parking, not the hint.
                var home = review.Location;
                review.Location = Point.Empty;
                Application.DoEvents();
                var chrome = review.ChromeForTesting;
                var hint = review.HintForTesting;
                var button = FirstLeaf(chrome);
                var centre = new Point(button.Width / 2, button.Height / 2);
                // Put the REAL cursor on the button first. A posted
                // WM_MOUSEMOVE makes WinForms start tracking, and the moment
                // the physical pointer is found elsewhere a WM_MOUSELEAVE
                // arrives and clears the pending hint before its 450 ms timer
                // can fire — the hint is then working exactly as designed and
                // the gate is testing where the runner's mouse happens to be.
                Cursor.Position = button.PointToScreen(centre);
                SendMouse(button, WmMouseMove, centre);
                var deadline = DateTime.UtcNow.AddSeconds(3);
                while (DateTime.UtcNow < deadline && !hint.IsHandleCreated)
                {
                    Application.DoEvents();
                    Thread.Sleep(30);
                }
                while (DateTime.UtcNow < deadline
                    && !IsWindowVisible(hint.Handle))
                {
                    Application.DoEvents();
                    Thread.Sleep(30);
                }
                if (!IsWindowVisible(hint.Handle))
                    throw new InvalidOperationException(
                        "hint never became visible — "
                        + hint.LastPlacementForTesting);
                long ex = (long)GetWindowLongPtr(hint.Handle, GwlExStyle);
                if ((ex & WsExTopmost) == 0)
                    throw new InvalidOperationException(
                        $"hint is not WS_EX_TOPMOST (exstyle 0x{ex:X})");
                hint.HideNow();
                Application.DoEvents();
                bool stillUp = IsWindowVisible(hint.Handle);
                review.Location = home;
                Application.DoEvents();
                if (stillUp)
                    throw new InvalidOperationException("HideNow left the hint up");
            });
            Step("review-rail-carries-its-actions", () =>
            {
                // The rail is tools THEN backdrop/color/undo/redo, like
                // macOS. The parity gate pins the catalog's split; this is
                // the other half — that the toolbar actually built it that
                // way, because the layout is told how many to place.
                var counts = review.ChromeCountsForTesting;
                if (counts.Rail != ToolCatalog.RailCount
                    || counts.Strip != ToolCatalog.StripCount)
                    throw new InvalidOperationException(
                        $"toolbar rail/strip {counts.Rail}/{counts.Strip}, "
                        + $"catalog {ToolCatalog.RailCount}/{ToolCatalog.StripCount}");

                // Backdrop's hint says (D), so D has to do something. A hint
                // naming a key nobody routes is a promise the app breaks the
                // first time someone believes it.
                var menu = review.BackdropMenuForTesting;
                if (!review.PressKeyForTesting(Keys.D))
                    throw new InvalidOperationException("D was not routed");
                Application.DoEvents();
                if (!menu.Visible)
                    throw new InvalidOperationException("D did not open the backdrop menu");
                menu.Close();
                Application.DoEvents();
            });
            Step("review-backdrop-menu-labels", () =>
            {
                // The menu showed five swatches and no words: AutoSize was
                // off with only a height set, so every row kept the default
                // width and the label had nowhere to draw. Opening is what
                // sizes them, so open it the way the button does.
                var menu = review.BackdropMenuForTesting;
                menu.RaiseOpeningForTesting();
                foreach (ToolStripItem item in menu.Items)
                {
                    // Separators have no label and keep their own thin box.
                    if (item is ToolStripSeparator) continue;
                    int text = TextRenderer.MeasureText(item.Text, menu.Font).Width;
                    int need = text + menu.ImageScalingSize.Width;
                    if (item.Width < need)
                        throw new InvalidOperationException(
                            $"backdrop row '{item.Text}' is {item.Width}px, "
                            + $"needs {need}px for its label");
                }
            });
            Step("review-backdrop-corner-rows", () =>
            {
                // The corner setting existed on Windows since 1.2.11 with no
                // way to reach it. Clicking the row has to move the LIVE
                // session, not only the stored setting: the session took its
                // copy when the surface opened.
                var menu = review.BackdropMenuForTesting;
                menu.RaiseOpeningForTesting();
                var rows = menu.Items.OfType<ToolStripMenuItem>()
                    .Where(i => i.Tag is BackdropCornerStyle).ToList();
                if (rows.Count != 4)
                    throw new InvalidOperationException(
                        $"{rows.Count} corner rows, want 4");
                var before = review.CornersForTesting;
                var target = rows.First(
                    i => (BackdropCornerStyle)i.Tag! == BackdropCornerStyle.Large);
                target.PerformClick();
                Application.DoEvents();
                if (review.CornersForTesting != BackdropCornerStyle.Large)
                    throw new InvalidOperationException(
                        $"session corners {review.CornersForTesting}, want Large");
                menu.RaiseOpeningForTesting();
                if (!rows.First(i => (BackdropCornerStyle)i.Tag! == BackdropCornerStyle.Large).Checked)
                    throw new InvalidOperationException("Large row is not ticked");
                // Leave the machine AND the surface as we found them: the
                // later shot steps photograph this session, and a corner
                // style left behind changes what they capture.
                AppSettings.Current.BackdropCorners = before.ToString();
                AppSettings.Current.Save();
                var restore = menu.Items.OfType<ToolStripMenuItem>().First(
                    i => i.Tag is BackdropCornerStyle st && st == before);
                restore.PerformClick();
                Application.DoEvents();
                if (review.CornersForTesting != before)
                    throw new InvalidOperationException(
                        $"session corners left at {review.CornersForTesting}, want {before}");
            });
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
    /// The deepest child of <paramref name="root"/> — an overlay toolbar
    /// button, for a hint that only fires over one.
    static Control FirstLeaf(Control root)
    {
        var c = root;
        while (c.Controls.Count > 0) c = c.Controls[0];
        return c;
    }

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
