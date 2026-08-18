using System.Diagnostics;
using System.Reflection;
using System.Text;

namespace Snippr;

/// Two small log files, always on.
///
/// The machine this app is developed on cannot run it: every Windows-only
/// question so far has cost a round trip through CI or through the owner's
/// hands. "No feature in the menu works" is exactly the report that cannot be
/// acted on without knowing whether the click arrived at all — so from here
/// the app answers that itself.
///
/// `click.log` records what the user pressed and what ran; `crash.log` records
/// anything that escaped. Both live in `%LOCALAPPDATA%\Snippr`, both rotate at
/// 256 KB, and neither ever throws: a diagnostic that can break the app it is
/// diagnosing is worse than none.
static class Diag
{
    const long MaxBytes = 256 * 1024;
    static readonly object Gate = new();

    static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Snippr");

    public static string ClickLogPath => Path.Combine(Dir, "click.log");
    public static string CrashLogPath => Path.Combine(Dir, "crash.log");

    /// Wires the last-resort handlers and notes that this build started.
    /// Call once, before the message loop.
    public static void Install()
    {
        Application.ThreadException += (_, e) => Crash("ui-thread", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Crash("background", e.ExceptionObject as Exception);
        var version = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? Application.ProductVersion;
        Click("app", $"start version={version} os={Environment.OSVersion.Version} " +
            $"dpiAware={Application.HighDpiMode} screens={Screen.AllScreens.Length}");
    }

    /// One line per user action: which surface, which control, what happened.
    public static void Click(string surface, string detail)
    {
        Write(ClickLogPath, $"{Stamp()} {surface}: {detail}");
    }

    /// Wraps an action so a throw is RECORDED and re-thrown rather than
    /// vanishing into a handler somewhere up the stack. The user still sees
    /// whatever the app does with it; the file keeps the reason.
    public static void Run(string surface, string detail, Action body)
    {
        Click(surface, detail);
        try
        {
            body();
        }
        catch (Exception ex)
        {
            Crash($"{surface}:{detail}", ex);
            throw;
        }
    }

    public static void Crash(string where, Exception? ex)
    {
        var text = new StringBuilder()
            .Append(Stamp()).Append(' ').Append(where).AppendLine()
            .AppendLine(ex?.ToString() ?? "(no exception object)")
            .ToString();
        Write(CrashLogPath, text);
    }

    static string Stamp() => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");

    static void Write(string path, string line)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Dir);
                Rotate(path);
                File.AppendAllText(path, line + Environment.NewLine);
            }
        }
        catch
        {
            // A log that cannot be written is not a reason to lose a capture.
            Debug.WriteLine($"Snippr diag: could not write {path}");
        }
    }

    /// Keeps one previous file. Two bounded files beat one unbounded one, and
    /// beat losing the start of a session to truncation.
    static void Rotate(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length < MaxBytes) return;
        var previous = path + ".1";
        File.Delete(previous);
        File.Move(path, previous);
    }
}
