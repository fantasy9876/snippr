import AppKit
import Vision

/// Headless feature tests: `Snippr --selftest [outdir]`.
/// Exercises everything that doesn't need Screen Recording permission.
enum SelfTest {
    static func run(outputDir: String) -> Int32 {
        // Headless tests may run from the installed bundle and therefore share
        // its preferences domain. Never mutate real user settings here.
        Settings.registerDefaults(applyMigrations: false)
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

        // 2e. macOS overlay scroller -------------------------------------------------
        // NSScroller is drawn on top of the page and its thumb moves/fades while
        // the user scrolls.  It is not page content, so a changing strip at the
        // viewport edge must not make an otherwise exact overlap fail.
        do {
            let fW = 400, fViewport = 500
            let content: CGImage = {
                let c = ctx(fW, 1800)
                c.setFillColor(CGColor(gray: 0.98, alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: fW, height: 1800))
                var seed: UInt64 = 0x5C20_11E2
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat((seed >> 33) & 0xFF) / 255
                }
                var y = 12
                while y < 1780 {
                    let lines = 1 + Int(next() * 3)
                    c.setFillColor(CGColor(gray: 0.72 + next() * 0.12, alpha: 1))
                    c.fillEllipse(in: CGRect(x: 12, y: y, width: 22, height: 22))
                    for line in 0..<lines {
                        c.setFillColor(CGColor(gray: 0.35 + next() * 0.22, alpha: 1))
                        c.fill(CGRect(x: 48, y: y + line * 13,
                                      width: 70 + Int(next() * 260), height: 7))
                    }
                    y += 34 + Int(next() * 23)
                }
                return c.makeImage()!
            }()

            func scrollerFrame(offset: Int, thumbY: Int) -> CGImage? {
                guard let body = content.cropping(to: CGRect(
                    x: 0, y: offset, width: fW, height: fViewport
                )) else { return nil }
                let c = ctx(fW, fViewport)
                c.draw(body, in: CGRect(x: 0, y: 0, width: fW, height: fViewport))
                // Deliberately high-contrast to cover both light and dark pages.
                c.setFillColor(CGColor(gray: 0.08, alpha: 0.85))
                c.fill(CGRect(x: fW - 14, y: thumbY, width: 10, height: 96))
                return c.makeImage()
            }

            let offsets = [0, 120, 260, 430]
            let thumbPositions = [350, 290, 205, 105]
            var s5: VerticalStitcher?
            var scrollerOK = true
            for (i, off) in offsets.enumerated() {
                guard let frame = scrollerFrame(offset: off, thumbY: thumbPositions[i])
                else { scrollerOK = false; break }
                if let s = s5 {
                    let rows = s.append(frame)
                    let want = off - offsets[i - 1]
                    if rows != want {
                        scrollerOK = false
                        print("  overlay-scroller step +\(want) → got \(rows)")
                    }
                } else {
                    s5 = VerticalStitcher(first: frame)
                }
            }
            check("stitch-overlay-scroller", scrollerOK)
        }

        // 2f. fractional-pixel trackpad scroll -------------------------------------
        // A 23.5-point scroll on a 1x display re-rasterizes horizontal edges
        // between pixel rows. Multiple half-pixel stops must carry their
        // residual: 23.5 + 23.5 is 47 rows, not two rounded 24-row slices.
        do {
            let fW = 400, fViewport = 500
            let content = makeStripePattern(width: fW, height: 1200, seed: 0xF12A_C710)
            func frame(offset: Int) -> CGImage? {
                content.cropping(to: CGRect(
                    x: 0, y: offset, width: fW, height: fViewport
                ))
            }
            func blend(_ a: CGImage, _ b: CGImage, fraction: CGFloat) -> CGImage? {
                let c = ctx(fW, fViewport)
                c.interpolationQuality = .high
                c.draw(a, in: CGRect(x: 0, y: 0, width: fW, height: fViewport))
                c.setAlpha(fraction)
                c.draw(b, in: CGRect(x: 0, y: 0, width: fW, height: fViewport))
                return c.makeImage()
            }
            func frame(offset: Double) -> CGImage? {
                let low = Int(floor(offset))
                let fraction = CGFloat(offset - Double(low))
                guard fraction > 0.001 else { return frame(offset: low) }
                guard let a = frame(offset: low), let b = frame(offset: low + 1) else { return nil }
                return blend(a, b, fraction: fraction)
            }
            let positions = [0.0, 23.5, 47.0, 70.5, 94.0]
            let expectedRows = [24, 23, 24, 23]
            if let first = frame(offset: positions[0]) {
                let fractional = VerticalStitcher(first: first)
                var rows: [Int] = []
                for position in positions.dropFirst() {
                    guard let next = frame(offset: position) else { break }
                    rows.append(fractional.append(next))
                }
                check("stitch-fractional-trackpad-sequence", rows == expectedRows,
                      "got \(rows), want \(expectedRows)")
                check("stitch-fractional-trackpad-no-drift",
                      fractional.totalHeight == fViewport + 94,
                      "got \(fractional.totalHeight), want \(fViewport + 94)")
                check("stitch-fractional-trackpad-compose-height",
                      fractional.compose()?.height == fViewport + 94)
            } else {
                check("stitch-fractional-trackpad-frame", false)
            }
        }

        // 2g. capture backend fallback state ---------------------------------------
        // A transient sourceRect error must keep the fast path. Three consecutive
        // failures switch once to full-display crop without discarding content
        // already stitched from sourceRect (both backends produce the same pixel
        // geometry; append's size/confidence guards still reject a bad frame).
        do {
            var backend = ScrollingCapture.CaptureBackend.sourceRect
            check("scroll-fallback-transient-keeps-fast-path",
                  !backend.switchToFallback(afterConsecutiveFailures: 2)
                  && backend == .sourceRect)
            let switched = backend.switchToFallback(afterConsecutiveFailures: 3)
            check("scroll-fallback-after-three-errors", switched && backend == .fullDisplayCrop)

            // `screenRect` is attached to the same ScreenCaptureKit frame as
            // the pixels. Include a negative-origin display to catch accidental
            // NSScreen/global-coordinate assumptions on multi-monitor Macs.
            let requested = ValidatedRectCapture.requestedScreenRect(
                displayFrame: CGRect(x: -1728, y: 240, width: 1728, height: 1117),
                sourceRect: CGRect(x: 125, y: 210, width: 500, height: 400))
            check("scroll-sourcerect-metadata-global-origin",
                  requested == CGRect(x: -1603, y: 450, width: 500, height: 400),
                  "got \(requested)")
            check("scroll-sourcerect-metadata-valid",
                  ValidatedRectCapture.matches(
                    CGRect(x: -1602.5, y: 449.5, width: 500, height: 400),
                    requested: requested))
            check("scroll-sourcerect-success-wrong-region-rejected",
                  !ValidatedRectCapture.matches(
                    CGRect(x: -1478, y: 450, width: 500, height: 400),
                    requested: requested))
            check("scroll-sourcerect-missing-metadata-rejected",
                  !ValidatedRectCapture.matches(nil, requested: requested))

            // Canonicalize a fractional @2x selection once. Both SCK output
            // and a full-display fallback must use this exact 801x601 bitmap,
            // rather than independently rounding to 800/801 pixels.
            let fractionalRegion = CanonicalCaptureRegion(
                screenSize: CGSize(width: 1440, height: 900),
                viewRect: CGRect(x: 100.25, y: 80.25, width: 400.1, height: 300.1),
                scale: 2)
            check("scroll-canonical-fractional-2x-size",
                  fractionalRegion?.pixelWidth == 801
                  && fractionalRegion?.pixelHeight == 601,
                  "got \(String(describing: fractionalRegion?.pixelRect))")
            check("scroll-canonical-fractional-2x-source-size",
                  fractionalRegion.map {
                    Int(($0.sourceRect.width * $0.scale).rounded()) == $0.pixelWidth
                    && Int(($0.sourceRect.height * $0.scale).rounded()) == $0.pixelHeight
                  } ?? false)

            if let fractionalRegion {
                let full = makeStripePattern(
                    width: 2880, height: 1800, seed: 0xCA90_21CA)
                let captured = CapturedImage(cgImage: full, scale: 2)
                check("scroll-canonical-fallback-crop-size",
                      captured.cropping(to: fractionalRegion).map {
                        $0.cgImage.width == fractionalRegion.pixelWidth
                        && $0.cgImage.height == fractionalRegion.pixelHeight
                      } ?? false)
            }

            let content = makeStripePattern(width: 200, height: 900, seed: 0xFA11_BACC)
            if let f0 = content.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 400)),
               let f1 = content.cropping(to: CGRect(x: 0, y: 120, width: 200, height: 400)),
               let f2 = content.cropping(to: CGRect(x: 0, y: 240, width: 200, height: 400)) {
                let retained = VerticalStitcher(first: f0)
                _ = retained.append(f1) // content accumulated on sourceRect
                check("scroll-fallback-overlap-handshake",
                      ScrollingCapture.validateBackendTransition(
                        stitcher: retained, frame: f2))
                _ = retained.append(f2) // first validated full-crop frame
                check("scroll-fallback-retains-accumulated-content",
                      retained.totalHeight == 640, "got \(retained.totalHeight), want 640")
                if let f3 = content.cropping(to: CGRect(
                    x: 0, y: 360, width: 200, height: 400)) {
                    let continued = retained.append(f3)
                    check("scroll-fallback-continues-after-switch", continued == 120,
                          "appended \(continued), want 120")
                    check("scroll-fallback-continued-height", retained.totalHeight == 760,
                          "got \(retained.totalHeight), want 760")
                } else {
                    check("scroll-fallback-continuation-frame", false)
                }

                let unrelated = makeStripePattern(
                    width: 200, height: 400, seed: 0xBAD0_C00D)
                check("scroll-fallback-wrong-region-not-mixed",
                      !ScrollingCapture.validateBackendTransition(
                        stitcher: retained, frame: unrelated))
                if let wrongGeometry = unrelated.cropping(to: CGRect(
                    x: 0, y: 0, width: 199, height: 400)) {
                    check("scroll-fallback-geometry-not-mixed",
                          !ScrollingCapture.validateBackendTransition(
                            stitcher: retained, frame: wrongGeometry))
                } else {
                    check("scroll-fallback-geometry-frame", false)
                }
            } else {
                check("scroll-fallback-retains-frames", false)
            }
            check("scroll-fallback-switches-once",
                  !backend.switchToFallback(afterConsecutiveFailures: 4))
        }

        // 2f. Editable capture/crop selection geometry -----------------------------
        // Both the full-screen overlay and editor crop UI use these helpers.
        let selectionBounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let initialSelection = EditableSelectionGeometry.rect(
            from: CGPoint(x: 500, y: 500),
            to: CGPoint(x: 100, y: 120),
            within: selectionBounds
        )
        check("selection-normalizes-reverse-drag",
              initialSelection == CGRect(x: 100, y: 120, width: 400, height: 380))
        let movedSelection = EditableSelectionGeometry.moved(
            initialSelection,
            by: CGPoint(x: 900, y: -400),
            within: selectionBounds
        )
        check("selection-move-clamps",
              movedSelection == CGRect(x: 600, y: 0, width: 400, height: 380),
              "got \(movedSelection)")
        let resizedSelection = EditableSelectionGeometry.resized(
            initialSelection,
            using: .topRight,
            to: CGPoint(x: 1200, y: 900),
            within: selectionBounds
        )
        check("selection-resize-clamps",
              resizedSelection == CGRect(x: 100, y: 120, width: 900, height: 580),
              "got \(resizedSelection)")
        check("selection-handle-hit",
              EditableSelectionGeometry.handle(
                at: CGPoint(x: initialSelection.maxX + 3, y: initialSelection.maxY - 2),
                in: initialSelection
              ) == .topRight)
        let pixelCrop = EditableSelectionGeometry.pixelCropRect(
            for: initialSelection, in: selectionBounds, scale: 2
        )
        check("selection-pixel-crop-orientation",
              pixelCrop == CGRect(x: 200, y: 400, width: 800, height: 760),
              "got \(pixelCrop)")
        let fractionalPixelCrop = EditableSelectionGeometry.pixelCropRect(
            for: CGRect(x: 10.25, y: 20.25, width: 100.1, height: 80.1),
            in: selectionBounds, scale: 2
        )
        let annotationOffset = EditableSelectionGeometry.annotationOffset(
            forPixelCrop: fractionalPixelCrop,
            imageHeight: selectionBounds.height * 2
        )
        check("selection-crop-annotation-integral-offset",
              annotationOffset == CGPoint(
                x: fractionalPixelCrop.minX,
                y: selectionBounds.height * 2 - fractionalPixelCrop.maxY
              ), "got \(annotationOffset)")

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
