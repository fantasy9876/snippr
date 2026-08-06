import SwiftUI
import ServiceManagement

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Snippr: launch-at-login failed: \(error)")
        }
    }

    static func toggle() { set(!isEnabled) }
}

// MARK: - Window controller

/// Which Preferences tab is showing — lets the menu open a specific one.
@MainActor
final class PreferencesSelection: ObservableObject {
    static let shared = PreferencesSelection()
    @Published var tab: PreferencesTab = .general
}

enum PreferencesTab: Hashable {
    case general, hotkeys, uploading, advanced, about
}

final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private static var window: NSWindow?
    private static var delegateHolder: PreferencesWindowController?

    @MainActor
    static func show(tab: PreferencesTab = .general) {
        PreferencesSelection.shared.tab = tab
        if let window {
            window.orderFrontRegardless()
            AppActivation.activateNow()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: PreferencesRoot())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Preferences"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        let holder = PreferencesWindowController()
        win.delegate = holder
        delegateHolder = holder
        window = win
        win.orderFrontRegardless()
        AppActivation.activateNow()
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root

struct PreferencesRoot: View {
    @ObservedObject private var selection = PreferencesSelection.shared

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PreferencesTab.general)
            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(PreferencesTab.hotkeys)
            UploadingTab()
                .tabItem { Label("Uploading", systemImage: "icloud.and.arrow.up") }
                .tag(PreferencesTab.uploading)
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wand.and.stars") }
                .tag(PreferencesTab.advanced)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(PreferencesTab.about)
        }
        .frame(width: 600)
        .padding(.bottom, 8)
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 230, alignment: .trailing)
                .foregroundStyle(.primary)
            content
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Window background style cards (visual picker)

/// Visual previews: each card shows what the window screenshot will
/// look like with that background. Click a card to choose.
private struct BGStyleCard: View {
    let style: WindowBGStyle
    let isSelected: Bool
    var solidColor: Color = .white

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                cardBackground
                miniWindow
            }
            .frame(width: 110, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.35),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            Text(style.label)
                .font(.callout)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .help(helpText)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    @ViewBuilder private var cardBackground: some View {
        switch style {
        case .wallpaper:
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.45, blue: 0.95),
                    Color(red: 0.30, green: 0.75, blue: 0.85),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .transparent:
            Checkerboard()
        case .solid:
            solidColor
        case .trimShadow:
            Color.black.opacity(0.001) // no backdrop — the window is all there is
        }
    }

    private var miniWindow: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(white: 0.24))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3.5) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 5.5, height: 5.5)
                    Circle().fill(Color(red: 1, green: 0.75, blue: 0.18)).frame(width: 5.5, height: 5.5)
                    Circle().fill(Color(red: 0.22, green: 0.79, blue: 0.25)).frame(width: 5.5, height: 5.5)
                }
                .padding(6)
            }
            .frame(
                width: style == .trimShadow ? 92 : 66,
                height: style == .trimShadow ? 60 : 44
            )
            .shadow(
                color: style == .trimShadow ? .clear : .black.opacity(0.55),
                radius: 7, y: 4
            )
    }

    private var helpText: String {
        switch style {
        case .wallpaper: return "Window on top of your desktop wallpaper"
        case .transparent: return "Padding with transparency — great for pasting into docs (PNG)"
        case .solid: return "Window on a solid color backdrop"
        case .trimShadow: return "Just the window — no padding, no shadow"
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var col = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + col) % 2 == 0 {
                        ctx.fill(
                            Path(CGRect(x: x, y: y, width: s, height: s)),
                            with: .color(.gray.opacity(0.4))
                        )
                    }
                    col += 1
                    x += s
                }
                row += 1
                y += s
            }
        }
        .background(Color.gray.opacity(0.15))
    }
}

// MARK: - General

struct GeneralTab: View {
    @AppStorage(Settings.Keys.windowBGStyle) private var bgStyle = WindowBGStyle.transparent.rawValue
    @AppStorage(Settings.Keys.saveFormat) private var saveFormat = SaveFormat.auto.rawValue
    @AppStorage(Settings.Keys.downscaleRetina) private var downscale = false
    @AppStorage(Settings.Keys.scrollMaxHeight) private var scrollMax = 20_000
    @AppStorage(Settings.Keys.scrollSpeed) private var scrollSpeed = 0.6
    @AppStorage(Settings.Keys.afterShow) private var afterShow = true
    @AppStorage(Settings.Keys.afterCopy) private var afterCopy = false
    @AppStorage(Settings.Keys.afterSave) private var afterSave = false
    @AppStorage(Settings.Keys.afterCropShow) private var afterCrop = AfterCropShow.editor.rawValue
    @AppStorage(Settings.Keys.hidePreviewMode) private var hidePreview = HidePreviewMode.manual.rawValue
    @State private var folderLabel = Settings.shared.screenshotsFolder.path
    @State private var launchAtStartup = LaunchAtLogin.isEnabled
    @State private var bgColor = Color(nsColor: Settings.shared.windowBGColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // visual picker — click a preview card to choose the backdrop
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Window Screenshot Background")
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help("The backdrop drawn behind Capture Active/Any Window shots. Hover a preview for details.")
                }
                HStack(spacing: 14) {
                    ForEach(WindowBGStyle.allCases, id: \.rawValue) { style in
                        BGStyleCard(
                            style: style,
                            isSelected: bgStyle == style.rawValue,
                            solidColor: bgColor
                        )
                        .onTapGesture { bgStyle = style.rawValue }
                    }
                }
                // always occupies its row — hidden (not removed) when unused,
                // so switching cards never shifts the layout
                ColorPicker("Backdrop color:", selection: $bgColor, supportsOpacity: false)
                    .onChange(of: bgColor) { _, new in
                        Settings.shared.windowBGColor = NSColor(new)
                    }
                    .opacity(bgStyle == WindowBGStyle.solid.rawValue ? 1 : 0)
                    .disabled(bgStyle != WindowBGStyle.solid.rawValue)
                    .accessibilityHidden(bgStyle != WindowBGStyle.solid.rawValue)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Row(label: "Screenshots folder") {
                Button(action: pickFolder) {
                    Text(folderLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300)
                }
            }
            Row(label: "Save format") {
                Picker("", selection: $saveFormat) {
                    ForEach(SaveFormat.allCases, id: \.rawValue) { f in
                        Text(f.label).tag(f.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            Row(label: "Resize retina screenshots") {
                Toggle("Downscale to 1× when saving", isOn: $downscale)
            }

            Divider()

            Row(label: "Scrolling screenshot max height") {
                TextField("", value: $scrollMax, format: .number)
                    .frame(width: 90)
                Text("px").foregroundStyle(.secondary)
            }
            Row(label: "Scrolling screenshot speed") {
                Slider(value: $scrollSpeed, in: 0...1)
                    .frame(width: 240)
            }

            Divider()

            Row(label: "Autostart") {
                Toggle("Launch at startup", isOn: $launchAtStartup)
                    .onChange(of: launchAtStartup) { _, new in
                        LaunchAtLogin.set(new)
                        launchAtStartup = LaunchAtLogin.isEnabled
                    }
            }
            Row(label: "After screenshot") {
                Toggle("Show", isOn: $afterShow)
                Toggle("Copy", isOn: $afterCopy)
                Toggle("Save", isOn: $afterSave)
            }
            Row(label: "After Area Crop, show") {
                Picker("", selection: $afterCrop) {
                    ForEach(AfterCropShow.allCases, id: \.rawValue) { c in
                        Text(c.label).tag(c.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            Row(label: "Hide preview thumbnail") {
                Picker("", selection: $hidePreview) {
                    ForEach(HidePreviewMode.allCases, id: \.rawValue) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.screenshotsFolder
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.screenshotsFolder = url
            folderLabel = url.path
        }
    }
}

// MARK: - Hotkeys

struct HotkeysTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How to reassign default shortcuts").bold()
                Text("1. Go to System Settings → Keyboard → Keyboard Shortcuts")
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                    )
                }
                Text("2. Select “Screenshots” and uncheck the system shortcuts")
                Text("3. Put ⌘⇧3 into Fullscreen and ⌘⇧4 into Area fields below")
            }
            .font(.callout)

            Divider()

            ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                HStack {
                    Text(action.label)
                        .frame(width: 230, alignment: .trailing)
                    KeyRecorderField(action: action)
                        .frame(width: 160, height: 24)
                    Spacer()
                }
            }
        }
        .padding(24)
    }
}

/// Click, then press a key combo to record a global hotkey.
struct KeyRecorderField: NSViewRepresentable {
    let action: HotkeyAction

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.hotkeyAction = action
        return b
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.hotkeyAction = action
        nsView.refreshTitle()
    }
}

final class RecorderButton: NSButton {
    var hotkeyAction: HotkeyAction? {
        didSet { refreshTitle() }
    }
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        this()
    }

    private func this() {
        self.action = #selector(startRecording)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        if recording {
            title = "Type shortcut…"
        } else if let a = hotkeyAction, let combo = Settings.shared.combo(for: a) {
            title = combo.display + "   ⓧ"
        } else {
            title = "Record Shortcut"
        }
    }

    @objc private func startRecording() {
        if !recording, let a = hotkeyAction, Settings.shared.combo(for: a) != nil {
            // click on an assigned shortcut clears it
            Settings.shared.setCombo(nil, for: a)
            HotkeyManager.shared.reloadAll()
            refreshTitle()
            return
        }
        recording = true
        refreshTitle()
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        refreshTitle()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        recording = false
        if event.keyCode == 53 { // Esc cancels
            refreshTitle()
            return
        }
        let combo = KeyCombo(nsEvent: event)
        // Carbon F-key codes are NOT contiguous (F1=122 … F12=111) — a range
        // literal here traps at runtime, so use an explicit set
        let fKeyCodes: Set<UInt32> = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        ]
        let isFKey = fKeyCodes.contains(combo.keyCode)
        guard combo.modifiers != 0 || isFKey else {
            refreshTitle()
            return
        }
        if let a = hotkeyAction {
            Settings.shared.setCombo(combo, for: a)
            HotkeyManager.shared.reloadAll()
        }
        refreshTitle()
    }
}

import Carbon.HIToolbox

// MARK: - Uploading

struct UploadingTab: View {
    @AppStorage(Settings.Keys.uploadProvider) private var provider = "disabled"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Image Uploading & Link Sharing").bold()
            Picker("", selection: $provider) {
                Text("Disable Uploading").tag("disabled")
            }
            .labelsHidden()
            .frame(width: 480)

            Text("Snippr keeps every screenshot on this Mac. Cloud upload providers can be plugged in here in a future version — nothing is ever sent anywhere by default.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 460)
            Spacer()
        }
        .padding(24)
        .frame(minHeight: 240)
    }
}

// MARK: - Advanced

struct AdvancedTab: View {
    @AppStorage(Settings.Keys.ocrLanguage) private var ocrLang = OCRLanguage.englishPlus.rawValue
    @AppStorage(Settings.Keys.ocrRemoveLineBreaks) private var removeBreaks = false
    @AppStorage(Settings.Keys.hideMenubarIcon) private var hideIcon = false
    @AppStorage(Settings.Keys.noSplash) private var noSplash = false
    @AppStorage(Settings.Keys.alwaysOnTop) private var alwaysOnTop = false
    @AppStorage(Settings.Keys.zoomReverseScroll) private var zoomReverse = false
    @AppStorage(Settings.Keys.scrollingReverse) private var scrollReverse = false
    @AppStorage(Settings.Keys.preferZoom100) private var prefer100 = true
    @AppStorage(Settings.Keys.escCopy) private var escCopy = true
    @AppStorage(Settings.Keys.escSave) private var escSave = false
    @AppStorage(Settings.Keys.confirmationStyle) private var confirmStyle = ConfirmationStyle.custom.rawValue
    @AppStorage(Settings.Keys.urlSchemeEnabled) private var urlScheme = false
    @AppStorage(Settings.Keys.diagnostics) private var diagnostics = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Row(label: "Primary OCR language") {
                Picker("", selection: $ocrLang) {
                    ForEach(OCRLanguage.allCases, id: \.rawValue) { l in
                        Text(l.label).tag(l.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Row(label: "OCR line breaks") {
                Toggle("Remove line breaks", isOn: $removeBreaks)
            }
            Row(label: "Menubar icon") {
                Toggle("Hide menubar icon", isOn: $hideIcon)
                    .help("Reopen Snippr from Finder or with the Show Snippr hotkey")
            }
            Row(label: "Splash window") {
                Toggle("Don't show splash", isOn: $noSplash)
            }
            Row(label: "Main window") {
                Toggle("Always on top", isOn: $alwaysOnTop)
            }
            Row(label: "Zoom with mouse wheel") {
                Toggle("Reverse scroll direction", isOn: $zoomReverse)
            }
            Row(label: "Scrolling capture") {
                Toggle("Reverse scroll direction", isOn: $scrollReverse)
            }
            Row(label: "Default zoom level") {
                Toggle("Prefer 100%", isOn: $prefer100)
            }
            Row(label: "Action when hiding with Esc") {
                Toggle("Copy Image", isOn: $escCopy)
                Toggle("Save Image", isOn: $escSave)
            }
            Row(label: "Confirmation style") {
                Picker("", selection: $confirmStyle) {
                    ForEach(ConfirmationStyle.allCases, id: \.rawValue) { c in
                        Text(c.label).tag(c.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Row(label: "URL Scheme API") {
                Toggle("Enable deep links", isOn: $urlScheme)
                    .help("snippr://capture?type=area|fullscreen|window · snippr://ocr")
            }
            Row(label: "Diagnostics information") {
                Toggle("Allow collection", isOn: $diagnostics)
            }

            Text("Snippr collects nothing at all — this toggle exists for symmetry with the app it pays homage to. Screenshots never leave this computer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(24)
    }
}

// MARK: - About / License

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
            Text("Snippr").font(.title).bold()
            Text("Version 1.1.8 — native for Apple Silicon & Intel")
                .foregroundStyle(.secondary)
            Divider().frame(width: 300)
            Text("Free for personal use. Screenshot, annotate, OCR,\nscrolling capture — everything stays on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Made with Claude Code 🤖")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minHeight: 280)
    }
}
