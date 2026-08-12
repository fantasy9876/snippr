using System.Runtime.InteropServices;

namespace Snippr;

static class Native
{
    public const int WM_HOTKEY = 0x0312;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT = 0x0004;

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    // ---- exclude our chrome windows from screen capture (Win10 2004+) ----

    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;

    [DllImport("user32.dll")]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);

    // ---- low-level keyboard hook (observe Esc without consuming it) ----

    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_SYSKEYDOWN = 0x0104;

    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookExW(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandleW(string? lpModuleName);
}

/// Converts between Keys combos ((int)(Keys.Control | Keys.Shift | Keys.D1)),
/// RegisterHotKey modifier/vk pairs, and display strings.
static class HotkeyUtil
{
    public const uint MOD_ALT = 0x0001;

    public static (uint mods, uint vk) Split(int combo)
    {
        var keys = (Keys)combo;
        uint mods = 0;
        if (keys.HasFlag(Keys.Control)) mods |= Native.MOD_CONTROL;
        if (keys.HasFlag(Keys.Shift)) mods |= Native.MOD_SHIFT;
        if (keys.HasFlag(Keys.Alt)) mods |= MOD_ALT;
        return (mods, (uint)(keys & Keys.KeyCode));
    }

    public static string Display(int combo)
    {
        if (combo == 0) return "None";
        var keys = (Keys)combo;
        var parts = new List<string>();
        if (keys.HasFlag(Keys.Control)) parts.Add("Ctrl");
        if (keys.HasFlag(Keys.Shift)) parts.Add("Shift");
        if (keys.HasFlag(Keys.Alt)) parts.Add("Alt");
        var code = keys & Keys.KeyCode;
        parts.Add(code switch
        {
            >= Keys.D0 and <= Keys.D9 => ((int)code - (int)Keys.D0).ToString(),
            >= Keys.NumPad0 and <= Keys.NumPad9 => "Num" + ((int)code - (int)Keys.NumPad0),
            Keys.Oemplus => "=",
            Keys.OemMinus => "-",
            Keys.PrintScreen => "PrtScn",
            _ => code.ToString(),
        });
        return string.Join("+", parts);
    }
}

/// Hidden message-only window that receives WM_HOTKEY.
sealed class HotkeyWindow : NativeWindow, IDisposable
{
    public event Action<int>? HotkeyPressed;

    public HotkeyWindow()
    {
        CreateHandle(new CreateParams());
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY)
        {
            HotkeyPressed?.Invoke(m.WParam.ToInt32());
        }
        base.WndProc(ref m);
    }

    public void Dispose() => DestroyHandle();
}
