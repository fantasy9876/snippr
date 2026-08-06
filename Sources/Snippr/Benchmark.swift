import AppKit

/// `Snippr --benchmark`: measures how long the editor takes to appear
/// for a realistic retina screenshot. Prints milliseconds per stage.
@MainActor
enum Benchmark {
    static var requested: Bool { CommandLine.arguments.contains("--benchmark") }

    /// `--test-firstopen`: reproduces "the first capture doesn't show the
    /// editor". Runs the production warm-up, then opens an editor exactly the
    /// way a capture does and reports whether the window actually appeared.
    static var firstOpenTestRequested: Bool {
        CommandLine.arguments.contains("--test-firstopen")
    }

    static func runFirstOpenTest() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // after prewarm fires
            var failures = 0
            print("policy at start: \(NSApp.activationPolicy().rawValue) (1 = accessory)")

            // 1) direct open
            for round in 1...2 {
                let shot = CapturedImage(
                    cgImage: SelfTest.makeTestImage(width: 1200, height: 800), scale: 2)
                let wc = EditorWindowController.open(with: shot)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let visible = wc.window?.isVisible ?? false
                print("direct open #\(round): isVisible=\(visible)")
                if !visible { failures += 1 }
                wc.window?.close()
            }

            // 2) full hotkey path with ANOTHER app frontmost — the real scenario
            guard let delegate = NSApp.delegate as? AppDelegate else {
                print("no delegate"); exit(1)
            }
            for round in 1...2 {
                // hand focus to Finder, like a user working in another app
                // hide ourselves so another app owns focus and Snippr has NOT
                // performed any activation — the state a menu-bar app is in
                NSApp.hide(nil)
                try? await Task.sleep(nanoseconds: 900_000_000)
                let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

                let before = editorWindows()
                delegate.runHotkeyForTesting(.fullscreen)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let fresh = editorWindows().filter { w in !before.contains { $0 === w } }
                let visible = fresh.contains { $0.isVisible }
                let isKey = fresh.contains { $0.isKeyWindow }
                let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                // ground truth: is the editor actually drawn above other apps?
                let onTop = fresh.contains { isAboveOtherApps($0) }

                print("hotkey #\(round): front \(frontBefore) → \(frontAfter) | "
                      + "newWindows=\(fresh.count) visible=\(visible) key=\(isKey) "
                      + "aboveOtherApps=\(onTop)")
                if !visible || !onTop { failures += 1 }
                fresh.forEach { $0.close() }
            }

            // 3) AREA capture driven by a synthetic drag — the most used path.
            // (Focus goes to Finder rather than hiding: a hidden app can't
            // receive the synthetic drag, which would only test the harness.)
            for round in 1...2 {
                let before = editorWindows()
                delegate.runHotkeyForTesting(.area)
                try? await Task.sleep(nanoseconds: 2_500_000_000) // overlay up & key
                let overlayUp = SelectionOverlay.current != nil
                dragMouse(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 900, y: 720))
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                let fresh = editorWindows().filter { w in !before.contains { $0 === w } }
                let visible = fresh.contains { $0.isVisible }
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                let overlayStillUp = SelectionOverlay.current != nil
                print("area #\(round): overlayShown=\(overlayUp) overlayStillUp=\(overlayStillUp) "
                      + "newWindows=\(fresh.count) visible=\(visible) front=\(front)")
                if overlayStillUp { SelectionOverlay.current?.finish(.cancelled) }
                if !overlayUp || !visible { failures += 1 }
                fresh.forEach { $0.close() }
            }

            print(failures == 0 ? "FIRST-OPEN OK" : "FIRST-OPEN FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Synthesises a real left-button drag (needs Accessibility permission).
    private static func dragMouse(from: CGPoint, to: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 1...2 {
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                    mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(250_000) // let the overlay settle & take the mouse
        }
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
        for i in 1...6 {
            let t = CGFloat(i) / 6
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func editorWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.windowController is EditorWindowController }
    }

    /// True when no other app's ordinary window sits in front of `window`
    /// in the window server's front-to-back list — i.e. the user can see it.
    private static func isAboveOtherApps(_ window: NSWindow) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myNumber = CGWindowID(window.windowNumber)
        let myLayer = Int(window.level.rawValue)
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            if number == myNumber { return true }        // reached ours first → visible
            if layer > myLayer { continue }              // system UI above us is fine
            if pid != myPID { return false }             // another app covers us
        }
        return false
    }

    static func run() {
        let width = 3600, height = 2338 // full retina display shot
        var t = Date()
        func lap(_ label: String) {
            let ms = Date().timeIntervalSince(t) * 1000
            print(String(format: "%-28s %7.1f ms", (label as NSString).utf8String!, ms))
            t = Date()
        }

        let cg = SelfTest.makeTestImage(width: width, height: height)
        lap("make test image")

        let shot = CapturedImage(cgImage: cg, scale: 2)
        lap("wrap CapturedImage")

        // full open path, exactly what a capture does
        let wc = EditorWindowController.open(with: shot)
        lap("EditorWindowController.open")

        wc.window?.displayIfNeeded()
        lap("first display (paint)")

        // second window: measures steady-state cost after warm caches
        let wc2 = EditorWindowController.open(with: shot)
        wc2.window?.displayIfNeeded()
        lap("second window open+paint")

        // Real capture path, measured the way a user experiences it: after the
        // app has been running (caches warm), not during cold launch.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000) // let prewarm finish
            print("--- warm app (what users actually hit) ---")
            for round in 1...2 {
                var t2 = Date()
                func lap2(_ label: String) {
                    let ms = Date().timeIntervalSince(t2) * 1000
                    print(String(format: "%-28s %7.1f ms", ("\(label) #\(round)" as NSString).utf8String!, ms))
                    t2 = Date()
                }
                let all = Date()
                guard let real = try? await CaptureEngine.shared.captureDisplay(screen: screen) else {
                    print("capture failed (no Screen Recording permission?)")
                    exit(1)
                }
                lap2("captureDisplay")
                let wc3 = EditorWindowController.open(with: real)
                lap2("editor open")
                wc3.window?.displayIfNeeded()
                wc3.window?.contentView?.displayIfNeeded()
                lap2("forced paint")
                print(String(format: "%-28s %7.1f ms",
                             ("END-TO-END #\(round)" as NSString).utf8String!,
                             Date().timeIntervalSince(all) * 1000))
                wc3.window?.close()
            }
            exit(0)
        }
    }
}
