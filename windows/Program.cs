namespace Snippr;

static class Program
{
    [STAThread]
    static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // Before anything else: whatever happens next, there will be a record
        // of it. This machine cannot run Windows UI, so the app's own log is
        // the only witness to a click that went nowhere.
        Diag.Install();

        // Test entries run without the single-instance mutex on purpose: they
        // are for a runner or an owner who already has Snippr in the tray, and
        // refusing to start would defeat the point.
        if (TestEntry.Handle(Environment.GetCommandLineArgs())) return;

        using var mutex = new Mutex(true, "SnipprWinSingleInstance", out bool isFirst);
        if (!isFirst)
        {
            // don't exit silently — tell the user where the running copy is
            MessageBox.Show(
                "Snippr is already running — look for its icon in the system tray (bottom-right).\n\n" +
                "If you just installed an update, right-click the old tray icon, choose Quit, then start Snippr again.",
                "Snippr", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        try
        {
            Application.Run(new TrayContext());
        }
        catch (Exception ex)
        {
            Diag.Crash("run", ex);
            throw;
        }
    }
}
