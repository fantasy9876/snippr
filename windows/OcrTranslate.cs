using System.Drawing.Imaging;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Snippr;

// ---------- OCR (Windows.Media.Ocr — offline, uses installed language packs) ----------

static class OcrService
{
    public static async Task<string> RecognizeAsync(Bitmap bmp)
    {
        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Png);
        ms.Position = 0;
        var decoder = await BitmapDecoder.CreateAsync(ms.AsRandomAccessStream());
        using var soft = await decoder.GetSoftwareBitmapAsync();

        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));
        // Which language answered is the whole diagnosis when the text comes
        // back wrong: a profile without a Vietnamese OCR pack silently falls
        // through to en-US, and en-US on Vietnamese reads as mangled glyphs
        // rather than as an error anyone can see.
        Diag.Click(
            "ocr",
            $"engine={engine?.RecognizerLanguage.LanguageTag ?? "none"} "
            + "available="
            + string.Join(
                "|",
                OcrEngine.AvailableRecognizerLanguages.Select(l => l.LanguageTag)));
        if (engine == null) return "";

        var result = await engine.RecognizeAsync(soft);
        return string.Join("\n", result.Lines.Select(l => l.Text));
    }
}

// ---------- Translation (Google gtx endpoint — only on explicit user action) ----------

static class TranslateService
{
    public static readonly (string Code, string Label)[] Languages =
    {
        ("vi", "Tiếng Việt"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
        ("zh-CN", "中文 (简体)"), ("fr", "Français"), ("de", "Deutsch"),
        ("es", "Español"), ("th", "ไทย"),
    };

    static readonly HttpClient Http = new();

    public static async Task<string> TranslateAsync(string text, string lang)
    {
        // POST with the text in the body: a GET URL breaks past ~8 KB, which is
        // exactly the dense/scroll captures where translation matters most
        var url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl="
            + Uri.EscapeDataString(lang) + "&dt=t";
        using var body = new FormUrlEncodedContent(new[]
        {
            new KeyValuePair<string, string>("q", text),
        });
        using var resp = await Http.PostAsync(url, body);
        resp.EnsureSuccessStatusCode();
        var json = await resp.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var sb = new StringBuilder();
        foreach (var seg in doc.RootElement[0].EnumerateArray())
        {
            sb.Append(seg[0].GetString());
        }
        return sb.ToString();
    }
}

// ---------- OCR result window: text + language picker + translate + copy ----------

sealed class TextResultForm : Form
{
    readonly TextBox _text = new();
    readonly ComboBox _lang = new();
    readonly Label _status = new();

    public static async void RunOcrFlow(Bitmap image, bool autoTranslate = false)
    {
        string text;
        try
        {
            text = await OcrService.RecognizeAsync(image);
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
        try { Clipboard.SetText(text); } catch { }
        var f = new TextResultForm(text);
        f.Show();
        f.Activate();
        if (autoTranslate) f.Translate();
    }

    TextResultForm(string text)
    {
        Text = "Recognized Text — Snippr";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 420);
        MinimumSize = new Size(420, 300);
        Font = new Font("Segoe UI", 11f);

        _text.Multiline = true;
        _text.ScrollBars = ScrollBars.Vertical;
        _text.Text = text;
        _text.Dock = DockStyle.Fill;
        _text.Font = new Font("Segoe UI", 11.5f);

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 56, Padding = new Padding(10) };

        _lang.DropDownStyle = ComboBoxStyle.DropDownList;
        foreach (var (code, label) in TranslateService.Languages) _lang.Items.Add(label);
        var savedIdx = Array.FindIndex(TranslateService.Languages,
            l => l.Code == AppSettings.Current.TranslateTarget);
        _lang.SelectedIndex = savedIdx >= 0 ? savedIdx : 0;
        _lang.SetBounds(10, 12, 160, 32);

        var translate = new Button { Text = "🌐 Translate", Bounds = new Rectangle(180, 10, 140, 34) };
        translate.Click += (_, _) => Translate();

        _status.AutoSize = true;
        _status.ForeColor = Color.Gray;
        _status.Location = new Point(330, 18);

        var copy = new Button
        {
            Text = "Copy",
            Size = new Size(100, 34),
            Anchor = AnchorStyles.Right | AnchorStyles.Top,
        };
        copy.Location = new Point(bottom.Width - 112, 10);
        copy.Click += (_, _) =>
        {
            try { Clipboard.SetText(_text.Text); } catch { }
            ToastForm.Show("Text copied");
        };

        bottom.Controls.AddRange(new Control[] { _lang, translate, _status, copy });
        Controls.Add(_text);
        Controls.Add(bottom);
    }

    internal async void Translate()
    {
        var idx = _lang.SelectedIndex;
        if (idx < 0 || _text.Text.Length == 0) return;
        var (code, label) = TranslateService.Languages[idx];
        AppSettings.Current.TranslateTarget = code;
        AppSettings.Current.Save();
        _status.Text = "Đang dịch…";
        try
        {
            _text.Text = await TranslateService.TranslateAsync(_text.Text, code);
            _status.Text = $"Đã dịch sang {label}";
        }
        catch
        {
            _status.Text = "Dịch thất bại — kiểm tra mạng";
        }
    }
}
