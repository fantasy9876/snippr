using System.Text.Json;

namespace Snippr;

class AppSettings
{
    public string SaveFolder { get; set; } =
        Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
    public string Format { get; set; } = "auto"; // auto | png
    public bool AfterShow { get; set; } = true;

    /// How round the Backdrop plate's corners are. Stored by name so an older
    /// build reading a newer file falls back to the default rather than to
    /// whatever number an enum happened to have.
    public string BackdropCorners { get; set; } =
        BackdropSpec.DefaultCornerStyle.ToString();

    /// Which recognizer to ask for, by name, mirroring macOS's OCRLanguage.
    /// Stored by name for the same reason the corner style is: an older build
    /// reading a newer file falls back to the default rather than to whatever
    /// number an enum happened to have.
    public string OcrLanguage { get; set; } = OcrLanguagePreference.EnglishPlus.ToString();

    public OcrLanguagePreference OcrPreference =>
        Enum.TryParse<OcrLanguagePreference>(OcrLanguage, ignoreCase: true, out var pref)
            ? pref
            : OcrLanguagePreference.EnglishPlus;

    public BackdropCornerStyle CornerStyle =>
        Enum.TryParse<BackdropCornerStyle>(BackdropCorners, ignoreCase: true, out var style)
            ? style
            : BackdropSpec.DefaultCornerStyle;
    public bool AfterCopy { get; set; } = false;
    public bool AfterSave { get; set; } = false;
    public bool LaunchAtStartup { get; set; } = false;
    // Hotkeys stored as (int)(Keys modifiers | key code); 0 = disabled
    public int HotkeyFullscreen { get; set; } = (int)(Keys.Control | Keys.Shift | Keys.D1);
    public int HotkeyArea { get; set; } = (int)(Keys.Control | Keys.Shift | Keys.D2);
    public int HotkeyWindow { get; set; } = (int)(Keys.Control | Keys.Shift | Keys.D4);
    // Editor preferences remembered across sessions
    public Dictionary<string, float> ToolWidths { get; set; } = new();
    public string LastColor { get; set; } = "#FF0000";
    /// Esc in the editor copies to clipboard before closing (mirrors macOS
    /// escCopy). Off = Esc discards without touching the clipboard.
    public bool EscCopy { get; set; } = true;
    public string TranslateTarget { get; set; } = "vi";
    public int LastAreaX { get; set; } = -1;
    public int LastAreaY { get; set; }
    public int LastAreaW { get; set; }
    public int LastAreaH { get; set; }

    static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Snippr");
    static string FilePath => Path.Combine(Dir, "settings.json");

    public static AppSettings Current { get; private set; } = Load();

    static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath))
                    ?? new AppSettings();
            }
        }
        catch { /* corrupted settings → defaults */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public float GetToolWidth(string tool) =>
        ToolWidths.TryGetValue(tool, out var w) ? Math.Clamp(w, 1, 20) : 3f;

    public void SetToolWidth(string tool, float w)
    {
        ToolWidths[tool] = Math.Clamp(w, 1, 20);
        Save();
    }

    public Rectangle? LastArea
    {
        get => LastAreaX < 0 ? null : new Rectangle(LastAreaX, LastAreaY, LastAreaW, LastAreaH);
        set
        {
            if (value is Rectangle r) { LastAreaX = r.X; LastAreaY = r.Y; LastAreaW = r.Width; LastAreaH = r.Height; }
            else LastAreaX = -1;
        }
    }
}
