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

final class PreferencesWindowController {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PreferencesRoot())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Preferences"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root

struct PreferencesRoot: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            UploadingTab()
                .tabItem { Label("Uploading", systemImage: "icloud.and.arrow.up") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wand.and.stars") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
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
            Row(label: "Window Screenshot Background") {
                Picker("", selection: $bgStyle) {
                    ForEach(WindowBGStyle.allCases, id: \.rawValue) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 330)
            }
            if bgStyle == WindowBGStyle.solid.rawValue {
                Row(label: "Background color") {
                    ColorPicker("", selection: $bgColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: bgColor) { _, new in
                            Settings.shared.windowBGColor = NSColor(new)
                        }
                }
            }

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
        let isFKey = (UInt32(kVK_F1)...UInt32(kVK_F12)).contains(combo.keyCode)
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
            Text("Version 1.0.1 — native Apple Silicon (arm64)")
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
