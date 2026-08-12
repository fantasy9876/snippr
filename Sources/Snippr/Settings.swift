import AppKit
import Carbon.HIToolbox

// MARK: - Enums (raw values are persisted in UserDefaults — keep stable)

enum WindowBGStyle: String, CaseIterable {
    case wallpaper, transparent, solid, trimShadow
    var label: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .transparent: return "Transparent"
        case .solid: return "Solid Color"
        case .trimShadow: return "Trim shadow"
        }
    }
}

enum SaveFormat: String, CaseIterable {
    case png, auto
    var label: String { self == .png ? "PNG" : "Auto (PNG/JPEG)" }
}

enum AfterCropShow: String, CaseIterable {
    case thumbnail, editor
    var label: String { self == .thumbnail ? "Thumbnail" : "Editor" }
}

enum HidePreviewMode: String, CaseIterable {
    case manual, after3s, after10s
    var label: String {
        switch self {
        case .manual: return "Manually (close button)"
        case .after3s: return "After 3 seconds"
        case .after10s: return "After 10 seconds"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .after3s: return 3
        case .after10s: return 10
        }
    }
}

enum ConfirmationStyle: String, CaseIterable {
    case custom, system, none
    var label: String {
        switch self {
        case .custom: return "Custom Notification"
        case .system: return "System Notification"
        case .none: return "None"
        }
    }
}

enum OCRLanguage: String, CaseIterable {
    case englishPlus, vietnamesePlus, auto
    var label: String {
        switch self {
        case .englishPlus: return "English+"
        case .vietnamesePlus: return "Vietnamese+"
        case .auto: return "Auto"
        }
    }
    var visionLanguages: [String] {
        switch self {
        case .englishPlus: return ["en-US", "vi-VN"]
        case .vietnamesePlus: return ["vi-VN", "en-US"]
        case .auto: return []
        }
    }
}

// MARK: - Key combo (global hotkeys, Carbon modifiers)

struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon: cmdKey, shiftKey, optionKey, controlKey

    var encoded: String { "\(keyCode):\(modifiers)" }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: ":")
        guard parts.count == 2, let kc = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: kc, modifiers: m)
    }

    init(nsEvent event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCombo.keyName(for: keyCode)
        return s
    }

    var nsModifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    var keyEquivalent: String {
        let name = KeyCombo.keyName(for: keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    static func keyName(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Grave): "`",
        ]
        return map[keyCode] ?? "key\(keyCode)"
    }
}

// MARK: - Hotkey actions

enum HotkeyAction: String, CaseIterable {
    case fullscreen, area, repeatArea, anyWindow, activeWindow, scrolling, showApp, ocr

    var label: String {
        switch self {
        case .fullscreen: return "Fullscreen screenshot"
        case .area: return "Area screenshot"
        case .repeatArea: return "Repeat area screenshot"
        case .anyWindow: return "Any window screenshot"
        case .activeWindow: return "Active window screenshot"
        case .scrolling: return "Scrolling screenshot"
        case .showApp: return "Show Snippr"
        case .ocr: return "Instant Text/QR Recognition"
        }
    }

    var defaultCombo: KeyCombo? {
        switch self {
        case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey))
        case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey))
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | optionKey | controlKey))
        default: return nil
        }
    }

    var settingsKey: String { "hotkey_\(rawValue)" }
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    struct Keys {
        static let windowBGStyle = "windowBGStyle"
        static let windowBGColor = "windowBGColor"
        static let screenshotsFolder = "screenshotsFolder"
        static let saveFormat = "saveFormat"
        static let downscaleRetina = "downscaleRetina"
        static let scrollMaxHeight = "scrollMaxHeight"
        static let afterShow = "afterShow"
        static let afterCopy = "afterCopy"
        static let afterSave = "afterSave"
        static let afterCropShow = "afterCropShow"
        static let hidePreviewMode = "hidePreviewMode"
        static let ocrLanguage = "ocrLanguage"
        static let ocrRemoveLineBreaks = "ocrRemoveLineBreaks"
        static let hideMenubarIcon = "hideMenubarIcon"
        static let noSplash = "noSplash"
        static let alwaysOnTop = "alwaysOnTop"
        static let zoomReverseScroll = "zoomReverseScroll"
        static let preferZoom100 = "preferZoom100"
        static let escCopy = "escCopy"
        static let escSave = "escSave"
        static let confirmationStyle = "confirmationStyle"
        static let urlSchemeEnabled = "urlSchemeEnabled"
        static let diagnostics = "diagnostics"
        static let lastAreaRect = "lastAreaRect"
        static let uploadProvider = "uploadProvider"
        static let lastAnnotationColor = "lastAnnotationColor"
        static let translateTarget = "translateTarget"
    }

    /// Per-tool stroke width, remembered across sessions ("nét vẽ history").
    func toolWidth(for toolRawValue: String) -> CGFloat {
        let v = d.double(forKey: "toolWidth_\(toolRawValue)")
        return v > 0 ? CGFloat(min(20, max(1, v))) : 3
    }

    func setToolWidth(_ width: CGFloat, for toolRawValue: String) {
        d.set(Double(min(20, max(1, width))), forKey: "toolWidth_\(toolRawValue)")
    }

    var lastAnnotationColor: NSColor {
        get { NSColor(hex: d.string(forKey: Keys.lastAnnotationColor) ?? "") ?? .systemRed }
        set { d.set(newValue.hexString, forKey: Keys.lastAnnotationColor) }
    }

    var translateTarget: String {
        get { d.string(forKey: Keys.translateTarget) ?? "vi" }
        set { d.set(newValue, forKey: Keys.translateTarget) }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.windowBGStyle: WindowBGStyle.transparent.rawValue,
            Keys.windowBGColor: "#FFFFFF",
            Keys.saveFormat: SaveFormat.auto.rawValue,
            Keys.downscaleRetina: false,
            Keys.scrollMaxHeight: 20_000,
            Keys.afterShow: true,
            Keys.afterCopy: false,
            Keys.afterSave: false,
            Keys.afterCropShow: AfterCropShow.editor.rawValue,
            Keys.hidePreviewMode: HidePreviewMode.manual.rawValue,
            Keys.ocrLanguage: OCRLanguage.englishPlus.rawValue,
            Keys.ocrRemoveLineBreaks: false,
            Keys.hideMenubarIcon: false,
            Keys.noSplash: false,
            Keys.alwaysOnTop: false,
            Keys.zoomReverseScroll: false,
            Keys.preferZoom100: true,
            Keys.escCopy: true,
            Keys.escSave: false,
            Keys.confirmationStyle: ConfirmationStyle.custom.rawValue,
            Keys.urlSchemeEnabled: false,
            Keys.diagnostics: true,
            Keys.uploadProvider: "disabled",
        ])
    }

    var windowBGStyle: WindowBGStyle {
        get { WindowBGStyle(rawValue: d.string(forKey: Keys.windowBGStyle) ?? "") ?? .transparent }
        set { d.set(newValue.rawValue, forKey: Keys.windowBGStyle) }
    }

    var windowBGColor: NSColor {
        get { NSColor(hex: d.string(forKey: Keys.windowBGColor) ?? "#FFFFFF") ?? .white }
        set { d.set(newValue.hexString, forKey: Keys.windowBGColor) }
    }

    var screenshotsFolder: URL {
        get {
            if let path = d.string(forKey: Keys.screenshotsFolder), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { d.set(newValue.path, forKey: Keys.screenshotsFolder) }
    }

    var saveFormat: SaveFormat {
        get { SaveFormat(rawValue: d.string(forKey: Keys.saveFormat) ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: Keys.saveFormat) }
    }

    var downscaleRetina: Bool {
        get { d.bool(forKey: Keys.downscaleRetina) }
        set { d.set(newValue, forKey: Keys.downscaleRetina) }
    }

    /// Page-length cap for scrolling capture, in points.
    var scrollMaxHeight: Int {
        get { max(1000, d.integer(forKey: Keys.scrollMaxHeight)) }
        set { d.set(newValue, forKey: Keys.scrollMaxHeight) }
    }

    var afterShow: Bool {
        get { d.bool(forKey: Keys.afterShow) }
        set { d.set(newValue, forKey: Keys.afterShow) }
    }
    var afterCopy: Bool {
        get { d.bool(forKey: Keys.afterCopy) }
        set { d.set(newValue, forKey: Keys.afterCopy) }
    }
    var afterSave: Bool {
        get { d.bool(forKey: Keys.afterSave) }
        set { d.set(newValue, forKey: Keys.afterSave) }
    }

    var afterCropShow: AfterCropShow {
        get { AfterCropShow(rawValue: d.string(forKey: Keys.afterCropShow) ?? "") ?? .editor }
        set { d.set(newValue.rawValue, forKey: Keys.afterCropShow) }
    }

    var hidePreviewMode: HidePreviewMode {
        get { HidePreviewMode(rawValue: d.string(forKey: Keys.hidePreviewMode) ?? "") ?? .manual }
        set { d.set(newValue.rawValue, forKey: Keys.hidePreviewMode) }
    }

    var ocrLanguage: OCRLanguage {
        get { OCRLanguage(rawValue: d.string(forKey: Keys.ocrLanguage) ?? "") ?? .englishPlus }
        set { d.set(newValue.rawValue, forKey: Keys.ocrLanguage) }
    }

    var ocrRemoveLineBreaks: Bool {
        get { d.bool(forKey: Keys.ocrRemoveLineBreaks) }
        set { d.set(newValue, forKey: Keys.ocrRemoveLineBreaks) }
    }

    var hideMenubarIcon: Bool {
        get { d.bool(forKey: Keys.hideMenubarIcon) }
        set { d.set(newValue, forKey: Keys.hideMenubarIcon) }
    }

    var alwaysOnTop: Bool {
        get { d.bool(forKey: Keys.alwaysOnTop) }
        set { d.set(newValue, forKey: Keys.alwaysOnTop) }
    }

    var zoomReverseScroll: Bool {
        get { d.bool(forKey: Keys.zoomReverseScroll) }
        set { d.set(newValue, forKey: Keys.zoomReverseScroll) }
    }

    var preferZoom100: Bool {
        get { d.bool(forKey: Keys.preferZoom100) }
        set { d.set(newValue, forKey: Keys.preferZoom100) }
    }

    var escCopy: Bool {
        get { d.bool(forKey: Keys.escCopy) }
        set { d.set(newValue, forKey: Keys.escCopy) }
    }
    var escSave: Bool {
        get { d.bool(forKey: Keys.escSave) }
        set { d.set(newValue, forKey: Keys.escSave) }
    }

    var confirmationStyle: ConfirmationStyle {
        get { ConfirmationStyle(rawValue: d.string(forKey: Keys.confirmationStyle) ?? "") ?? .custom }
        set { d.set(newValue.rawValue, forKey: Keys.confirmationStyle) }
    }

    var urlSchemeEnabled: Bool {
        get { d.bool(forKey: Keys.urlSchemeEnabled) }
        set { d.set(newValue, forKey: Keys.urlSchemeEnabled) }
    }

    var lastAreaRect: CGRect? {
        get {
            guard let s = d.string(forKey: Keys.lastAreaRect) else { return nil }
            let p = s.split(separator: ",").compactMap { Double($0) }
            guard p.count == 4 else { return nil }
            return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        }
        set {
            if let r = newValue {
                d.set("\(r.origin.x),\(r.origin.y),\(r.width),\(r.height)", forKey: Keys.lastAreaRect)
            } else {
                d.removeObject(forKey: Keys.lastAreaRect)
            }
        }
    }

    func combo(for action: HotkeyAction) -> KeyCombo? {
        if let s = d.string(forKey: action.settingsKey) {
            return s.isEmpty ? nil : KeyCombo(encoded: s)
        }
        return action.defaultCombo
    }

    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        d.set(combo?.encoded ?? "", forKey: action.settingsKey)
    }
}

// MARK: - NSColor hex helpers

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
