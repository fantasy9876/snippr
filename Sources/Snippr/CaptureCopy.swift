import Foundation

/// UI language for capture-flow copy. Missing or garbage → English (owner default).
enum UILanguage: String, CaseIterable {
    case english = "en"
    case vietnamese = "vi"

    static var resolved: UILanguage {
        let raw = UserDefaults.standard.string(forKey: Settings.Keys.uiLanguage) ?? "en"
        return UILanguage(rawValue: raw) ?? .english
    }

    /// Labels stay in their own language so the picker is findable either way.
    var menuLabel: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

/// Capture-flow strings. Production reads only this table. Gates pin the
/// same sentences as *independent literals* so editing one cell goes red.
/// Windows PR repeats these keys/literals in `CaptureCopy.cs`.
enum CaptureCopy {
    static func stopHint(hotkeysRegistered: Bool, language: UILanguage = .resolved) -> String {
        hotkeysRegistered ? stopHintHotkey(language) : stopHintFallback(language)
    }

    static func stopHintHotkey(_ lang: UILanguage) -> String {
        switch lang {
        case .english: return "Enter/✓ done · ⌘C copy · Esc cancel"
        case .vietnamese: return "Enter/✓ xong · ⌘C copy · Esc hủy"
        }
    }

    static func stopHintFallback(_ lang: UILanguage) -> String {
        switch lang {
        case .english: return "click ✓ to finish"
        case .vietnamese: return "bấm ✓ để xong"
        }
    }

    static func stitchingProgress(
        points: Int, connectingUp: Bool, hotkeysRegistered: Bool,
        language: UILanguage = .resolved
    ) -> String {
        let stitched: String
        switch language {
        case .english: stitched = "Stitched \(points) pt"
        case .vietnamese: stitched = "Đã ghép \(points) pt"
        }
        let up: String
        switch language {
        case .english: up = connectingUp ? " (connecting upward)" : ""
        case .vietnamese: up = connectingUp ? " (nối lên trên)" : ""
        }
        let keep: String
        switch language {
        case .english: keep = " — keep scrolling · "
        case .vietnamese: keep = " — cuộn tiếp · "
        }
        return stitched + up + keep + stopHint(hotkeysRegistered: hotkeysRegistered, language: language)
    }

    static func doneButton(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "✓ Done"
        case .vietnamese: return "✓ Xong"
        }
    }

    static func scrollCancelled(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Scrolling capture cancelled"
        case .vietnamese: return "Đã hủy chụp cuộn"
        }
    }

    static func copied(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Copied"
        case .vietnamese: return "Đã copy"
        }
    }

    static func regionTooSmall(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english:
            return "Region too small for scrolling capture — pick an area taller than 60 pt"
        case .vietnamese:
            return "Vùng quá nhỏ cho chụp cuộn — chọn vùng cao hơn 60 pt"
        }
    }

    static func bidirectional(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Scroll up or down — stitching works both ways"
        case .vietnamese: return "Cuộn lên hoặc xuống — stitcher nối cả hai chiều"
        }
    }

    static func noMatch(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "No match — scroll a bit slower"
        case .vietnamese: return "Chưa khớp được — cuộn chậm lại một chút"
        }
    }

    static func waitingFirstFrame(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Waiting for the first frame…"
        case .vietnamese: return "Chờ khung hình đầu tiên…"
        }
    }

    static func compatibilityMode(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Using compatibility mode — keep scrolling · "
        case .vietnamese: return "Đang dùng chế độ tương thích — cuộn tiếp · "
        }
    }

    static func retrace(_ points: Int, _ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Scrolling through captured area — \(points) pt"
        case .vietnamese: return "Đang cuộn qua vùng đã chụp — \(points) pt"
        }
    }

    static func lostSegment(_ n: Int, _ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english:
            return "Missed a stretch from scrolling too fast — recording segment \(n); a bright bar marks the gap"
        case .vietnamese:
            return "Mất một đoạn do cuộn quá nhanh — đang ghi đoạn \(n); vạch sáng đánh dấu chỗ thiếu"
        }
    }

    static func backendSync(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Syncing compatibility mode — scroll slowly to reconnect"
        case .vietnamese: return "Đang đồng bộ chế độ tương thích — cuộn chậm để nối tiếp"
        }
    }

    static func backendNewSegment(_ n: Int, _ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english:
            return "Capture mode changed and started segment \(n); a bright bar marks the gap"
        case .vietnamese:
            return "Đã đổi chế độ chụp và bắt đầu đoạn \(n); vạch sáng đánh dấu chỗ thiếu"
        }
    }

    static func screenshotCopied(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Screenshot copied"
        case .vietnamese: return "Đã copy"
        }
    }

    static func screenshotCopiedToClipboard(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Screenshot copied to clipboard"
        case .vietnamese: return "Đã copy vào clipboard"
        }
    }

    static func screenshotSummary(_ parts: [String], _ lang: UILanguage = .resolved) -> String {
        let joined = parts.joined(separator: " · ")
        switch lang {
        case .english: return "Screenshot \(joined)"
        case .vietnamese: return "Ảnh \(joined)"
        }
    }

    static func toastCopiedWord(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "copied"
        case .vietnamese: return "đã copy"
        }
    }

    static func toastSavedWord(_ filename: String, _ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "saved \(filename)"
        case .vietnamese: return "đã lưu \(filename)"
        }
    }

    static func toastSaveFailed(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "save failed"
        case .vietnamese: return "lưu thất bại"
        }
    }

    static func toastSaveFailedCopied(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "save failed — copied instead"
        case .vietnamese: return "lưu thất bại — đã copy vào clipboard"
        }
    }

    /// Sentence-initial save toast (router `.save`), not the "saved x.png" fragment.
    static func savedFile(_ filename: String, _ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Saved \(filename)"
        case .vietnamese: return "Đã lưu \(filename)"
        }
    }

    static func saveFailed(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Save failed"
        case .vietnamese: return "Lưu thất bại"
        }
    }

    static func exportAnnotatedFailed(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Couldn't export the annotated image — try again"
        case .vietnamese: return "Không xuất được ảnh có nét vẽ — thử lại"
        }
    }

    static func savedRegionGone(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "The saved region is no longer on screen — pick it again"
        case .vietnamese: return "Vùng đã lưu không còn trên màn hình — chọn lại nhé"
        }
    }

    static func selectionTooLargeForBackdrop(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Selection too large for Backdrop"
        case .vietnamese: return "Vùng chọn quá lớn cho Backdrop"
        }
    }

    static func backdropBuildFailed(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Couldn't build the Backdrop — try another preset"
        case .vietnamese: return "Không dựng được nền Backdrop — thử preset khác"
        }
    }

    static func noPreviousArea(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "No previous area — use Capture Area first"
        case .vietnamese: return "Chưa có vùng trước — hãy chọn vùng trước đã"
        }
    }

    static func screenRecordingNeeded(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english:
            return "Screen Recording permission needed — enable Snippr in System Settings"
        case .vietnamese:
            return "Cần quyền Screen Recording — bật Snippr trong Cài đặt Hệ thống"
        }
    }

    static func captureFailed(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "Capture failed"
        case .vietnamese: return "Chụp thất bại"
        }
    }

    static func noWindowFound(_ lang: UILanguage = .resolved) -> String {
        switch lang {
        case .english: return "No window found"
        case .vietnamese: return "Không tìm thấy cửa sổ"
        }
    }
}
