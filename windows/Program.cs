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
        if (!isFirst) return;

        Application.Run(new TrayContext());
    }
}
