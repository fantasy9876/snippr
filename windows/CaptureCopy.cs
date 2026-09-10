namespace Snippr;

/// UI language for capture-flow copy. Missing or garbage → English (owner default).
public enum UILanguage
{
    English,
    Vietnamese,
}

public static class UILanguageUtil
{
    public const string EnglishCode = "en";
    public const string VietnameseCode = "vi";

    public static UILanguage Parse(string? raw) =>
        string.Equals(raw, VietnameseCode, StringComparison.OrdinalIgnoreCase)
            ? UILanguage.Vietnamese
            : UILanguage.English;

    public static string Code(UILanguage lang) =>
        lang == UILanguage.Vietnamese ? VietnameseCode : EnglishCode;

    /// Labels stay in their own language so the picker is findable either way.
    public static string MenuLabel(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Tiếng Việt",
        _ => "English",
    };
}

/// Capture-flow strings. Production reads only this table. Gates pin the
/// same sentences as *independent literals* so editing one cell goes red.
/// Keys match macOS `CaptureCopy.swift` after `3519422`; Windows uses Ctrl+C
/// and `px` where the platform differs. `Resolve` is bound by the app so
/// ParityGate can compile this file without `AppSettings`. Language has no
/// default: omitting it is a compile error (Honey W1). Call sites pass
/// `Current` or a session snapshot.
public static class CaptureCopy
{
    public static Func<UILanguage> Resolve { get; set; } = static () => UILanguage.English;

    public static UILanguage Current => Resolve();

    public static string StopHint(bool hotkeysRegistered, UILanguage language) =>
        hotkeysRegistered ? StopHintHotkey(language) : StopHintFallback(language);

    public static string StopHintHotkey(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Enter/✓ xong · Ctrl+C copy · Esc hủy",
        _ => "Enter/✓ done · Ctrl+C copy · Esc cancel",
    };

    public static string StopHintFallback(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "bấm ✓ để xong",
        _ => "click ✓ to finish",
    };

    public static string StitchingProgress(
        int pixels, bool hotkeysRegistered, UILanguage language)
    {
        var stitched = language == UILanguage.Vietnamese
            ? $"Đã ghép {pixels} px"
            : $"Stitched {pixels} px";
        var keep = language == UILanguage.Vietnamese ? " — cuộn tiếp · " : " — keep scrolling · ";
        return stitched + keep + StopHint(hotkeysRegistered, language);
    }

    public static string StitchingProgressUp(
        int pixels, bool hotkeysRegistered, UILanguage language)
    {
        var stitched = language == UILanguage.Vietnamese
            ? $"Đã ghép {pixels} px"
            : $"Stitched {pixels} px";
        var up = language == UILanguage.Vietnamese ? " (nối lên trên)" : " (connecting upward)";
        var keep = language == UILanguage.Vietnamese ? " — cuộn tiếp · " : " — keep scrolling · ";
        return stitched + up + keep + StopHint(hotkeysRegistered, language);
    }

    public static string DoneButton(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "✓ Xong",
        _ => "✓ Done",
    };

    public static string ScrollCancelled(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Đã hủy chụp cuộn",
        _ => "Scrolling capture cancelled",
    };

    public static string Copied(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Đã copy",
        _ => "Copied",
    };

    public static string RegionTooSmall(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Vùng quá nhỏ cho chụp cuộn — chọn vùng cao hơn 60 px",
        _ => "Region too small for scrolling capture — pick an area taller than 60 px",
    };

    public static string Bidirectional(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Cuộn lên hoặc xuống — stitcher nối cả hai chiều",
        _ => "Scroll up or down — stitching works both ways",
    };

    public static string NoMatch(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Chưa khớp được — cuộn chậm lại một chút",
        _ => "No match — scroll a bit slower",
    };

    public static string WaitingFirstFrame(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Chờ khung hình đầu tiên…",
        _ => "Waiting for the first frame…",
    };

    public static string CompatibilityMode(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Đang dùng chế độ tương thích — cuộn tiếp · ",
        _ => "Using compatibility mode — keep scrolling · ",
    };

    public static string Retrace(int pixels, UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => $"Đang cuộn qua vùng đã chụp — {pixels} px",
        _ => $"Scrolling through captured area — {pixels} px",
    };

    public static string LostSegment(int n, UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese =>
            $"Mất một đoạn do cuộn quá nhanh — đang ghi đoạn {n}; vạch sáng đánh dấu chỗ thiếu",
        _ =>
            $"Missed a stretch from scrolling too fast — recording segment {n}; a bright bar marks the gap",
    };

    public static string BackendSync(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Đang đồng bộ chế độ tương thích — cuộn chậm để nối tiếp",
        _ => "Syncing compatibility mode — scroll slowly to reconnect",
    };

    public static string BackendNewSegment(int n, UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese =>
            $"Đã đổi chế độ chụp và bắt đầu đoạn {n}; vạch sáng đánh dấu chỗ thiếu",
        _ =>
            $"Capture mode changed and started segment {n}; a bright bar marks the gap",
    };

    public static string ScreenshotCopied(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Đã copy",
        _ => "Screenshot copied",
    };

    public static string ScreenshotCopiedToClipboard(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Đã copy vào clipboard",
        _ => "Screenshot copied to clipboard",
    };

    public static string ScreenshotSummary(IReadOnlyList<string> parts, UILanguage lang)
    {
        var joined = string.Join(" · ", parts);
        return lang == UILanguage.Vietnamese ? $"Ảnh {joined}" : $"Screenshot {joined}";
    }

    public static string ToastCopiedWord(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "đã copy",
        _ => "copied",
    };

    public static string ToastSavedWord(string filename, UILanguage lang) =>
        lang == UILanguage.Vietnamese ? $"đã lưu {filename}" : $"saved {filename}";

    public static string ToastSaveFailed(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "lưu thất bại",
        _ => "save failed",
    };

    public static string ToastSaveFailedCopied(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "lưu thất bại — đã copy vào clipboard",
        _ => "save failed — copied instead",
    };

    /// Sentence-initial save toast (review `.save`), not the "saved x.png" fragment.
    public static string SavedFile(string filename, UILanguage lang) =>
        lang == UILanguage.Vietnamese ? $"Đã lưu {filename}" : $"Saved {filename}";

    public static string SaveFailed(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Lưu thất bại",
        _ => "Save failed",
    };

    public static string ExportAnnotatedFailed(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Không xuất được ảnh có nét vẽ — thử lại",
        _ => "Couldn't export the annotated image — try again",
    };

    public static string SavedRegionGone(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Vùng đã lưu không còn trên màn hình — chọn lại nhé",
        _ => "The saved region is no longer on screen — pick it again",
    };

    public static string SelectionTooLargeForBackdrop(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Vùng chọn quá lớn cho Backdrop",
        _ => "Selection too large for Backdrop",
    };

    public static string BackdropBuildFailed(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Không dựng được nền Backdrop — thử preset khác",
        _ => "Couldn't build the Backdrop — try another preset",
    };

    public static string NoPreviousArea(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Chưa có vùng đã lưu — chụp một vùng trước đã",
        _ => "No previous area — use Capture Area first",
    };

    public static string ScreenRecordingNeeded(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Cần quyền Screen Recording — bật Snippr trong Cài đặt hệ thống",
        _ => "Screen Recording permission needed — enable Snippr in System Settings",
    };

    public static string CaptureFailed(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Chụp thất bại",
        _ => "Capture failed",
    };

    public static string NoWindowFound(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Không tìm thấy cửa sổ",
        _ => "No window found",
    };

    /// Win-only: the live-preview prompt before the first stitched frame.
    /// macOS deleted the dead `scrollSlowly` path; Windows still shows it.
    public static string ScrollSlowly(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Cuộn từ từ — ảnh ghép hiện bên dưới",
        _ => "Scroll slowly — the stitch appears below",
    };

    /// Win-only: clipboard held by another process (RouteReviewed copy).
    public static string ClipboardBusy(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Clipboard đang bận — thử lại sau giây lát",
        _ => "Clipboard is busy — try again in a moment",
    };

    /// Win-only fragment inside the screenshot summary.
    public static string ClipboardBusyWord(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "clipboard bận",
        _ => "clipboard busy",
    };

    public static string ClipboardBusySaved(string filename, UILanguage lang) =>
        lang == UILanguage.Vietnamese
            ? $"Clipboard bận — đã lưu {filename}"
            : $"Clipboard busy — saved {filename}";

    public static string CopySaveFailedOpenEditor(UILanguage lang) => lang switch
    {
        UILanguage.Vietnamese => "Không copy/lưu được — mở editor",
        _ => "Couldn't copy or save — opening the editor",
    };
}
