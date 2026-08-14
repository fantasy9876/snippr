import AppKit
import SwiftUI

/// `Snippr --uitest <outdir>`: boots the real app, opens the Editor and
/// Preferences windows, snapshots every visible window to PNG, then exits.
/// Verifies the actual UI stack without needing Screen Recording permission.
@MainActor
enum UITest {
    static var requestedOutputDir: String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--uitest") else { return nil }
        return args.count > idx + 1 ? args[idx + 1] : NSTemporaryDirectory() + "snippr-uitest"
    }

    static func runIfRequested() {
        guard let outDir = requestedOutputDir else { return }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // sample capture: gradient test card @2x
        let sample = CapturedImage(cgImage: SelfTest.makeTestImage(width: 1440, height: 900), scale: 2)
        let fittedEditor = EditorWindowController.open(with: sample, forceFitForTesting: true)
        // small shot in a deliberately oversized window — proves centering
        let small = CapturedImage(cgImage: SelfTest.makeTestImage(width: 600, height: 360), scale: 2)
        let smallEditor = EditorWindowController.open(with: small, forceFitForTesting: true)
        smallEditor.window?.setContentSize(NSSize(width: 820, height: 560))
        // Tall scrolling result: its fit factor is below the old 10% zoom
        // floor, which used to leave both scrollers visible in "Fit" mode.
        let tall = CapturedImage(cgImage: SelfTest.makeTestImage(width: 400, height: 24_000), scale: 2)
        let tallEditor = EditorWindowController.open(with: tall, forceFitForTesting: true)
        tallEditor.selectTool(.crop)
        // opened the way the menu's "About Snippr" does — must land on About
        PreferencesWindowController.show(tab: .about)
        ToastHUD.show("Snippr UI test — toast OK", symbol: "checkmark.seal.fill", duration: 6)
        TextResultWindow.show(text: "Snippr — chụp màn hình, nhận diện chữ (OCR), dịch đa ngôn ngữ.\nScreenshot → OCR → Translate, everything on your machine.")
        ThumbnailHUD.show(sample) { _ in }
        PinWindow.pin(CapturedImage(cgImage: SelfTest.makeTestImage(width: 400, height: 260), scale: 2))

        // SwiftUI text layers don't always survive cacheDisplay — render each tab directly too
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralTab())),
            ("hotkeys", AnyView(HotkeysTab())),
            ("uploading", AnyView(UploadingTab())),
            ("advanced", AnyView(AdvancedTab())),
            ("about", AnyView(AboutTab())),
        ]
        for (name, view) in tabs {
            let renderer = ImageRenderer(content: view.frame(width: 600).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(outDir)/prefs-\(name).png"))
                }
            }
        }

        // In-place area review factory case: real overlay window with an
        // injected frozen image (no Screen Recording), driven through the
        // production selection→review→escape-hatch path.
        var overlayReviewOK = false
        if let screen = NSScreen.main {
            let frozen = CapturedImage(
                cgImage: SelfTest.makeTestImage(width: 1200, height: 800), scale: 1)
            let editorsBefore = NSApp.windows.filter { $0.windowController is EditorWindowController }.count
            // no-op dependencies: the harness must never touch the user's
            // clipboard, files or settings
            var editorPresents = 0
            let noopDeps = CaptureActionRouter.Dependencies(
                copyToClipboard: { _ in },
                autoSave: { _, _ in },
                saveAs: { _, _ in },
                pin: { _ in }, ocr: { _ in },
                openEditor: { image in
                    editorPresents += 1
                    EditorWindowController.open(with: image)
                },
                toast: { _ in },
                setLastCapture: { _ in },
                setLastAreaRect: { _ in },
                logEvent: { _ in })
            let overlay = SelectionOverlay.beginForTesting(
                purpose: .areaReview,
                inputs: OverlaySessionInputs(
                    afterShow: true, afterCopy: false, afterSave: false),
                frozen: frozen, screen: screen,
                dependencies: noopDeps, completion: { _ in })
            if let overlay,
               let view = overlay.activeReviewViewForTesting {
                view.selectForTesting(rect: CGRect(x: 120, y: 140, width: 360, height: 240))
                let toolbarFrame = view.reviewToolbarFrameForTesting
                let reviewing = view.isReviewingForTesting
                    && overlay.session.phase == .reviewing
                let toolbarInside = toolbarFrame.map { view.bounds.contains($0) } ?? false
                // annotation + text-responder precedence: while the text
                // field is first responder, Return must stay in the field —
                // the overlay survives.
                view.annotationSurface?.tool = .rect
                _ = view.annotationSurface?.beginDrag(
                    atPixel: CGPoint(x: 200, y: 220))
                view.annotationSurface?.continueDrag(
                    toPixel: CGPoint(x: 320, y: 300))
                view.annotationSurface?.endDrag()
                let annotated = view.annotationSurface?.isEmpty == false
                view.annotationSurface?.tool = .text
                view.beginTextEntryForTesting(
                    atView: CGPoint(x: 200, y: 200))
                var precedenceOK = false
                if let field = view.textFieldForTesting,
                   view.window?.firstResponder === field
                    || view.window?.firstResponder is NSTextView {
                    if let returnEvent = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                        context: nil, characters: "\r",
                        charactersIgnoringModifiers: "\r",
                        isARepeat: false, keyCode: 36) {
                        view.keyDown(with: returnEvent)
                    }
                    precedenceOK = SelectionOverlay.current != nil
                }
                view.commitTextEntryForTesting(text: "hello")
                view.annotationSurface?.tool = .select
                // escape hatch: exactly one editor presented AFTER teardown
                view.performReviewActionForTesting(.openEditor)
                let editorsAfter = NSApp.windows.filter { $0.windowController is EditorWindowController }.count
                overlayReviewOK = reviewing && toolbarInside
                    && SelectionOverlay.current == nil
                    && editorsAfter == editorsBefore + 1
                    && editorPresents == 1
                    && annotated && precedenceOK
            }
        }

        // Scroll-result panel factory case: 24k-pt stitch fits ≤90% of the
        // visible frame, toolbar visible, escape hatch presents exactly one
        // editor AFTER the panel dismissed.
        var scrollPanelOK = false
        if let screen = NSScreen.main {
            let tallStitch = CapturedImage(
                cgImage: SelfTest.makeTestImage(width: 400, height: 24_000), scale: 2)
            let editorsBefore = NSApp.windows
                .filter { $0.windowController is EditorWindowController }.count
            var panelEditorPresents = 0
            let panelDeps = CaptureActionRouter.Dependencies(
                copyToClipboard: { _ in },
                autoSave: { _, _ in },
                saveAs: { _, _ in },
                pin: { _ in }, ocr: { _ in },
                openEditor: { image in
                    panelEditorPresents += 1
                    EditorWindowController.open(with: image)
                },
                toast: { _ in },
                setLastCapture: { _ in },
                setLastAreaRect: { _ in },
                logEvent: { _ in })
            let panel = ScrollResultPanel.show(
                image: tallStitch,
                inputs: OverlaySessionInputs(
                    afterShow: true, afterCopy: false, afterSave: false),
                screen: screen,
                dependencies: panelDeps)
            let visible = screen.visibleFrame
            let fits = panel.frame.width <= visible.width * 0.9 + 1
                && panel.frame.height <= visible.height * 0.9 + 1
            // toolbar layout is REAL: every button (Close included) inside
            // the bar, no pairwise overlap, and each hit-tests to itself
            var toolbarVisible = panel.toolbarFrameForTesting != nil
            if let bar = panel.toolbarFrameForTesting {
                let frames = panel.toolbarButtonFramesForTesting
                let barBounds = CGRect(origin: .zero, size: bar.size)
                for (i, f) in frames.enumerated() {
                    if !barBounds.contains(f) { toolbarVisible = false }
                    for j in (i + 1)..<frames.count
                        where f.intersects(frames[j]) {
                        toolbarVisible = false
                    }
                }
                if let content = panel.contentView {
                    for f in frames {
                        let centerInContent = CGPoint(
                            x: bar.minX + f.midX, y: bar.minY + f.midY)
                        if !(content.hitTest(centerInContent) is NSButton) {
                            toolbarVisible = false
                        }
                    }
                }
            }
            // Annotate through REAL mouse events at the four corners and
            // the center of the fitted strip: each stroke must land at the
            // matching pixel in the export (uniform X/Y mapping), and the
            // export keeps the stitched dimensions.
            panel.annotationSurface.tool = .pen
            panel.annotationSurface.color = .systemRed
            var panelAnnotated = true
            if let host = panel.annotationHostForTesting {
                // uniform mapping: pixels-per-point equal on both axes
                let ppx = CGFloat(tallStitch.cgImage.width) / host.frame.width
                let ppy = CGFloat(tallStitch.cgImage.height) / host.frame.height
                if abs(ppx - ppy) > 0.02 * max(ppx, ppy) { panelAnnotated = false }
                let w = host.bounds.width, h = host.bounds.height
                let probes: [CGPoint] = [
                    CGPoint(x: 2, y: 2), CGPoint(x: w - 2, y: 2),
                    CGPoint(x: 2, y: h - 2), CGPoint(x: w - 2, y: h - 2),
                    CGPoint(x: w / 2, y: h / 2),
                ]
                for p in probes {
                    panel.drawWithRealEventsForTesting(
                        fromView: p,
                        toView: CGPoint(x: min(w - 1, p.x + 1), y: p.y))
                }
                let export = panel.exportSnapshotForTesting
                if export.cgImage.width != tallStitch.cgImage.width
                    || export.cgImage.height != tallStitch.cgImage.height
                    || SelfTest.imagesEqualForTesting(
                        export.cgImage, tallStitch.cgImage) {
                    panelAnnotated = false
                }
                // every probe pixel neighborhood must contain red ink
                if let probe = SelfTest.redInkNearForTesting(
                    export.cgImage,
                    points: probes.map { CGPoint(x: $0.x * ppx, y: $0.y * ppy) },
                    pixelRadius: Int(8 * max(ppx, 1))) {
                    _ = probe
                } else {
                    panelAnnotated = false
                }
            } else {
                panelAnnotated = false
            }
            panel.performActionForTesting(.openEditor)
            let editorsAfter = NSApp.windows
                .filter { $0.windowController is EditorWindowController }.count
            scrollPanelOK = fits && toolbarVisible
                && ScrollResultPanel.current == nil
                && editorsAfter == editorsBefore + 1
                && panelEditorPresents == 1
                && panelAnnotated
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let fitOK = fittedEditor.imageFitsViewportForTesting()
                && smallEditor.imageFitsViewportForTesting()
                && tallEditor.imageFitsViewportForTesting()
            let tallCropControlsOK = tallEditor.cropActionControlsReadyForTesting()
            print("UITEST editor-fit \(fitOK ? "PASS" : "FAIL")")
            print("UITEST tall-crop-controls \(tallCropControlsOK ? "PASS" : "FAIL")")
            print("UITEST overlay-review \(overlayReviewOK ? "PASS" : "FAIL")")
            print("UITEST scroll-panel \(scrollPanelOK ? "PASS" : "FAIL")")
            var index = 0
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView, view.bounds.width > 10 else { continue }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                let kind = window is NSPanel ? "panel" : "window"
                let name = String(format: "%02d-%@-%.0fx%.0f.png", index, kind, view.bounds.width, view.bounds.height)
                try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
                index += 1
            }
            print("UITEST captured \(index) windows → \(outDir)")
            exit(index >= 3 && fitOK && tallCropControlsOK && overlayReviewOK
                 && scrollPanelOK ? 0 : 1)
        }
    }
}
