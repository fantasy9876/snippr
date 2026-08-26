using System.Drawing.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Snippr;

/// Which recognizer the user wants, mirroring macOS's `OCRLanguage`. Stored
/// by name; see AppSettings.OcrLanguage.
enum OcrLanguagePreference { EnglishPlus, VietnamesePlus, Auto }

// ---------- OCR (Windows.Media.Ocr — offline, uses installed language packs) ----------

static class OcrService
{
    /// Recognition outcome: the text, plus what to say when the engine that
    /// answered is not the one that was asked for. Silence is what made
    /// Vietnamese look like a font bug — English recognizing Vietnamese
    /// returns confident nonsense, not an error.
    public readonly record struct OcrResult(string Text, string? LanguageWarning);

    /// The recognizer this build would like, in order of preference, mirroring
    /// macOS's OCRLanguage. `Auto` asks Windows for the user's own profile
    /// languages and accepts whatever that gives.
    static string[] PreferredTags(OcrLanguagePreference pref) => pref switch
    {
        OcrLanguagePreference.EnglishPlus => ["en-US", "vi-VN"],
        OcrLanguagePreference.VietnamesePlus => ["vi-VN", "en-US"],
        _ => [],
    };

    static readonly HashSet<string> _warnedLanguages = new();

    static OcrEngine? EngineFor(string tag) =>
        OcrEngine.AvailableRecognizerLanguages.Any(
            l => string.Equals(l.LanguageTag, tag, StringComparison.OrdinalIgnoreCase))
            ? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language(tag))
            : null;

    public static async Task<OcrResult> RecognizeAsync(Bitmap bmp)
    {
        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Png);
        ms.Position = 0;
        var decoder = await BitmapDecoder.CreateAsync(ms.AsRandomAccessStream());
        using var soft = await decoder.GetSoftwareBitmapAsync();

        var pref = AppSettings.Current.OcrPreference;
        var wanted = PreferredTags(pref);
        OcrEngine? engine = null;
        foreach (var tag in wanted)
        {
            engine = EngineFor(tag);
            if (engine != null) break;
        }
        engine ??= OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));

        var used = engine?.RecognizerLanguage.LanguageTag ?? "none";
        // Which language answered is the whole diagnosis when the text comes
        // back wrong: Windows ships no Vietnamese recognizer, so asking for
        // one lands on English, and English reading Vietnamese returns
        // confident nonsense rather than an error anyone can see.
        Diag.Click(
            "ocr",
            $"pref={pref} wanted={string.Join("|", wanted)} used={used} available="
            + string.Join(
                "|",
                OcrEngine.AvailableRecognizerLanguages.Select(l => l.LanguageTag)));
        if (engine == null) return new OcrResult("", "No text recognizer is installed");

        string? warning = null;
        if (wanted.Length > 0
            && !string.Equals(used, wanted[0], StringComparison.OrdinalIgnoreCase))
        {
            warning = pref == OcrLanguagePreference.VietnamesePlus
                ? $"Windows không có gói OCR tiếng Việt — đang đọc bằng {used}"
                : $"Không có bộ nhận dạng {wanted[0]} — đang đọc bằng {used}";
            // Once per run. The same recognizer answers every capture, so
            // repeating it turns a useful sentence into noise the user learns
            // to dismiss without reading.
            if (!_warnedLanguages.Add(warning)) warning = null;
        }

        var result = await engine.RecognizeAsync(soft);
        return new OcrResult(
            string.Join("\n", result.Lines.Select(l => l.Text)), warning);
    }
}

// ---------- OCR result window: text + language picker + translate + copy ----------

sealed class TextResultForm : Form
{
    readonly string _sourceText;
    readonly TextBox _text = new() { Name = "result" };
    readonly ComboBox _lang = new() { Name = "language" };
    readonly Label _status = new() { Name = "status" };
    readonly Button _translate = new() { Name = "translate", Text = "🌐 Translate" };
    readonly Button _retry = new() { Name = "retry", Text = "Thử lại" };
    readonly Button _copy = new() { Name = "copy", Text = "Copy" };
    int _generation;

    public static async void RunOcrFlow(Bitmap image, bool autoTranslate = false)
    {
        string text;
        string? languageWarning = null;
        try
        {
            var recognized = await OcrService.RecognizeAsync(image);
            text = recognized.Text;
            languageWarning = recognized.LanguageWarning;
        }
        catch
        {
            text = "";
        }
        finally
        {
            image.Dispose();
        }
        if (string.IsNullOrWhiteSpace(text))
        {
            ToastForm.Show("No text found");
            return;
        }
        // UnicodeText by name: the default already is Unicode, but an ANSI
        // round trip is exactly how accented text turns into the "font bug"
        // this flow was reported for, so the format is stated rather than
        // assumed.
        try { Clipboard.SetText(text, TextDataFormat.UnicodeText); } catch { }
        if (languageWarning != null) ToastForm.Show(languageWarning);
        var f = new TextResultForm(text);
        f.Show();
        f.Activate();
        if (autoTranslate) f.Translate();
    }

    internal static TextResultForm CreateForTesting(string text) => new(text);

    TextResultForm(string text)
    {
        _sourceText = text ?? "";
        Text = "Recognized Text — Snippr";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 440);
        MinimumSize = new Size(420, 300);
        Font = new Font("Segoe UI", 11f);

        _text.Multiline = true;
        _text.ScrollBars = ScrollBars.Vertical;
        _text.Text = _sourceText;
        _text.Dock = DockStyle.Fill;
        _text.Font = new Font("Segoe UI", 11.5f);

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 78, Padding = new Padding(10) };

        _lang.DropDownStyle = ComboBoxStyle.DropDownList;
        foreach (var (code, label) in TranslateService.Languages) _lang.Items.Add(label);
        var savedIdx = Array.FindIndex(TranslateService.Languages,
            l => l.Code == AppSettings.Current.TranslateTarget);
        _lang.SelectedIndex = savedIdx >= 0 ? savedIdx : 0;
        _lang.SetBounds(10, 8, 150, 32);
        // Attach AFTER SelectedIndex so opening the window does not fire a
        // translate. Changing the language afterwards re-translates from
        // the original, same as the mac panel.
        _lang.SelectedIndexChanged += (_, _) => Translate();

        _translate.Bounds = new Rectangle(168, 6, 130, 34);
        _translate.Click += (_, _) => Translate();

        _retry.Bounds = new Rectangle(306, 6, 90, 34);
        _retry.Visible = false;
        _retry.Click += (_, _) => Translate();

        _copy.Size = new Size(100, 34);
        _copy.Anchor = AnchorStyles.Right | AnchorStyles.Top;
        _copy.Location = new Point(bottom.Width - 112, 6);
        _copy.Click += (_, _) =>
        {
            try { Clipboard.SetText(_text.Text); } catch { }
            ToastForm.Show("Text copied");
        };

        _status.AutoSize = false;
        _status.ForeColor = Color.Gray;
        _status.SetBounds(10, 46, bottom.Width - 20, 24);
        _status.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;

        bottom.Controls.AddRange(new Control[] { _lang, _translate, _retry, _status, _copy });
        Controls.Add(_text);
        Controls.Add(bottom);
    }

    /// Lookup by Name, never by the label. A filter that matches 0 controls
    /// is a green suite that checked nothing.
    internal Control? ControlNamed(string name)
    {
        var found = Controls.Find(name, searchAllChildren: true);
        return found.Length == 1 ? found[0] : null;
    }

    internal void Translate() => _ = TranslateCore();

    async Task TranslateCore()
    {
        var idx = _lang.SelectedIndex;
        if (idx < 0 || _sourceText.Length == 0) return;
        var (code, label) = TranslateService.Languages[idx];
        AppSettings.Current.TranslateTarget = code;
        AppSettings.Current.Save();
        var gen = ++_generation;
        _status.Text = "Đang dịch…";
        _retry.Visible = false;
        try
        {
            var translated = await TranslateService.TranslateAsync(
                TranslateService.RequestText(_sourceText, _text.Text), code);
            if (gen != _generation) return;
            if (string.IsNullOrEmpty(translated))
            {
                ShowFailure(TranslateService.Failure.Payload(null));
                return;
            }
            _text.Text = translated;
            _status.Text = $"Đã dịch sang {label}";
            _retry.Visible = false;
        }
        catch (Exception ex)
        {
            if (gen != _generation) return;
            ShowFailure(TranslateService.Failure.Classify(ex));
        }
    }

    void ShowFailure(TranslateService.Failure failure)
    {
        // Fail open onto the original, not the previous translation.
        _text.Text = _sourceText;
        _status.Text = failure.UserMessage;
        _retry.Visible = true;
    }
}
