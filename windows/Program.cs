namespace Snippr;

static class Program
{
    [STAThread]
    static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

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

        Application.Run(new TrayContext());
    }
}
