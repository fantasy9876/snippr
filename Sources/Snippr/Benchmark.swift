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

    /// `--test-scrollpreview <outdir>`: starts a scrolling session on a fixed
    /// rect, lets it grab a few frames, snapshots the live preview panel to
    /// PNG and exits — visual proof the "vừa chụp vừa xem" panel works.
    static var scrollPreviewOutDir: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--test-scrollpreview"),
              CommandLine.arguments.count > i + 1 else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func runScrollPreviewTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let rect = CGRect(x: 120, y: screen.frame.height - 620, width: 420, height: 340)
            let session = ScrollingCapture(onFinish: { image in
                print("scroll session finished, image: \(image.map { "\($0.cgImage.width)x\($0.cgImage.height)" } ?? "nil")")
                exit(0)
            })
            ScrollingCapture.active = session
            Task { @MainActor in await session.run(screen: screen, rect: rect) }

            try? await Task.sleep(nanoseconds: 1_800_000_000) // a few ticks
            if let panel = session.previewPanelForTesting, let view = panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: outDir + "/scroll-preview.png"))
                    print("preview panel snapshot saved")
                }
            } else {
                print("NO PREVIEW PANEL")
            }
            session.finishForTesting()
        }
    }

    /// `--test-scrollstitch`: grabs a REAL screenshot and simulates scrolling
    /// by cropping frames at known offsets — validates the matcher against
    /// actual UI content (dark backgrounds, repetitive chat rows, text),
    /// not just synthetic patterns. Prints accept/reject per step.
    static var scrollStitchTestRequested: Bool {
        CommandLine.arguments.contains("--test-scrollstitch")
    }

    static func runScrollStitchTest() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let screen = NSScreen.main ?? NSScreen.screens[0]
            guard let full = try? await CaptureEngine.shared.captureDisplay(screen: screen) else {
                print("capture failed"); exit(1)
            }
            let tall = full.cgImage
            let vw = min(1100, tall.width - 200)
            let vh = 700
            guard tall.height > vh + 900 else { print("screen too small"); exit(1) }

            // realistic mix: small nudges, medium scrolls, one big jump
            let steps = [0, 120, 260, 420, 480, 900, 1000]
            var expectedHeight = vh
            var stitcher: VerticalStitcher?
            var accepted = 0, rejected = 0

            for (i, off) in steps.enumerated() {
                guard let frame = tall.cropping(to: CGRect(x: 100, y: off, width: vw, height: vh)) else {
                    print("crop fail"); exit(1)
                }
                if let s = stitcher {
                    let rows = s.append(frame)
                    let delta = off - steps[i - 1]
                    if rows == delta {
                        accepted += 1
                        expectedHeight += rows
                        print("step +\(delta)px → appended \(rows) ✓")
                    } else if rows == 0 {
                        rejected += 1
                        print("step +\(delta)px → REJECTED")
                    } else {
                        print("step +\(delta)px → WRONG rows=\(rows) ✗✗")
                        print("SCROLLSTITCH FAILED (wrong offset accepted)")
                        exit(1)
                    }
                } else {
                    stitcher = VerticalStitcher(first: frame)
                }
            }
            let total = stitcher?.totalHeight ?? 0
            print("accepted \(accepted)/\(steps.count - 1), rejected \(rejected), height \(total) (expect \(expectedHeight))")
            let ok = accepted >= steps.count - 2 && total == expectedHeight
            print(ok ? "SCROLLSTITCH OK" : "SCROLLSTITCH FAILED (too many rejections)")
            exit(ok ? 0 : 1)
        }
    }

    /// `--test-scrollreal <outdir>`: END-TO-END scrolling-capture test on the
    /// live machine. Opens a window with tall deterministic content, captures
    /// its rect through the REAL SCK pipeline (captureRect), scrolls the
    /// window programmatically and stitches — validating (1) sourceRect
    /// coordinate math against captureDisplay+crop, (2) hash stability,
    /// (3) the matcher on real screen-rendered content.
    static var scrollRealOutDir: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--test-scrollreal"),
              CommandLine.arguments.count > i + 1 else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func runScrollRealTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            let screen = NSScreen.main ?? NSScreen.screens[0]
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                print(ok ? "PASS \(name)" : "FAIL \(name) \(detail)")
                if !ok { failures += 1 }
            }

            // --- tall scrollable window with deterministic content
            let viewW: CGFloat = 500, viewH: CGFloat = 600, docH: CGFloat = 4000
            let origin = CGPoint(x: screen.frame.minX + 200, y: screen.frame.minY + 150)
            let win = NSWindow(
                contentRect: CGRect(origin: origin, size: CGSize(width: viewW, height: viewH)),
                styleMask: .borderless, backing: .buffered, defer: false)
            win.level = .screenSaver // nothing may cover the content mid-test
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: viewW, height: viewH))
            scroll.hasVerticalScroller = false
            scroll.verticalScrollElasticity = .none
            let doc = StripeDocView(frame: CGRect(x: 0, y: 0, width: viewW, height: docH))
            scroll.documentView = doc
            win.contentView = scroll
            win.orderFrontRegardless()
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(nanoseconds: 700_000_000)

            // window frame in screen-local points (bottom-left origin)
            let rect = CGRect(
                x: win.frame.minX - screen.frame.minX,
                y: win.frame.minY - screen.frame.minY,
                width: viewW, height: viewH)

            // --- 1) sourceRect coordinate validation
            guard let full = try? await CaptureEngine.shared.captureDisplay(screen: screen),
                  let cropRef = full.cropping(toViewRect: rect),
                  let sub = try? await CaptureEngine.shared.captureRect(screen: screen, rect: rect)
            else { print("FAIL capture unavailable (screen asleep/locked?)"); exit(1) }
            SelfTest.writePNG(cropRef.cgImage, to: "\(outDir)/ref-crop.png")
            SelfTest.writePNG(sub.cgImage, to: "\(outDir)/sourcerect.png")
            check("sizes-match",
                  sub.cgImage.width == cropRef.cgImage.width
                  && sub.cgImage.height == cropRef.cgImage.height,
                  "sub \(sub.cgImage.width)x\(sub.cgImage.height) vs crop \(cropRef.cgImage.width)x\(cropRef.cgImage.height)")
            let diff = ScrollingCapture.meanAbsDiff(sub.cgImage, cropRef.cgImage)
            check("sourcerect-region", diff < 8.0, "mean abs diff \(diff)")

            // --- 2) hash stability + change detection
            let h1 = ScrollingCapture.quickHash(sub.cgImage)
            guard let sub2 = try? await CaptureEngine.shared.captureRect(screen: screen, rect: rect)
            else { print("FAIL second capture"); exit(1) }
            let h2 = ScrollingCapture.quickHash(sub2.cgImage)
            check("hash-stable", h1 == h2)

            // --- 3) real scroll + stitch through the actual pipeline
            let scale = screen.backingScaleFactor
            let stitcher = VerticalStitcher(first: sub.cgImage, scale: scale)
            let stepPt: CGFloat = 150
            var accepted = 0
            for step in 1...6 {
                doc.scrollOffset += stepPt
                scroll.contentView.scroll(to: CGPoint(x: 0, y: doc.scrollOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
                win.display()
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let frame = try? await CaptureEngine.shared.captureRect(screen: screen, rect: rect)
                else { check("capture-step-\(step)", false); continue }
                let rows = stitcher.append(frame.cgImage)
                let want = Int(stepPt * scale)
                if rows == want { accepted += 1 }
                print("  step \(step): +\(want)px → appended \(rows)\(rows == want ? " ✓" : " ✗")")
            }
            let composed = stitcher.compose()
            if let composed {
                SelfTest.writePNG(composed, to: "\(outDir)/scrollreal.png")
            }
            let expected = Int((viewH + 6 * stepPt) * scale)
            check("stitch-accepted", accepted >= 5, "only \(accepted)/6 accepted")
            check("stitch-height", composed?.height == expected,
                  "got \(composed?.height ?? -1), want \(expected)")

            win.orderOut(nil)

            // ---- Phase B: realistic hard case — chat-like low-contrast page,
            // sticky composer bar with a blinking caret, small/fractional
            // trackpad-style scroll steps.
            let chatDoc = ChatDocView(frame: CGRect(x: 0, y: 0, width: viewW, height: docH))
            let win2 = NSWindow(
                contentRect: CGRect(origin: origin, size: CGSize(width: viewW, height: viewH)),
                styleMask: .borderless, backing: .buffered, defer: false)
            win2.level = .screenSaver
            win2.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let scroll2 = NSScrollView(frame: CGRect(x: 0, y: 0, width: viewW, height: viewH))
            scroll2.hasVerticalScroller = false
            scroll2.verticalScrollElasticity = .none
            scroll2.documentView = chatDoc
            let composer = ComposerBarView(frame: CGRect(x: 0, y: 0, width: viewW, height: 60))
            let container = NSView(frame: CGRect(x: 0, y: 0, width: viewW, height: viewH))
            scroll2.frame = CGRect(x: 0, y: 60, width: viewW, height: viewH - 60)
            container.addSubview(scroll2)
            container.addSubview(composer)
            win2.contentView = container
            win2.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 700_000_000)

            guard let first2 = try? await CaptureEngine.shared.captureRect(screen: screen, rect: rect)
            else { print("FAIL phase-B capture"); exit(1) }
            let s2 = VerticalStitcher(first: first2.cgImage, scale: scale)
            // small, fractional, and mixed steps — what a trackpad really does
            let steps: [CGFloat] = [7, 11, 23.5, 90, 16, 150]
            var offset: CGFloat = 0
            var accepted2 = 0
            var caret = false
            for (i, step) in steps.enumerated() {
                offset += step
                scroll2.contentView.scroll(to: CGPoint(x: 0, y: offset))
                scroll2.reflectScrolledClipView(scroll2.contentView)
                caret.toggle()
                composer.caretOn = caret // blinks between ticks, like a real input
                composer.needsDisplay = true
                win2.display()
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let frame = try? await CaptureEngine.shared.captureRect(screen: screen, rect: rect)
                else { check("phaseB-capture-\(i)", false); continue }
                let rows = s2.append(frame.cgImage)
                let want = Int(round(step * scale))
                if rows == want { accepted2 += 1 }
                print("  chat step \(i + 1) (+\(want)px): appended \(rows)\(rows == want ? " ✓" : " ✗")")
            }
            let composed2 = s2.compose()
            if let composed2 {
                SelfTest.writePNG(composed2, to: "\(outDir)/scrollreal-chat.png")
            }
            let totalSteps = steps.reduce(0, +)
            let expected2 = Int(round((viewH + totalSteps) * scale))
            check("chat-accepted", accepted2 >= 5, "only \(accepted2)/\(steps.count) accepted")
            check("chat-footer-latched", s2.footerRows >= Int(50 * scale),
                  "footerRows \(s2.footerRows), composer is \(Int(60 * scale))px")
            check("chat-height", composed2?.height == expected2,
                  "got \(composed2?.height ?? -1), want \(expected2)")

            win2.orderOut(nil)

            // ---- Phase C: sourceRect COMBINED with a non-empty window
            // exclusion list — exactly what a real scroll session does (its
            // chrome windows are excluded). This pairing is the one thing the
            // phases above don't cover.
            let decoy = NSWindow(
                contentRect: CGRect(x: screen.frame.minX + 8, y: screen.frame.minY + 8, width: 120, height: 40),
                styleMask: .borderless, backing: .buffered, defer: false)
            decoy.level = .screenSaver
            decoy.backgroundColor = .systemBlue
            decoy.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 400_000_000)
            CaptureEngine.shared.invalidateContentCache()
            if let subEx = try? await CaptureEngine.shared.captureRect(
                   screen: screen, rect: rect, excludingOwnWindows: true, contentMaxAge: 300),
               let fullEx = try? await CaptureEngine.shared.captureDisplay(
                   screen: screen, excludingOwnWindows: true, contentMaxAge: 300),
               let refEx = fullEx.cropping(toViewRect: rect) {
                let sizeOK = subEx.cgImage.width == refEx.cgImage.width
                    && subEx.cgImage.height == refEx.cgImage.height
                let dEx = sizeOK ? ScrollingCapture.meanAbsDiff(subEx.cgImage, refEx.cgImage) : 255
                check("sourcerect-with-exclusion", sizeOK && dEx < 8.0,
                      "size \(subEx.cgImage.width)x\(subEx.cgImage.height) vs \(refEx.cgImage.width)x\(refEx.cgImage.height), diff \(dEx)")
                SelfTest.writePNG(subEx.cgImage, to: "\(outDir)/sourcerect-excl.png")
                SelfTest.writePNG(refEx.cgImage, to: "\(outDir)/ref-excl.png")
            } else {
                check("sourcerect-with-exclusion", false, "capture failed")
            }
            decoy.orderOut(nil)

            print(failures == 0 ? "SCROLLREAL OK" : "SCROLLREAL FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Chat-like page: white background, sparse gray "message" rows with
    /// avatars — low contrast, lots of whitespace, 34-pt line pitch (the
    /// self-similar structure that stresses the matcher's uniqueness test).
    final class ChatDocView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(bounds)
            var y: CGFloat = 8
            var seed: UInt64 = 0xCAFE_D00D
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) & 0xFF) / 255
            }
            while y < bounds.height {
                // avatar
                ctx.setFillColor(CGColor(srgbRed: 0.7 + next() * 0.25, green: 0.7 + next() * 0.25, blue: 0.75 + next() * 0.2, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 10, y: y, width: 24, height: 24))
                // 1-3 gray text lines, varying widths
                let lines = 1 + Int(next() * 2.6)
                var ly = y + 2
                for _ in 0..<lines {
                    ctx.setFillColor(CGColor(gray: 0.35 + next() * 0.2, alpha: 1))
                    ctx.fill(CGRect(x: 44, y: ly, width: 80 + next() * 300, height: 9))
                    ly += 14
                }
                y = max(ly, y + 34) + 8
            }
        }
    }

    /// Sticky composer bar with a blinking caret — the classic footer case.
    final class ComposerBarView: NSView {
        var caretOn = false
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
            ctx.fill(bounds)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 14, width: bounds.width - 80, height: 32))
            ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            ctx.stroke(CGRect(x: 10, y: 14, width: bounds.width - 80, height: 32), width: 1)
            ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.45, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: bounds.width - 60, y: 14, width: 50, height: 32))
            if caretOn {
                ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
                ctx.fill(CGRect(x: 18, y: 20, width: 2, height: 20))
            }
        }
    }

    /// `--test-scrollapp`: drives the REAL ScrollingCapture session against
    /// the frontmost window of ANOTHER app (open a tall page first), scrolling
    /// it with synthesized wheel events — chrome exclusion, overlay
    /// scrollbars, real content: the exact end-user flow.
    static var scrollAppRequested: Bool {
        CommandLine.arguments.contains("--test-scrollapp")
    }

    static func runScrollAppTest() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let info = CaptureEngine.frontmostWindow() else {
                print("no frontmost window"); exit(1)
            }
            let screen = CaptureEngine.screenContaining(cgRect: info.frameCG)
                ?? NSScreen.main ?? NSScreen.screens[0]
            let fA = info.frameAppKit
            // inside the window, skipping the title bar region at the top
            let local = CGRect(
                x: fA.minX - screen.frame.minX + 12,
                y: fA.minY - screen.frame.minY + 12,
                width: fA.width - 24,
                height: fA.height - 110)
            guard local.width >= 200, local.height >= 200 else {
                print("front window too small: \(info.ownerName) \(fA)"); exit(1)
            }
            print("target: \(info.ownerName) rect \(Int(local.width))x\(Int(local.height))pt")
            let viewportPx = Int(local.height * screen.backingScaleFactor)

            let session = ScrollingCapture(onFinish: { image in
                guard let image else { print("SCROLLAPP FAILED (no image)"); exit(1) }
                let h = image.cgImage.height
                print("stitched \(image.cgImage.width)x\(h)px (viewport \(viewportPx)px)")
                SelfTest.writePNG(image.cgImage, to: NSTemporaryDirectory() + "/scrollapp.png")
                print("saved \(NSTemporaryDirectory())scrollapp.png")
                let grew = h > viewportPx + 200
                print(grew ? "SCROLLAPP OK" : "SCROLLAPP FAILED (no growth)")
                exit(grew ? 0 : 1)
            })
            ScrollingCapture.active = session
            Task { @MainActor in await session.run(screen: screen, rect: local) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            // the target page auto-scrolls itself (discrete then smooth phases)
            // — synthesized wheel events silently no-op without Accessibility,
            // which produced a false "nothing scrolled" reproduction earlier
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            session.finishForTesting()
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

    /// Deterministic tall content: 4-pt color bands from a seeded LCG with
    /// darker inner blocks so rows carry horizontal detail (gradient energy).
    final class StripeDocView: NSView {
        var scrollOffset: CGFloat = 0
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let band: CGFloat = 4
            var y: CGFloat = 0
            while y < bounds.height {
                var seed = UInt64(y / band) &* 6364136223846793005 &+ 1442695040888963407
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat((seed >> 33) & 0xFF) / 255
                }
                ctx.setFillColor(CGColor(srgbRed: next(), green: next(), blue: next(), alpha: 1))
                ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: band))
                // horizontal detail: a few darker blocks at row-dependent x
                ctx.setFillColor(CGColor(srgbRed: next() * 0.4, green: next() * 0.4, blue: next() * 0.4, alpha: 1))
                var x: CGFloat = next() * 60
                while x < bounds.width {
                    ctx.fill(CGRect(x: x, y: y, width: 14 + next() * 30, height: band))
                    x += 60 + next() * 90
                }
                y += band
            }
        }
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
