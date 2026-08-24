import AppKit
import ScreenCaptureKit

enum CaptureSource {
    case fullscreen, area, window, scrolling
    /// Interactive in-place area review (Lightshot flow). Distinct from
    /// legacy `.area`, which Repeat Area still uses — the router honors
    /// `finalGlobalRect` only for this source.
    case areaReview
    /// Stitched scroll result presented on the in-place panel (not the
    /// legacy `handleResult` scrolling route).
    case scrollResult
}

/// Shared error/result plumbing used by capture flows.
enum AppServices {
    /// The most recent capture, shared between the legacy result routing and
    /// the overlay action router ("open last", Repeat-related features).
    @MainActor static var lastCapture: CapturedImage?

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
    private var screenParametersObserver: NSObjectProtocol?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let devToolFlags = [
            "--uitest", "--benchmark", "--test-firstopen", "--test-scrollpreview",
            "--test-scrollstitch", "--test-scrollreal", "--test-scrollapp",
            "--test-scrollreplay", "--test-scrollreplay-split",
            "--test-panel-hid",
        ]
        let isDevTool = devToolFlags.contains { CommandLine.arguments.contains($0) }
        let captureDevToolFlags = [
            "--benchmark", "--test-firstopen", "--test-scrollpreview", "--test-scrollstitch",
            "--test-scrollreal", "--test-scrollapp",
        ]
        let needsCaptureServices = !isDevTool
            || captureDevToolFlags.contains { CommandLine.arguments.contains($0) }

        // FIRST decision of the launch: is this the installed Snippr? A wrong
        // copy (ad-hoc build in ~/Applications, DMG, Downloads) must not
        // create a status item, register hotkeys, write launch status or
        // prompt TCC — every one of those would bind state to the wrong
        // signature. Dev tools and SNIPPR_ALLOW_NONCANONICAL=1 may proceed.
        // The order below is BundleIntegrity.launchPlan (gated headlessly).
        // A canonical app starts normally and silently; only a process that is
        // itself running from the wrong bundle path is blocked.
        let disposition = BundleIntegrity.launchDisposition(
            for: BundleIntegrity.currentVerdict(),
            allowNonCanonical: isDevTool || BundleIntegrity.debugOverrideRequested)
        for step in BundleIntegrity.launchPlan(
            for: disposition, isDevTool: isDevTool,
            needsCaptureServices: needsCaptureServices) {
            switch step {
            case .presentWrongCopyAlertAndExit:
                guard case let .blockWrongCopy(running, canonicalExists) = disposition
                else { continue }
                BundleIntegrity.presentWrongCopyAlert(
                    running: running, canonicalExists: canonicalExists)
                exit(0)
            case .setupStatusItem:
                setupStatusItem()
            case .writeLaunchStatus:
                writeLaunchStatus()
            case .startHotkeys:
                HotkeyManager.shared.handler = { [weak self] action in
                    self?.perform(hotkey: action)
                }
                HotkeyManager.shared.start()
                NotificationCenter.default.addObserver(
                    self, selector: #selector(defaultsChanged),
                    name: UserDefaults.didChangeNotification, object: nil
                )
            case .requestScreenCapture:
                if !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                }
            }
        }

        if !isDevTool, !UserDefaults.standard.bool(forKey: Settings.Keys.noSplash) {
            ToastHUD.show("Snippr is running — ⇧⌘1 screen · ⇧⌘2 area", symbol: "camera.viewfinder", duration: 3)
        }

        // warm the slow paths while the user is idle: display list (~30 ms)
        // and the editor's AppKit machinery (~35 ms on first open)
        if needsCaptureServices { CaptureEngine.shared.prewarm() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            EditorWindowController.prewarm()
        }
        if needsCaptureServices {
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    CaptureEngine.shared.invalidateContentCache()
                    CaptureEngine.shared.prewarm()
                }
            }
        }

        UITest.runIfRequested()
        if Benchmark.requested { Benchmark.run() }
        if Benchmark.firstOpenTestRequested { Benchmark.runFirstOpenTest() }
        if let dir = Benchmark.scrollPreviewOutDir { Benchmark.runScrollPreviewTest(outDir: dir) }
        if Benchmark.scrollStitchTestRequested { Benchmark.runScrollStitchTest() }
        if let path = Benchmark.scrollReplayPath { Benchmark.runScrollReplayTest(path: path) }
        if let split = Benchmark.scrollReplaySplit {
            Benchmark.runScrollReplaySplitTest(path: split.path, topRows: split.topRows)
        }
        if let dir = Benchmark.scrollRealOutDir { Benchmark.runScrollRealTest(outDir: dir) }
        if Benchmark.scrollAppRequested { Benchmark.runScrollAppTest() }
        if Benchmark.panelHIDTestRequested { Benchmark.runPanelHIDTest() }
        if !isDevTool {
            UpdateChecker.checkOnLaunch()
        }
    }

    /// A quit (user, or the updater's terminate-and-relaunch) must not drop an
    /// in-flight background save — the screenshot would vanish or land as a
    /// truncated file. Waits for pending writes, with a 10 s failsafe.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SaveService.inFlightSaves > 0 else { return .terminateNow }
        SaveService.onSavesDrained = {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if SaveService.onSavesDrained != nil {
                SaveService.onSavesDrained = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    /// Debug breadcrumb: lets tooling confirm the app booted and see its TCC state.
    private func writeLaunchStatus() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let status = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        version=\(version)
        build=\(build)
        executable=\(Bundle.main.executableURL?.path ?? "")
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
                case "scrolling": startScrolling()
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
        EventLog.append(line)
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
        add("Check for Updates…", #selector(checkUpdates), symbol: "arrow.triangle.2.circlepath")
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

    /// Test hook: drives the exact same path a global hotkey does.
    func runHotkeyForTesting(_ action: HotkeyAction) {
        perform(hotkey: action)
    }

    // MARK: hotkey routing

    private func perform(hotkey: HotkeyAction) {
        switch hotkey {
        case .fullscreen: captureFullscreen()
        case .area: captureArea()
        case .repeatArea: repeatAreaCapture()
        case .anyWindow: captureAnyWindow()
        case .activeWindow: captureActiveWindow()
        case .scrolling: startScrolling()
        case .showApp: reopen()
        case .ocr: OCRService.shared.instantOCRFlow()
        }
    }

    // MARK: menu actions

    @objc private func reopen() {
        if let last = AppServices.lastCapture {
            EditorWindowController.open(with: last)
        } else {
            PreferencesWindowController.show()
        }
    }

    @objc private func menuCaptureScreen() { captureFullscreen() }
    @objc private func menuCaptureArea() { captureArea() }
    @objc private func menuScrolling() { startScrolling() }
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

    @objc private func openAbout() { PreferencesWindowController.show(tab: .about) }

    @objc private func checkUpdates() {
        Task { await UpdateChecker.check(manual: true) }
    }

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
        AppServices.lastCapture = captured
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
        let t0 = Date()
        Task { @MainActor in
            do {
                let shot = try await CaptureEngine.shared.captureDisplay(screen: screen)
                Perf.log("capture total", since: t0)
                let tEditor = Date()
                handleResult(shot, source: .fullscreen)
                Perf.log("handleResult→editor", since: tEditor)
                Perf.log("END-TO-END", since: t0)
            } catch {
                AppServices.handleCaptureError(error)
            }
        }
    }

    private func captureArea() {
        // The area-review overlay runs the whole flow in place: the action
        // router performs copy/save/lastAreaRect and any presentation, so
        // there is deliberately NO handleResult here — a second routing path
        // would double every side effect (QA: cấm hai đường cùng chạy).
        SelectionOverlay.begin(purpose: .areaReview) { result in
            switch result {
            case .handled, .cancelled, .area, .window:
                break
            }
        }
    }

    private func repeatAreaCapture() {
        guard let global = Settings.shared.lastAreaRect else {
            ToastHUD.show("No previous area — use Capture Area first", symbol: "rectangle.dashed")
            captureArea()
            return
        }
        // pick the screen holding MOST of the saved rect (first-intersect chose
        // primary-first and silently cropped the wrong region), and fall back
        // loudly when the display layout changed and the rect is gone
        let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(global).area < $1.frame.intersection(global).area
        })
        let visible = screen.map { $0.frame.intersection(global) } ?? .null
        guard let screen, visible.width >= 4, visible.height >= 4 else {
            ToastHUD.show("Vùng đã lưu không còn trên màn hình — chọn lại nhé", symbol: "rectangle.dashed")
            captureArea()
            return
        }
        let local = CGRect(
            x: visible.minX - screen.frame.minX, y: visible.minY - screen.frame.minY,
            width: visible.width, height: visible.height
        )
        Task { @MainActor in
            do {
                // one-shot: full capture + crop has proven coordinate math;
                // sourceRect stays reserved for the (validated) scroll loop
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
        SelectionOverlay.begin(purpose: .windowPick) { [weak self] result in
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

    private func startScrolling() {
        // Scroll-end routes through the in-place result presenter — never
        // handleResult: the router runs the auto actions exactly once with
        // the inputs snapshotted at begin, and the borderless panel replaces
        // the titled editor (QA invariants 13–15).
        ScrollingCapture.begin { finish in
            ScrollResultPresenter.present(finish)
        }
    }

    // MARK: result routing

    /// Bakes a backdrop into a capture for the routes that have no document to
    /// hold one. Fails CLOSED to the bare shot: an over-budget frame must cost
    /// the user their frame, never their screenshot.
    static func compose(
        _ image: CapturedImage, backdrop style: BackdropStyle
    ) -> CapturedImage? {
        guard style.kind != .none else { return image }
        guard let composed = SliceBBackdrop.compose(
            image: image.cgImage, style: style,
            budgetBytes: SliceBExport.defaultBudgetBytes,
            pixelScale: image.scale)
        else { return nil }
        return CapturedImage(cgImage: composed, scale: image.scale)
    }

    private func handleResult(_ image: CapturedImage, source: CaptureSource) {
        AppServices.lastCapture = image
        logEvent("capture source=\(source) px=\(image.cgImage.width)x\(image.cgImage.height)")
        let s = Settings.shared
        let copied = s.afterCopy

        // Auto-apply (WP7): the chosen preset frames every capture. The two
        // kinds of destination take it DIFFERENTLY, and which ones run is
        // independent of that.
        //
        // The editor gets the style as document state, so the frame stays
        // non-destructive — the whole point of Backdrop is changing your mind
        // after the shot. The clipboard and the saved file are pixels with
        // nowhere to keep a style, so they get it composed in.
        //
        // Both can happen at once. An earlier cut composed only when NO editor
        // opened, which meant "copy + save + show" put a bare shot on the
        // clipboard and a bare file on disk while the editor displayed a frame
        // — three things disagreeing, including this app's own Preferences
        // text. Whether the editor opens says nothing about what the clipboard
        // should contain.
        //
        // Composed at most once, and only if some pixel route actually asks:
        // an editor-only capture must not pay for a frame nobody reads.
        // `BackdropAutoApply.plan` is that choice, so a gate can pin it
        // without touching the clipboard. This function only carries it out.
        //
        // Scrolling captures deliberately do NOT come through here — they route
        // via ScrollResultPresenter — so auto-apply does not frame a scrollshot.
        // A 20,000pt strip gains nothing from padding and would be the first
        // thing to hit the byte budget.
        let autoBackdrop = BackdropPresetStore.autoApplyStyle
        let plan = BackdropAutoApply.plan(
            image: image,
            afterShow: s.afterShow,
            afterCopy: copied,
            afterSave: s.afterSave,
            style: autoBackdrop,
            compose: { Self.compose($0, backdrop: $1) })
        let framed = plan.exportImage

        if copied {
            SaveService.shared.copyToClipboard(framed)
        }
        if s.afterSave {
            // encoding runs in the background; announce when it lands (only
            // when no editor opens — same visibility rule as before)
            let announce = !plan.opensEditor
            SaveService.shared.save(framed) { url in
                guard announce else { return }
                var toasts: [String] = copied ? ["copied"] : []
                if let url {
                    toasts.append("saved \(url.lastPathComponent)")
                } else {
                    // the only configured action failed — rescue the shot
                    if !copied { SaveService.shared.copyToClipboard(framed) }
                    toasts.append(copied ? "save failed" : "save failed — copied instead")
                }
                ToastHUD.show("Screenshot \(toasts.joined(separator: " · "))")
            }
        }

        switch plan.destination {
        case .editor(let style):
            if source == .area && s.afterCropShow == .thumbnail {
                ThumbnailHUD.show(image) { img in
                    EditorWindowController.open(with: img, backdrop: style)
                }
            } else {
                EditorWindowController.open(with: image, backdrop: style)
            }
        case .export:
            if s.afterSave {
                // toast arrives from the save completion above
            } else if copied {
                ToastHUD.show("Screenshot copied")
            } else {
                // nothing configured — at least copy so the shot isn't lost
                SaveService.shared.copyToClipboard(framed)
                ToastHUD.show("Screenshot copied to clipboard")
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // refresh Launch at Startup checkmark & hotkey badges
        if let item = menu.items.first(where: { $0.title == "Launch at Startup" }) {
            item.state = LaunchAtLogin.isEnabled ? .on : .off
        }
        // a capture is likely seconds away — make sure the pipeline is hot
        CaptureEngine.shared.prewarm()
    }
}
