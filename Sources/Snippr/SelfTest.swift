import AppKit
import Vision

/// Headless feature tests: `Snippr --selftest [outdir]`.
/// Exercises everything that doesn't need Screen Recording permission.
enum SelfTest {
    static func run(outputDir: String) -> Int32 {
        Settings.registerDefaults()
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("PASS \(name)")
            } else {
                failures += 1
                print("FAIL \(name) \(detail)")
            }
        }

        // 1. Annotation rendering ------------------------------------------------
        let base = makeTestImage(width: 1600, height: 1200)
        let scale: CGFloat = 2
        var annotations: [Annotation] = []

        let arrow = ShapeAnnotation(kind: .arrow, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 700, y: 500), uiScale: scale)
        arrow.color = .systemRed
        annotations.append(arrow)

        let rect = ShapeAnnotation(kind: .rect, start: CGPoint(x: 800, y: 700), end: CGPoint(x: 1300, y: 1000), uiScale: scale)
        rect.color = .systemBlue
        annotations.append(rect)

        let oval = ShapeAnnotation(kind: .oval, start: CGPoint(x: 150, y: 700), end: CGPoint(x: 500, y: 950), uiScale: scale)
        oval.color = .systemGreen
        annotations.append(oval)

        let highlight = ShapeAnnotation(kind: .highlight, start: CGPoint(x: 600, y: 100), end: CGPoint(x: 1100, y: 220), uiScale: scale)
        highlight.color = .systemYellow
        annotations.append(highlight)

        let pen = PenAnnotation(uiScale: scale)
        pen.color = .systemOrange
        pen.points = stride(from: 0.0, to: 400.0, by: 8).map {
            CGPoint(x: 900 + $0, y: 350 + sin($0 / 40) * 60)
        }
        annotations.append(pen)

        let text = TextAnnotation(uiScale: scale)
        text.text = "Hello Snippr"
        text.origin = CGPoint(x: 250, y: 1050)
        text.color = .white
        annotations.append(text)

        for (i, pt) in [CGPoint(x: 120, y: 420), CGPoint(x: 120, y: 320)].enumerated() {
            let counter = CounterAnnotation(uiScale: scale)
            counter.center = pt
            counter.number = i + 1
            counter.color = .systemRed
            annotations.append(counter)
        }

        let blur = BlurAnnotation(uiScale: scale)
        blur.rect = CGRect(x: 1200, y: 150, width: 300, height: 200)
        annotations.append(blur)

        let pixellated = AnnotationRenderer.pixellate(base, scale: scale)
        check("pixellate", pixellated != nil)

        let rendered = AnnotationRenderer.render(base: base, annotations: annotations, pixellated: pixellated)
        check("annotation-render-size", rendered.width == base.width && rendered.height == base.height)
        check("annotation-render-changed", !imagesEqual(base, rendered))
        writePNG(rendered, to: "\(outputDir)/annotations.png")

        // 2. Stitcher --------------------------------------------------------------
        let tall = makeStripePattern(width: 400, height: 2000)
        let viewport = 500
        var offsets: [Int] = []
        var o = 0
        while o < 2000 - viewport {
            offsets.append(o)
            o += 320
        }
        offsets.append(2000 - viewport) // final clamped frame

        var stitcher: VerticalStitcher?
        for off in offsets {
            guard let frame = tall.cropping(to: CGRect(x: 0, y: off, width: 400, height: viewport)) else {
                check("stitch-crop", false); break
            }
            if let s = stitcher {
                _ = s.append(frame, direction: .down)
            } else {
                stitcher = VerticalStitcher(first: frame)
            }
        }
        let composed = stitcher?.compose()
        check("stitch-height", composed?.height == 2000, "got \(composed?.height ?? -1), want 2000")
        if let composed {
            check("stitch-content", imagesRoughlyEqual(tall, composed), "stitched content mismatch")
            writePNG(composed, to: "\(outputDir)/stitched.png")
        }

        // 3. Save format heuristic --------------------------------------------------
        let flat = makeSolidImage(width: 500, height: 500, color: NSColor.systemTeal.cgColor)
        let noisy = makeNoiseImage(width: 500, height: 500)
        check("format-flat-png", SaveService.decideFormat(for: flat) == .png)
        check("format-noise-jpeg", SaveService.decideFormat(for: noisy) == .jpeg)

        // 4. KeyCombo round-trip ----------------------------------------------------
        let combo = KeyCombo(keyCode: 18, modifiers: 768)
        check("keycombo-roundtrip", KeyCombo(encoded: combo.encoded) == combo)
        check("keycombo-display", HotkeyAction.fullscreen.defaultCombo?.display == "⇧⌘1",
              "got \(HotkeyAction.fullscreen.defaultCombo?.display ?? "nil")")

        // 5. OCR ---------------------------------------------------------------------
        let textImage = makeTextImage(text: "SNIPPR TEST 123", width: 900, height: 240)
        writePNG(textImage, to: "\(outputDir)/ocr-input.png")
        let sem = DispatchSemaphore(value: 0)
        var ocrText = ""
        Task {
            let result = await OCRService.shared.recognize(textImage)
            ocrText = result.text
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        check("ocr-text", ocrText.uppercased().contains("SNIPPR"), "got '\(ocrText)'")

        // 6. Window shot composition ---------------------------------------------------
        let windowShot = CapturedImage(cgImage: makeSolidImage(width: 400, height: 300, color: NSColor.darkGray.cgColor), scale: 2)
        let composedShot = CaptureEngine.composeWindowShot(windowShot, style: .solid, screen: nil)
        check("windowshot-padding", composedShot.cgImage.width == 400 + 96 * 2,
              "got \(composedShot.cgImage.width)")
        let trimmed = CaptureEngine.composeWindowShot(windowShot, style: .trimShadow, screen: nil)
        check("windowshot-trim", trimmed.cgImage.width == 400)
        writePNG(composedShot.cgImage, to: "\(outputDir)/windowshot.png")

        // 7. Retina downscale -----------------------------------------------------------
        let down = windowShot.downscaledTo1x()
        check("downscale-1x", down.cgImage.width == 200 && down.scale == 1)

        print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
        print("Artifacts: \(outputDir)")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Test image factories

    private static func ctx(_ w: Int, _ h: Int) -> CGContext {
        CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    static func makeTestImage(width: Int, height: Int) -> CGImage {
        let c = ctx(width, height)
        let colors = [NSColor.systemIndigo.cgColor, NSColor.systemPurple.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        c.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        for i in stride(from: 0, to: width, by: 120) {
            c.fill(CGRect(x: i, y: 0, width: 60, height: height))
        }
        return c.makeImage()!
    }

    private static func makeStripePattern(width: Int, height: Int) -> CGImage {
        let c = ctx(width, height)
        var seed: UInt64 = 0x5EED_1234
        for y in 0..<height {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = CGFloat((seed >> 33) & 0xFF) / 255
            let g = CGFloat((seed >> 41) & 0xFF) / 255
            let b = CGFloat((seed >> 49) & 0xFF) / 255
            c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            c.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return c.makeImage()!
    }

    private static func makeSolidImage(width: Int, height: Int, color: CGColor) -> CGImage {
        let c = ctx(width, height)
        c.setFillColor(color)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return c.makeImage()!
    }

    private static func makeNoiseImage(width: Int, height: Int) -> CGImage {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0xBADC0FFE
        for i in stride(from: 0, to: buf.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            buf[i] = UInt8((seed >> 33) & 0xFF)
            buf[i + 1] = UInt8((seed >> 41) & 0xFF)
            buf[i + 2] = UInt8((seed >> 49) & 0xFF)
            buf[i + 3] = 255
        }
        let c = CGContext(
            data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return c.makeImage()!
    }

    private static func makeTextImage(text: String, width: Int, height: Int) -> CGImage {
        let c = ctx(width, height)
        c.setFillColor(NSColor.white.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let nsCtx = NSGraphicsContext(cgContext: c, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: CGPoint(x: 40, y: 70), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()!
    }

    // MARK: - Comparison helpers

    private static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func imagesEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        return rgbaBytes(a) == rgbaBytes(b)
    }

    private static func imagesRoughlyEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let ba = rgbaBytes(a), bb = rgbaBytes(b)
        var diff: Int = 0
        var i = 0
        while i < ba.count {
            diff += abs(Int(ba[i]) - Int(bb[i]))
            i += 97 * 4 // sample sparsely
        }
        let samples = ba.count / (97 * 4)
        return Double(diff) / Double(max(1, samples)) < 3.0
    }

    private static func writePNG(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
