import AppKit
import ScreenCaptureKit

enum CaptureSource {
    case fullscreen, area, window, scrolling
}

/// Shared error/result plumbing used by capture flows.
enum AppServices {
    static func handleCaptureError(_ error: Error) {
        if case CaptureError.permission = error {
            ToastHUD.show("Screen Recording permission needed — enable Snippr in System Settings", symbol: "exclamationmark.shield.fill", duration: 5)
            openScreenRecordingSettings()
        } else if case CaptureError.cancelled = error {
            // silent
        } else {
            ToastHUD.show("Capture failed", symbol: "exclamationmark.triangle.fill")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var lastCapture: CapturedImage?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        writeLaunchStatus()
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        HotkeyManager.shared.handler = { [weak self] action in
            self?.perform(hotkey: action)
        }
        HotkeyManager.shared.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )

        if !UserDefaults.standard.bool(forKey: Settings.Keys.noSplash) {
            ToastHUD.show("Snippr is running — ⇧⌘1 screen · ⇧⌘2 area", symbol: "camera.viewfinder", duration: 3)
        }

        UITest.runIfRequested()
    }

    /// Debug breadcrumb: lets tooling confirm the app booted and see its TCC state.
    private func writeLaunchStatus() {
        let status = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        screenRecording=\(CGPreflightScreenCaptureAccess())
        accessibility=\(AXIsProcessTrusted())
        launchedAt=\(Date())
        """
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snippr")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? status.write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard Settings.shared.urlSchemeEnabled else {
            ToastHUD.show("URL scheme is disabled in Advanced settings", symbol: "link.badge.plus")
            return
        }
        for url in urls where url.scheme == "snippr" {
            switch url.host {
            case "capture":
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let type = comps?.queryItems?.first(where: { $0.name == "type" })?.value ?? "area"
                switch type {
                case "fullscreen": captureFullscreen()
                case "window": captureActiveWindow()
                case "scrolling": startScrolling(direction: .down)
                default: captureArea()
                }
            case "ocr":
                OCRService.shared.instantOCRFlow()
            case "clipboard":
                menuLoadClipboard()
            default:
                break
            }
            logEvent("url-handled \(url.absoluteString)")
        }
    }

    private func logEvent(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snippr")
        let url = dir.appendingPathComponent("events.log")
        let entry = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.isVisible = !Settings.shared.hideMenubarIcon
        }
    }

    // MARK: status item & menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snippr"
        )
        item.menu = buildMenu()
        item.isVisible = !Settings.shared.hideMenubarIcon
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ selector: Selector?, action: HotkeyAction? = nil,
                 symbol: String? = nil, to target: NSMenu = menu) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            if let action, let combo = Settings.shared.combo(for: action) {
                item.keyEquivalent = combo.keyEquivalent
                item.keyEquivalentModifierMask = combo.nsModifierFlags
            }
            target.addItem(item)
        }

        add("Reopen Snippr", #selector(reopen), symbol: "arrow.uturn.forward.square")
        menu.addItem(.separator())
        add("Capture Screen", #selector(menuCaptureScreen), action: .fullscreen, symbol: "macwindow")
        add("Capture Area", #selector(menuCaptureArea), action: .area, symbol: "rectangle.dashed")
        add("Scrolling Capture", #selector(menuScrolling), action: .scrolling, symbol: "arrow.down.doc")
        add("Recognize Text/QR", #selector(menuOCR), action: .ocr, symbol: "text.viewfinder")

        let moreItem = NSMenuItem(title: "more", action: nil, keyEquivalent: "")
        moreItem.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        let moreMenu = NSMenu()
        add("Repeat Area Capture", #selector(menuRepeatArea), action: .repeatArea, symbol: "rectangle.dashed.badge.record", to: moreMenu)
        add("Capture Active Window", #selector(menuActiveWindow), action: .activeWindow, symbol: "macwindow.on.rectangle", to: moreMenu)
        add("Capture Any Window", #selector(menuAnyWindow), action: .anyWindow, symbol: "macwindow.badge.plus", to: moreMenu)
        add("Delayed Screenshot (3s)", #selector(menuDelayed), symbol: "timer", to: moreMenu)
        moreMenu.addItem(.separator())
        add("Open File", #selector(menuOpenFile), symbol: "doc", to: moreMenu)
        add("Load From Clipboard", #selector(menuLoadClipboard), symbol: "doc.on.clipboard", to: moreMenu)
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)

        menu.addItem(.separator())
        add("About Snippr", #selector(openAbout))
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Startup", action: #selector(toggleLaunch), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        add("Quit", #selector(quit))

        menu.delegate = self
        return menu
    }

    // MARK: hotkey routing

    private func perform(hotkey: HotkeyAction) {
        switch hotkey {
        case .fullscreen: captureFullscreen()
        case .area: captureArea()
        case .repeatArea: repeatAreaCapture()
        case .anyWindow: captureAnyWindow()
        case .activeWindow: captureActiveWindow()
        case .scrolling: startScrolling(direction: .down)
        case .showApp: reopen()
        case .ocr: OCRService.shared.instantOCRFlow()
        }
    }

    // MARK: menu actions

    @objc private func reopen() {
        if let last = lastCapture {
            EditorWindowController.open(with: last)
        } else {
            PreferencesWindowController.show()
        }
    }

    @objc private func menuCaptureScreen() { captureFullscreen() }
    @objc private func menuCaptureArea() { captureArea() }
    @objc private func menuScrolling() { startScrolling(direction: .down) }
    @objc private func menuScrollingUp() { startScrolling(direction: .up) }
    @objc private func menuOCR() { OCRService.shared.instantOCRFlow() }
    @objc private func menuRepeatArea() { repeatAreaCapture() }
    @objc private func menuActiveWindow() { captureActiveWindow() }
    @objc private func menuAnyWindow() { captureAnyWindow() }

    @objc private func menuDelayed() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            captureFullscreen()
        }
    }

    @objc private func menuOpenFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .webP]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            openInEditor(nsImage: img)
        }
    }

    @objc private func menuLoadClipboard() {
        guard let img = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil
        )?.first as? NSImage else {
            ToastHUD.show("No image in clipboard", symbol: "doc.on.clipboard")
            return
        }
        openInEditor(nsImage: img)
    }

    @objc private func openAbout() { PreferencesWindowController.show() }

    @objc private func toggleLaunch() {
        LaunchAtLogin.toggle()
        statusItem?.menu = buildMenu()
    }

    @objc private func openSettings() { PreferencesWindowController.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    private func openInEditor(nsImage: NSImage) {
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = nsImage.size.width > 0 ? CGFloat(cg.width) / nsImage.size.width : 1
        let captured = CapturedImage(cgImage: cg, scale: max(1, scale))
        lastCapture = captured
        logEvent("editor-opened px=\(cg.width)x\(cg.height)")
        EditorWindowController.open(with: captured)
    }

    // MARK: capture flows

    private func screenUnderMouse() -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func captureFullscreen() {
        let screen = screenUnderMouse()
        Task { @MainActor in
            do {
                let shot = try await CaptureEngine.shared.captureDisplay(screen: screen)
                handleResult(shot, source: .fullscreen)
            } catch {
                AppServices.handleCaptureError(error)
            }
        }
    }

    private func captureArea() {
        SelectionOverlay.begin(mode: .area) { [weak self] result in
            guard case let .area(screen, frozen, rect) = result,
                  let cropped = frozen.cropping(toViewRect: rect) else { return }
            // remember for Repeat Area Capture (global AppKit coords)
            let global = CGRect(
                x: rect.minX + screen.frame.minX, y: rect.minY + screen.frame.minY,
                width: rect.width, height: rect.height
            )
            Settings.shared.lastAreaRect = global
            self?.handleResult(cropped, source: .area)
        }
    }

    private func repeatAreaCapture() {
        guard let global = Settings.shared.lastAreaRect else {
            ToastHUD.show("No previous area — use Capture Area first", symbol: "rectangle.dashed")
            captureArea()
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(global) }) else { return }
        let local = CGRect(
            x: global.minX - screen.frame.minX, y: global.minY - screen.frame.minY,
            width: global.width, height: global.height
        )
        Task { @MainActor in
            do {
                let full = try await CaptureEngine.shared.captureDisplay(screen: screen)
                if let cropped = full.cropping(toViewRect: local) {
                    handleResult(cropped, source: .area)
                }
            } catch {
                AppServices.handleCaptureError(error)
            }
        }
    }

    private func captureActiveWindow() {
        guard let info = CaptureEngine.frontmostWindow() else {
            ToastHUD.show("No window found", symbol: "macwindow")
            return
        }
        captureWindow(info)
    }

    private func captureAnyWindow() {
        SelectionOverlay.begin(mode: .windowPick) { [weak self] result in
            guard case let .window(info) = result else { return }
            self?.captureWindow(info)
        }
    }

    private func captureWindow(_ info: WindowInfo) {
        Task { @MainActor in
            do {
                let shot = try await CaptureEngine.shared.captureWindow(windowID: info.windowID)
                let screen = CaptureEngine.screenContaining(cgRect: info.frameCG)
                let composed = CaptureEngine.composeWindowShot(
                    shot, style: Settings.shared.windowBGStyle, screen: screen
                )
                handleResult(composed, source: .window)
            } catch {
                AppServices.handleCaptureError(error)
            }
        }
    }

    private func startScrolling(direction: ScrollingCapture.Direction) {
        ScrollingCapture.begin(direction: direction) { [weak self] image in
            guard let image else { return }
            self?.handleResult(image, source: .scrolling)
        }
    }

    // MARK: result routing

    private func handleResult(_ image: CapturedImage, source: CaptureSource) {
        lastCapture = image
        logEvent("capture source=\(source) px=\(image.cgImage.width)x\(image.cgImage.height)")
        let s = Settings.shared
        var toasts: [String] = []

        if s.afterCopy {
            SaveService.shared.copyToClipboard(image)
            toasts.append("copied")
        }
        if s.afterSave {
            if let url = SaveService.shared.save(image) {
                toasts.append("saved \(url.lastPathComponent)")
            }
        }

        if s.afterShow {
            if source == .area && s.afterCropShow == .thumbnail {
                ThumbnailHUD.show(image) { img in
                    EditorWindowController.open(with: img)
                }
            } else {
                EditorWindowController.open(with: image)
            }
        } else if !toasts.isEmpty {
            ToastHUD.show("Screenshot \(toasts.joined(separator: " · "))")
        } else {
            // nothing configured — at least copy so the shot isn't lost
            SaveService.shared.copyToClipboard(image)
            ToastHUD.show("Screenshot copied to clipboard")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // refresh Launch at Startup checkmark & hotkey badges
        if let item = menu.items.first(where: { $0.title == "Launch at Startup" }) {
            item.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }
}
