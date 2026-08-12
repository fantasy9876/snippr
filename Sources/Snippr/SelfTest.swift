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
                _ = s.append(frame)
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

        // 2b. Self-similar content must be REJECTED, not guessed -------------------
        // (repetitive chat-like UI used to produce duplicated blocks and
        // corrupted seams — the matcher now requires a unique best offset)
        let periodic = makePeriodicPattern(width: 400, height: 1000, period: 40)
        if let f0 = periodic.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 500)),
           let f1 = periodic.cropping(to: CGRect(x: 0, y: 100, width: 400, height: 500)) {
            let s2 = VerticalStitcher(first: f0)
            let appended = s2.append(f1)
            check("stitch-ambiguous-rejected", appended == 0,
                  "appended \(appended) rows from ambiguous content")
        } else {
            check("stitch-ambiguous-crop", false)
        }

        // 2c. Sticky footer inside the viewport ------------------------------------
        // A fixed bottom bar (chat input, cookie banner…) used to either stall
        // matching entirely or get baked into every seam. The stitcher must
        // keep matching AND move the footer to the very end of the page.
        do {
            let fW = 400, fViewport = 500, fFooterH = 60
            let bodyH = fViewport - fFooterH
            let content = makeStripePattern(width: fW, height: 2000, seed: 0xC0FFEE42)
            let footerBand = makeStripePattern(width: fW, height: fFooterH, seed: 0x0DDBA11)

            func footerFrame(offset: Int) -> CGImage? {
                guard let body = content.cropping(to: CGRect(x: 0, y: offset, width: fW, height: bodyH))
                else { return nil }
                let c = ctx(fW, fViewport)
                // CG drawing is bottom-left: footer at the bottom, body above
                c.draw(footerBand, in: CGRect(x: 0, y: 0, width: fW, height: fFooterH))
                c.draw(body, in: CGRect(x: 0, y: fFooterH, width: fW, height: bodyH))
                return c.makeImage()
            }

            let offsets = [0, 320, 640, 900]
            var s3: VerticalStitcher?
            var appendsOK = true
            for (i, off) in offsets.enumerated() {
                guard let frame = footerFrame(offset: off) else { appendsOK = false; break }
                if let s = s3 {
                    let rows = s.append(frame)
                    let want = off - offsets[i - 1]
                    if rows != want {
                        appendsOK = false
                        print("  footer step +\(want) → got \(rows)")
                    }
                } else {
                    s3 = VerticalStitcher(first: frame)
                }
            }
            check("stitch-footer-appends", appendsOK)

            if let composed3 = s3?.compose() {
                // expected: body content [0, bodyH + 900) then the footer once
                let totalBody = bodyH + 900
                let expected = ctx(fW, totalBody + fFooterH)
                if let allBody = content.cropping(to: CGRect(x: 0, y: 0, width: fW, height: totalBody)) {
                    expected.draw(footerBand, in: CGRect(x: 0, y: 0, width: fW, height: fFooterH))
                    expected.draw(allBody, in: CGRect(x: 0, y: fFooterH, width: fW, height: totalBody))
                }
                let expectedImg = expected.makeImage()!
                check("stitch-footer-height", composed3.height == totalBody + fFooterH,
                      "got \(composed3.height), want \(totalBody + fFooterH)")
                check("stitch-footer-content", imagesRoughlyEqual(expectedImg, composed3),
                      "footer relocated wrong")
                writePNG(composed3, to: "\(outputDir)/stitched-footer.png")
            } else {
                check("stitch-footer-compose", false)
            }
        }

        // 2d. Sticky footer with a BLINKING cursor row ------------------------------
        // The bar's cursor toggles between frames; the footer estimate must be
        // latched once for the session (a flapping per-pair estimate used to
        // bake bar fragments into the page mid-seam) and detection must bridge
        // the small dynamic band so the full bar height is latched up front.
        do {
            let fW = 400, fViewport = 500, fFooterH = 60, cursorH = 6, cursorFromBottom = 24
            let bodyH = fViewport - fFooterH
            let content = makeStripePattern(width: fW, height: 2000, seed: 0xB114_CAFE)
            let barA = makeStripePattern(width: fW, height: fFooterH, seed: 0xFEE7)
            // variant B: same bar, one bright "cursor" band toggled
            let barB: CGImage = {
                let c = ctx(fW, fFooterH)
                c.draw(barA, in: CGRect(x: 0, y: 0, width: fW, height: fFooterH))
                c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                c.fill(CGRect(x: 20, y: cursorFromBottom, width: 80, height: cursorH))
                return c.makeImage()!
            }()

            func blinkFrame(offset: Int, phase: Int) -> CGImage? {
                guard let body = content.cropping(to: CGRect(x: 0, y: offset, width: fW, height: bodyH))
                else { return nil }
                let c = ctx(fW, fViewport)
                c.draw(phase % 2 == 0 ? barA : barB, in: CGRect(x: 0, y: 0, width: fW, height: fFooterH))
                c.draw(body, in: CGRect(x: 0, y: fFooterH, width: fW, height: bodyH))
                return c.makeImage()
            }

            let offsets = [0, 300, 620, 880]
            var s4: VerticalStitcher?
            var blinkOK = true
            for (i, off) in offsets.enumerated() {
                guard let frame = blinkFrame(offset: off, phase: i) else { blinkOK = false; break }
                if let s = s4 {
                    let rows = s.append(frame)
                    let want = off - offsets[i - 1]
                    if rows != want {
                        blinkOK = false
                        print("  blink step +\(want) → got \(rows)")
                    }
                } else {
                    s4 = VerticalStitcher(first: frame)
                }
            }
            check("stitch-footer-blink-appends", blinkOK)
            if let s4, let composed4 = s4.compose() {
                let totalBody = bodyH + 880
                check("stitch-footer-blink-height", composed4.height == totalBody + fFooterH,
                      "got \(composed4.height), want \(totalBody + fFooterH)")
            } else {
                check("stitch-footer-blink-compose", false)
            }
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

    private static func makeStripePattern(width: Int, height: Int, seed: UInt64 = 0x5EED_1234) -> CGImage {
        let c = ctx(width, height)
        var seed = seed
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

    /// Rows repeat every `period` px — worst case for overlap matching.
    private static func makePeriodicPattern(width: Int, height: Int, period: Int) -> CGImage {
        let c = ctx(width, height)
        for y in 0..<height {
            let phase = y % period
            let v = CGFloat(phase) / CGFloat(period)
            c.setFillColor(CGColor(srgbRed: v, green: 0.3 + v * 0.5, blue: 1 - v, alpha: 1))
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

    static func writePNG(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
