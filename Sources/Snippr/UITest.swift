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
            let overlay = SelectionOverlay.beginForTesting(
                purpose: .areaReview,
                frozen: frozen, screen: screen, completion: { _ in })
            if let overlay,
               let view = overlay.activeReviewViewForTesting {
                view.selectForTesting(rect: CGRect(x: 120, y: 140, width: 360, height: 240))
                let toolbarFrame = view.reviewToolbarFrameForTesting
                let reviewing = view.isReviewingForTesting
                    && overlay.session.phase == .reviewing
                let toolbarInside = toolbarFrame.map { view.bounds.contains($0) } ?? false
                // escape hatch: exactly one editor presented AFTER teardown
                view.performReviewActionForTesting(.openEditor)
                let editorsAfter = NSApp.windows.filter { $0.windowController is EditorWindowController }.count
                overlayReviewOK = reviewing && toolbarInside
                    && SelectionOverlay.current == nil
                    && editorsAfter == editorsBefore + 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let fitOK = fittedEditor.imageFitsViewportForTesting()
                && smallEditor.imageFitsViewportForTesting()
                && tallEditor.imageFitsViewportForTesting()
            let tallCropControlsOK = tallEditor.cropActionControlsReadyForTesting()
            print("UITEST editor-fit \(fitOK ? "PASS" : "FAIL")")
            print("UITEST tall-crop-controls \(tallCropControlsOK ? "PASS" : "FAIL")")
            print("UITEST overlay-review \(overlayReviewOK ? "PASS" : "FAIL")")
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
            exit(index >= 3 && fitOK && tallCropControlsOK && overlayReviewOK ? 0 : 1)
        }
    }
}
