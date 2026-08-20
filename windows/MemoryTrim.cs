using System.Runtime;

namespace Snippr;

/// Hands the process's peak back to the machine.
///
/// Snippr has a very spiky shape: it idles in the tray for hours, then one
/// capture allocates several bitmaps the size of the whole desktop — a 4K
/// virtual screen is 33 MB each, and a review holds the frozen shot, the
/// toolbar's back buffer and, if anything was redacted, a pixelated copy —
/// and drops them all a moment later.
///
/// The collector frees them, but a freed large-object segment stays MAPPED in
/// the process. Resident memory keeps the high-water mark, so a tray icon that
/// is doing nothing reads as hundreds of megabytes in Task Manager, and on a
/// machine with little RAM that is not merely cosmetic — it is pages another
/// program wanted.
///
/// So once a capture is over, ask for the one collection that actually returns
/// segments to the OS. Two rules keep it invisible:
///
///  - Debounced. `Schedule` restarts a short timer, so a burst of captures
///    trims once, after the last one.
///  - Never while a surface is up. A blocking gen-2 with LOH compaction takes
///    tens of milliseconds; that is nothing with no window on screen and a
///    stutter with one. If a session is running when the timer fires, it waits.
///
/// Call `Schedule` wherever a capture-sized bitmap stops being reachable.
static class MemoryTrim
{
    /// Long enough that a save dialog or a toast is done with, short enough
    /// that the memory is back before the user looks.
    const int QuietMs = 2500;

    static System.Windows.Forms.Timer? _timer;

    public static void Schedule()
    {
        _timer ??= Build();
        // Restart, not start: the LAST release decides when the quiet began.
        _timer.Stop();
        _timer.Start();
    }

    static System.Windows.Forms.Timer Build()
    {
        var timer = new System.Windows.Forms.Timer { Interval = QuietMs };
        timer.Tick += (_, _) => Run();
        return timer;
    }

    static void Run()
    {
        _timer?.Stop();
        // The overlay and the scroll session own the screen while they are up,
        // and their bitmaps are still live — collecting now would cost the
        // pause and free nothing. Whatever they release will schedule again.
        if (OverlayForm.IsActive || ScrollShotSession.IsActive)
        {
            Schedule();
            return;
        }
        try
        {
            var before = GC.GetTotalMemory(false);
            // CompactOnce is the half that returns LOH segments; Aggressive is
            // the half that bothers to look at everything. Neither alone gives
            // the memory back.
            GCSettings.LargeObjectHeapCompactionMode =
                GCLargeObjectHeapCompactionMode.CompactOnce;
            //
            // Deliberately NOT followed by WaitForPendingFinalizers: this runs
            // on the UI thread, and a WinForms finalizer that marshals to the
            // thread it is blocking is a deadlock. Nothing here depends on
            // finalizers anyway — every capture bitmap is disposed explicitly.
            GC.Collect(2, GCCollectionMode.Aggressive, blocking: true, compacting: true);
            var after = GC.GetTotalMemory(false);
            Diag.Click(
                "memory",
                $"trim {before / (1024 * 1024)}MB -> {after / (1024 * 1024)}MB managed");
        }
        catch (Exception ex)
        {
            // Reclaiming memory must never be the thing that loses a capture.
            Diag.Crash("memory-trim", ex);
        }
    }
}
