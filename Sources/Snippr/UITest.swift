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
        EditorWindowController.open(with: sample)
        // small shot in a deliberately oversized window — proves centering
        let small = CapturedImage(cgImage: SelfTest.makeTestImage(width: 600, height: 360), scale: 2)
        EditorWindowController.open(with: small).window?
            .setContentSize(NSSize(width: 820, height: 560))
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
            exit(index >= 3 ? 0 : 1)
        }
    }
}
