using System.Runtime.CompilerServices;
using System.Text;

namespace Snippr.Tests;

/// Reads Windows capture-flow sources and flags user-facing string literals
/// that did not go through `CaptureCopy`. Ports macOS Honey G2 + D1/D2, with
/// N6 (unscanned channels need an in-code reason) and N7 (directory walk:
/// a file that contains a discovery marker must be scanned or excluded).
static class CaptureCopySourceScan
{
    static readonly string[] ScannedFiles =
    [
        "TrayContext.cs",
        "ScrollShot.cs",
        "AreaReviewForm.cs",
    ];

    /// Files that contain a discovery marker but are out of this slice.
    static readonly (string File, string Reason)[] ExcludedFiles =
    [
        ("Update.cs",
         "updater toasts, not capture-result — same as macOS UpdateChecker"),
        ("EditorForm.cs",
         "editor chrome, not capture-flow"),
        ("OcrTranslate.cs",
         "OCR — out of i18n slice; splash/OCR joint decision with macOS"),
        ("MiscForms.cs",
         "pin/about/settings chrome; Language radios stay English/Tiếng Việt by design"),
        ("TestEntry.cs",
         "Windows runner smoke, not production copy"),
        ("Ui/OcrResultPanel.cs",
         "OCR panel — out of i18n slice, same group as OcrTranslate"),
    ];

    static readonly (string Prefix, string Reason)[] ExcludedPrefixes =
    [
        ("Snippr.Win.ParityGate/",
         "independent pin literals, same as macOS SelfTest"),
        ("Snippr.Win.RasterGate/",
         "pixel gate, not production copy"),
        ("Snippr.Win.StitcherGate/",
         "stitcher gate, not production copy"),
    ];

    /// Honey N6: channels the scanner does not look at. A new user-facing
    /// channel must join the marker list or land here with a reason —
    /// silent omission is the hole N6 closes.
    static readonly (string Marker, string Reason)[] UnscannedChannels =
    [
        ("new ToolStripMenuItem(",
         "tray and backdrop menus stay English this slice; capture-result toasts are ToastForm.Show"),
        (".ToolTipText",
         "hover chrome, not capture-result"),
        (".AccessibleName",
         "accessibility labels, not capture-result"),
        (".AccessibleDescription",
         "accessibility, not capture-result"),
    ];

    /// Out-of-slice or non-result toasts inside scanned files. Exact match —
    /// a prefix must not hide a future literal. Reason is part of the gate
    /// so the list cannot grow silently.
    static readonly (string Needle, string Reason)[] Allowlist =
    [
        ("Snippr is running — {HotkeyUtil.Display(AppSettings.Current.HotkeyArea)} to capture",
         "launch splash, not a capture-result toast — OCR/splash joint decision with macOS"),
        ("Hotkey {HotkeyUtil.Display(combo)} is taken by another app",
         "hotkey conflict, not a capture-result toast"),
        ("No image in clipboard",
         "Load From Clipboard, not a capture path"),
        ("Could not open image",
         "Open File, not a capture path"),
        ("Text copied",
         "OCR overlay — out of i18n slice, Win PR decides with splash"),
        ("Snippr {Application.ProductVersion.Split('+')[0]}",
         "tray tooltip version string, not capture-result copy"),
    ];

    static readonly string[] DiscoveryMarkers =
    [
        "ToastForm.Show(",
        ".Text =",
        "new Button",
    ];

    static readonly string[] ScanMarkers =
    [
        "ToastForm.Show(",
        ".Text =",
        "new Button",
    ];

    public static string WindowsDirectory([CallerFilePath] string file = "")
    {
        var dir = Path.GetDirectoryName(file)
            ?? throw new InvalidOperationException("CaptureCopySourceScan has no file path");
        return Path.GetFullPath(Path.Combine(dir, ".."));
    }

    public static List<string> Hits(string windowsDir)
    {
        var found = new List<string>();
        foreach (var (marker, reason) in UnscannedChannels)
        {
            if (string.IsNullOrWhiteSpace(marker)) found.Add("n6-empty-marker");
            if (string.IsNullOrWhiteSpace(reason)) found.Add($"n6-empty-reason:{marker}");
        }
        foreach (var (file, reason) in ExcludedFiles)
        {
            if (string.IsNullOrWhiteSpace(reason)) found.Add($"n7-empty-reason:{file}");
        }
        foreach (var (prefix, reason) in ExcludedPrefixes)
        {
            if (string.IsNullOrWhiteSpace(reason)) found.Add($"n7-empty-prefix-reason:{prefix}");
        }
        foreach (var (_, reason) in Allowlist)
        {
            if (string.IsNullOrWhiteSpace(reason)) found.Add("allowlist-empty-reason");
        }

        var scanned = new HashSet<string>(ScannedFiles, StringComparer.Ordinal);
        var excluded = new HashSet<string>(
            ExcludedFiles.Select(e => e.File), StringComparer.Ordinal);

        foreach (var path in Directory.GetFiles(windowsDir, "*.cs", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(windowsDir, path).Replace('\\', '/');
            if (rel.Contains("/obj/", StringComparison.Ordinal)
                || rel.Contains("/bin/", StringComparison.Ordinal)
                || rel.StartsWith("obj/", StringComparison.Ordinal)
                || rel.StartsWith("bin/", StringComparison.Ordinal))
                continue;

            string text;
            try { text = File.ReadAllText(path); }
            catch
            {
                found.Add($"{rel}:unreadable");
                continue;
            }

            if (!ContainsAnyMarker(text, DiscoveryMarkers)) continue;

            if (PrefixExcluded(rel)) continue;
            if (excluded.Contains(rel)) continue;
            if (scanned.Contains(rel))
            {
                found.AddRange(Scan(rel, text));
                continue;
            }
            found.Add($"{rel}:has-marker-not-listed");
        }

        foreach (var name in ScannedFiles)
        {
            var full = Path.Combine(windowsDir, name);
            if (!File.Exists(full)) found.Add($"{name}:missing");
        }

        return found;
    }

    static bool PrefixExcluded(string rel) =>
        ExcludedPrefixes.Any(p => rel.StartsWith(p.Prefix, StringComparison.Ordinal));

    static bool ContainsAnyMarker(string text, string[] markers)
    {
        foreach (var m in markers)
        {
            if (text.Contains(m, StringComparison.Ordinal)) return true;
        }
        return false;
    }

    static List<string> Scan(string file, string source)
    {
        var stripped = StripComments(source);
        var hits = new List<string>();
        int searchFrom = 0;
        while (searchFrom < stripped.Length)
        {
            int bestIdx = -1;
            string? bestMarker = null;
            foreach (var marker in ScanMarkers)
            {
                var idx = stripped.IndexOf(marker, searchFrom, StringComparison.Ordinal);
                if (idx < 0) continue;
                if (bestIdx < 0 || idx < bestIdx)
                {
                    bestIdx = idx;
                    bestMarker = marker;
                }
            }
            if (bestIdx < 0 || bestMarker is null) break;

            var after = bestIdx + bestMarker.Length;
            IEnumerable<string> lits;
            if (bestMarker == "new Button")
                lits = ButtonTextLiterals(stripped, after);
            else if (bestMarker.EndsWith('(') || bestMarker.EndsWith(':'))
                lits = StringLiterals(ArgumentSnippet(stripped, after));
            else
                lits = StringLiterals(RhsSnippet(stripped, after));

            foreach (var lit in lits)
            {
                if (IsPunctuationOnly(lit)) continue;
                if (IsCaptureCopyInterpolation(lit)) continue;
                if (Allowlist.Any(a => a.Needle == lit)) continue;
                hits.Add($"{file}:{LineNumber(stripped, bestIdx)}:{lit}");
            }

            searchFrom = after + (after < stripped.Length ? 1 : 0);
        }
        return hits;
    }

    static IEnumerable<string> ButtonTextLiterals(string text, int from)
    {
        var brace = text.IndexOf('{', from);
        if (brace < 0) return [];
        var block = BraceSnippet(text, brace + 1);
        var found = new List<string>();
        int i = 0;
        while (i < block.Length)
        {
            var idx = block.IndexOf("Text =", i, StringComparison.Ordinal);
            if (idx < 0) break;
            found.AddRange(StringLiterals(RhsSnippet(block, idx + "Text =".Length)));
            i = idx + 6;
        }
        return found;
    }

    static string StripComments(string source)
    {
        var outBuf = new StringBuilder(source.Length);
        var chars = source;
        int i = 0;
        bool inStr = false;
        bool escaped = false;
        while (i < chars.Length)
        {
            var c = chars[i];
            if (inStr)
            {
                outBuf.Append(c);
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inStr = false;
                i++;
                continue;
            }
            if (c == '"')
            {
                inStr = true;
                outBuf.Append(c);
                i++;
                continue;
            }
            if (c == '/' && i + 1 < chars.Length && chars[i + 1] == '/')
            {
                while (i < chars.Length && chars[i] != '\n') i++;
                continue;
            }
            if (c == '/' && i + 1 < chars.Length && chars[i + 1] == '*')
            {
                i += 2;
                while (i + 1 < chars.Length && !(chars[i] == '*' && chars[i + 1] == '/'))
                {
                    if (chars[i] == '\n') outBuf.Append('\n');
                    i++;
                }
                i = Math.Min(i + 2, chars.Length);
                continue;
            }
            outBuf.Append(c);
            i++;
        }
        return outBuf.ToString();
    }

    static string ArgumentSnippet(string text, int start)
    {
        int depth = 1;
        bool inStr = false;
        bool escaped = false;
        for (int i = start; i < text.Length; i++)
        {
            var c = text[i];
            if (inStr)
            {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inStr = false;
            }
            else
            {
                if (c == '"') inStr = true;
                else if (c == '(') depth++;
                else if (c == ')')
                {
                    depth--;
                    if (depth == 0) return text[start..i];
                }
            }
        }
        return text[start..];
    }

    static string BraceSnippet(string text, int start)
    {
        int depth = 1;
        bool inStr = false;
        bool escaped = false;
        for (int i = start; i < text.Length; i++)
        {
            var c = text[i];
            if (inStr)
            {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inStr = false;
            }
            else
            {
                if (c == '"') inStr = true;
                else if (c == '{') depth++;
                else if (c == '}')
                {
                    depth--;
                    if (depth == 0) return text[start..i];
                }
            }
        }
        return text[start..];
    }

    static string RhsSnippet(string text, int start)
    {
        for (int i = start; i < text.Length; i++)
        {
            var c = text[i];
            if (c == '\n' || c == ';' || c == ',') return text[start..i];
        }
        return text[start..];
    }

    /// `$"{CaptureCopy.Foo()} · {stopHint}"` is production wiring, not a
    /// hardcoded sentence. `"Copied"` or `" extra"` is not.
    static bool IsCaptureCopyInterpolation(string lit)
    {
        if (!lit.Contains('{')) return false;
        return IsPunctuationOnly(StripInterpolations(lit));
    }

    static string StripInterpolations(string s)
    {
        var outBuf = new StringBuilder();
        int i = 0;
        while (i < s.Length)
        {
            if (s[i] == '{')
            {
                int j = i + 1;
                int depth = 1;
                while (j < s.Length && depth > 0)
                {
                    if (s[j] == '{') depth++;
                    else if (s[j] == '}') depth--;
                    j++;
                }
                i = j;
                continue;
            }
            outBuf.Append(s[i]);
            i++;
        }
        return outBuf.ToString();
    }

    static List<string> StringLiterals(string snippet)
    {
        var lits = new List<string>();
        int i = 0;
        while (i < snippet.Length)
        {
            if (snippet[i] == '"')
            {
                int j = i + 1;
                bool escaped = false;
                var buf = new StringBuilder();
                while (j < snippet.Length)
                {
                    var c = snippet[j];
                    if (escaped) { buf.Append(c); escaped = false; }
                    else if (c == '\\') escaped = true;
                    else if (c == '"') break;
                    else buf.Append(c);
                    j++;
                }
                lits.Add(buf.ToString());
                i = j < snippet.Length ? j + 1 : j;
                continue;
            }
            i++;
        }
        return lits;
    }

    static bool IsPunctuationOnly(string s)
    {
        var trimmed = s.Trim();
        if (trimmed.Length == 0) return true;
        foreach (var c in trimmed)
        {
            if (char.IsLetter(c) || char.IsDigit(c)) return false;
        }
        return true;
    }

    static int LineNumber(string text, int idx)
    {
        int line = 1;
        for (int i = 0; i < idx && i < text.Length; i++)
        {
            if (text[i] == '\n') line++;
        }
        return line;
    }
}
