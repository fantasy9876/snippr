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
            let appended = s2.append(f1).newRows
            check("stitch-ambiguous-rejected", appended == 0,
                  "appended \(appended) rows from ambiguous content")
        } else {
            check("stitch-ambiguous-crop", false)
        }

        // 2b-up. Bottom-to-top capture ---------------------------------------------
        // Scrolling upward reveals new content at the TOP of the viewport. The
        // matcher finds the reversed overlap and the stitcher prepends, so a
        // session that starts at the end of a page still produces the full page.
        do {
            let doc = makeStripePattern(width: 400, height: 2000, seed: 0xB1D1_5EED)
            let vp = 500
            var upOffsets: [Int] = []
            var position = 2000 - vp
            while position > 0 {
                upOffsets.append(position)
                position -= 320
            }
            upOffsets.append(0)
            var up: VerticalStitcher?
            var prepends = 0
            var rejects = 0
            for off in upOffsets {
                guard let frame = doc.cropping(to: CGRect(
                    x: 0, y: off, width: 400, height: vp)) else {
                    check("stitch-upscroll-crop", false); break
                }
                if let s = up {
                    switch s.append(frame) {
                    case .prepended: prepends += 1
                    case .rejected: rejects += 1
                    default: break
                    }
                } else {
                    up = VerticalStitcher(first: frame)
                }
            }
            let upComposed = up?.compose()
            check("stitch-upscroll-height", upComposed?.height == 2000,
                  "got \(upComposed?.height ?? -1), want 2000")
            check("stitch-upscroll-all-prepended",
                  prepends == upOffsets.count - 1 && rejects == 0,
                  "prepends \(prepends)/\(upOffsets.count - 1), rejects \(rejects)")
            if let upComposed {
                check("stitch-upscroll-content", imagesRoughlyEqual(doc, upComposed),
                      "up-scrolled content mismatch")
                writePNG(upComposed, to: "\(outputDir)/stitched-upscroll.png")
            }
        }

        // 2b-retrace. Reversing over already-captured rows -------------------------
        // Scrolling back up to re-read (then continuing down) used to reject
        // every reversed frame until the session dead-locked into a new segment
        // full of duplicates. A reversal over captured content must be a
        // confirmed `moved`, never a reject, and must not duplicate rows.
        do {
            let doc = makeStripePattern(width: 400, height: 2000, seed: 0x0FF5_E70D)
            let vp = 500
            let path = [0, 320, 640, 320, 80, 400, 720, 1040, 1360, 1500]
            var s: VerticalStitcher?
            var rejects = 0
            var moves = 0
            for off in path {
                guard let frame = doc.cropping(to: CGRect(
                    x: 0, y: off, width: 400, height: vp)) else {
                    check("stitch-retrace-crop", false); break
                }
                if let st = s {
                    switch st.append(frame) {
                    case .rejected: rejects += 1
                    case .moved: moves += 1
                    default: break
                    }
                } else {
                    s = VerticalStitcher(first: frame)
                }
            }
            let composed = s?.compose()
            check("stitch-retrace-height", composed?.height == 2000,
                  "got \(composed?.height ?? -1), want 2000")
            check("stitch-retrace-no-rejects", rejects == 0 && moves == 3,
                  "rejects \(rejects), moves \(moves) (want 0 and 3)")
            if let composed {
                check("stitch-retrace-content", imagesRoughlyEqual(doc, composed),
                      "retraced content mismatch")
            }
        }

        // 2b-mixed. Start mid-page, scroll up first, then down past the start ------
        do {
            let doc = makeStripePattern(width: 400, height: 2000, seed: 0x001A_ED00)
            let vp = 500
            let path = [800, 480, 160, 480, 800, 1120, 1440]
            var s: VerticalStitcher?
            var rejects = 0
            var prepends = 0
            var appends = 0
            for off in path {
                guard let frame = doc.cropping(to: CGRect(
                    x: 0, y: off, width: 400, height: vp)) else {
                    check("stitch-mixed-crop", false); break
                }
                if let st = s {
                    switch st.append(frame) {
                    case .rejected: rejects += 1
                    case .prepended: prepends += 1
                    case .appended: appends += 1
                    default: break
                    }
                } else {
                    s = VerticalStitcher(first: frame)
                }
            }
            let composed = s?.compose()
            let wantHeight = (1440 + vp) - 160
            check("stitch-mixed-height", composed?.height == wantHeight,
                  "got \(composed?.height ?? -1), want \(wantHeight)")
            check("stitch-mixed-outcomes",
                  rejects == 0 && prepends == 2 && appends == 2,
                  "rejects \(rejects), prepends \(prepends), appends \(appends)")
            if let composed,
               let wantImage = doc.cropping(to: CGRect(
                x: 0, y: 160, width: 400, height: wantHeight)) {
                check("stitch-mixed-content", imagesRoughlyEqual(wantImage, composed),
                      "mixed-direction content mismatch")
            }
        }

        // 2b-header-up. Up-scroll under fixed top chrome ---------------------------
        // Prepended strips must slide UNDER the header: the composed page keeps
        // the chrome on top exactly once, never repeated mid-page.
        do {
            let hW = 400, hViewport = 500, hHeader = 40
            let doc = makeStripePattern(width: hW, height: 2000, seed: 0x4EAD_F00D)
            let chrome = makeStripePattern(width: hW, height: hHeader, seed: 0xC0FF_EE00)
            func chromedFrame(offset: Int) -> CGImage? {
                guard let body = doc.cropping(to: CGRect(
                    x: 0, y: offset + hHeader, width: hW,
                    height: hViewport - hHeader)) else { return nil }
                let c = ctx(hW, hViewport)
                c.draw(chrome, in: CGRect(
                    x: 0, y: CGFloat(hViewport - hHeader),
                    width: CGFloat(hW), height: CGFloat(hHeader)))
                c.draw(body, in: CGRect(
                    x: 0, y: 0, width: CGFloat(hW),
                    height: CGFloat(hViewport - hHeader)))
                return c.makeImage()
            }
            let path = [1000, 700, 400, 100]
            var s: VerticalStitcher?
            var prepends = 0
            var rejects = 0
            for off in path {
                guard let frame = chromedFrame(offset: off) else {
                    check("stitch-header-up-crop", false); break
                }
                if let st = s {
                    switch st.append(frame) {
                    case .prepended: prepends += 1
                    case .rejected: rejects += 1
                    default: break
                    }
                } else {
                    s = VerticalStitcher(first: frame)
                }
            }
            let composed = s?.compose()
            // chrome once + doc body from (100 + hHeader) to (1000 + hViewport)
            let wantHeight = hHeader + (1000 + hViewport) - (100 + hHeader)
            check("stitch-header-up-height", composed?.height == wantHeight,
                  "got \(composed?.height ?? -1), want \(wantHeight)")
            check("stitch-header-up-outcomes", prepends == 3 && rejects == 0,
                  "prepends \(prepends), rejects \(rejects)")
            if let composed,
               let composedTop = composed.cropping(to: CGRect(
                x: 0, y: 0, width: hW, height: hHeader)) {
                check("stitch-header-up-chrome-on-top",
                      imagesRoughlyEqual(chrome, composedTop),
                      "top of composed image is not the fixed chrome")
            }
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
                    let rows = s.append(frame).newRows
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

            // The short-overlap path must apply the same footer geometry as
            // the primary matcher: recover the body, then attach the bar once.
            let recoveryOffsets = [0, 350, 390]
            var footerRecovery: VerticalStitcher?
            var recoveryRows: [Int] = []
            for off in recoveryOffsets {
                guard let frame = footerFrame(offset: off) else { break }
                if let footerRecovery {
                    recoveryRows.append(footerRecovery.append(frame).newRows)
                } else {
                    footerRecovery = VerticalStitcher(first: frame)
                }
            }
            check("stitch-footer-short-overlap-appends",
                  recoveryRows == [350, 40],
                  "appended \(recoveryRows), want [350, 40]")
            if let recovered = footerRecovery?.compose() {
                let totalBody = bodyH + recoveryOffsets.last!
                let expected = ctx(fW, totalBody + fFooterH)
                if let allBody = content.cropping(to: CGRect(
                    x: 0, y: 0, width: fW, height: totalBody)) {
                    expected.draw(footerBand, in: CGRect(
                        x: 0, y: 0, width: fW, height: fFooterH))
                    expected.draw(allBody, in: CGRect(
                        x: 0, y: fFooterH, width: fW, height: totalBody))
                }
                let expectedImage = expected.makeImage()!
                check("stitch-footer-short-overlap-height",
                      recovered.height == totalBody + fFooterH,
                      "got \(recovered.height), want \(totalBody + fFooterH)")
                check("stitch-footer-short-overlap-content",
                      imagesRoughlyEqual(expectedImage, recovered),
                      "short-overlap footer was duplicated or misplaced")
            } else {
                check("stitch-footer-short-overlap-compose", false)
            }
        }

        // 2c2. A low-detail fixed footer must beat a plausible no-footer match ----
        // Solid chat/cookie bars carry little horizontal energy. The moving body
        // can dominate the no-footer template enough to make both geometries
        // look confident, so footer selection must compare their actual scores.
        do {
            let fW = 400, fViewport = 500, fFooterH = 60
            let bodyH = fViewport - fFooterH
            let content = makeNoiseImage(width: fW, height: 1800)
            let footerBand = makeSolidImage(
                width: fW, height: fFooterH,
                color: CGColor(gray: 0.94, alpha: 1))

            func lowDetailFooterFrame(offset: Int) -> CGImage? {
                guard let body = content.cropping(to: CGRect(
                    x: 0, y: offset, width: fW, height: bodyH))
                else { return nil }
                let c = ctx(fW, fViewport)
                c.draw(footerBand, in: CGRect(
                    x: 0, y: 0, width: fW, height: fFooterH))
                c.draw(body, in: CGRect(
                    x: 0, y: fFooterH, width: fW, height: bodyH))
                return c.makeImage()
            }

            let positions = [0, 320, 640]
            var lowDetail: VerticalStitcher?
            var rows: [Int] = []
            for position in positions {
                guard let frame = lowDetailFooterFrame(offset: position) else { break }
                if let lowDetail {
                    rows.append(lowDetail.append(frame).newRows)
                } else {
                    lowDetail = VerticalStitcher(first: frame)
                }
            }
            check("stitch-low-detail-footer-appends",
                  rows == [320, 320], "appended \(rows)")
            check("stitch-low-detail-footer-detected",
                  lowDetail?.footerRows == fFooterH,
                  "got footer \(lowDetail?.footerRows ?? -1)")
            if let composed = lowDetail?.compose() {
                let totalBody = bodyH + positions.last!
                let expected = ctx(fW, totalBody + fFooterH)
                if let body = content.cropping(to: CGRect(
                    x: 0, y: 0, width: fW, height: totalBody)) {
                    expected.draw(footerBand, in: CGRect(
                        x: 0, y: 0, width: fW, height: fFooterH))
                    expected.draw(body, in: CGRect(
                        x: 0, y: fFooterH, width: fW, height: totalBody))
                }
                check("stitch-low-detail-footer-content",
                      imagesRoughlyEqual(expected.makeImage()!, composed),
                      "low-detail footer duplicated or body rows dropped")
            } else {
                check("stitch-low-detail-footer-compose", false)
            }
        }

        // 2c3. A coincidentally static page tail is not a sticky footer ---------
        // A long blank/repeated block can make both footer hypotheses score
        // perfectly. Latching a footer on that tie would silently discard real
        // page rows, so the complete-viewport interpretation must win.
        do {
            let height = 500, shift = 120, staticTail = 60
            var seed: UInt64 = 0xF00D_CAFE
            var document = [Double](repeating: 0, count: 620 * 4)
            for index in document.indices {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                document[index] = Double((seed >> 32) & 0xFF)
            }
            for row in 0..<staticTail {
                for band in 0..<4 {
                    document[(560 + row) * 4 + band]
                        = document[(440 + row) * 4 + band]
                }
            }
            func signature(start: Int) -> VerticalStitcher.RowSig {
                let first = start * 4
                let last = (start + height) * 4
                return VerticalStitcher.RowSig(
                    bands: Array(document[first..<last]),
                    energy: [Double](repeating: 10, count: height))
            }
            let match = VerticalStitcher.findOverlap(
                prev: signature(start: 0), next: signature(start: shift),
                height: height, scale: 1)
            check("stitch-static-page-tail-not-footer",
                  match?.footerRows == 0,
                  "got footer \(match?.footerRows ?? -1)")
            check("stitch-static-page-tail-offset",
                  abs((match?.preciseOffset ?? -1) - Double(shift)) < 0.001,
                  "got offset \(match?.preciseOffset ?? -1)")
        }

        // 2c4. Conflicting footer hypotheses must fail closed ---------------------
        // Two individually confident offsets describe mutually exclusive seams.
        // Score tie-breaking is unsafe here regardless of which geometry wins.
        do {
            let height = 500, footerRows = 60
            var seed: UInt64 = 0xF007_EA11
            func randomBands() -> [Double] {
                var values = [Double](repeating: 0, count: height * 4)
                for index in values.indices {
                    seed = seed &* 6364136223846793005
                        &+ 1442695040888963407
                    values[index] = Double((seed >> 32) & 0xFF)
                }
                return values
            }
            let previousBands = randomBands()
            var nextBands = randomBands()
            func copyRows(
                previousStart: Int, nextStart: Int, count: Int
            ) {
                for row in 0..<count {
                    for band in 0..<4 {
                        nextBands[(nextStart + row) * 4 + band]
                            = previousBands[(previousStart + row) * 4 + band]
                    }
                }
            }
            copyRows(previousStart: 375, nextStart: 255, count: 125)
            copyRows(previousStart: 330, nextStart: 130, count: 110)
            copyRows(
                previousStart: height - footerRows,
                nextStart: height - footerRows,
                count: footerRows)
            let previous = VerticalStitcher.RowSig(
                bands: previousBands,
                energy: [Double](repeating: 10, count: height))
            let next = VerticalStitcher.RowSig(
                bands: nextBands,
                energy: [Double](repeating: 10, count: height))
            let match = VerticalStitcher.findOverlap(
                prev: previous, next: next, height: height, scale: 1)
            check("stitch-conflicting-footer-hypotheses-rejected",
                  match == nil,
                  "accepted offset \(match?.preciseOffset ?? -1), "
                    + "footer \(match?.footerRows ?? -1)")
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
                    let rows = s.append(frame).newRows
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
                check("stitch-footer-blink-detected",
                      s4.footerRows == fFooterH,
                      "got footer \(s4.footerRows), want \(fFooterH)")
                let expected = ctx(fW, totalBody + fFooterH)
                if let body = content.cropping(to: CGRect(
                    x: 0, y: 0, width: fW, height: totalBody)) {
                    expected.draw(barB, in: CGRect(
                        x: 0, y: 0, width: fW, height: fFooterH))
                    expected.draw(body, in: CGRect(
                        x: 0, y: fFooterH, width: fW, height: totalBody))
                }
                check("stitch-footer-blink-content",
                      imagesRoughlyEqual(expected.makeImage()!, composed4),
                      "blinking footer duplicated or misplaced")
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
                    let rows = s.append(frame).newRows
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
                    rows.append(fractional.append(next).newRows)
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

        // 2g. Fine text while a macOS trackpad is between backing pixels ----------
        // The coarse stripe fixture above stays easy after interpolation. Real
        // glyph strokes are only a couple of pixels tall: WindowServer's
        // subpixel re-rasterization changes their raw per-row signatures enough
        // that the correct offset can lose the matcher's absolute-score gate.
        do {
            let fW = 1000, fViewport = 1200, documentHeight = 8000
            let content: CGImage = {
                let c = ctx(fW, documentHeight)
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: fW, height: documentHeight))
                var seed: UInt64 = 0xBEEF_F00D
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat((seed >> 33) & 0xFF) / 255
                }
                c.translateBy(x: 0, y: CGFloat(documentHeight))
                c.scaleBy(x: 1, y: -1)
                var y: CGFloat = 10
                while y < CGFloat(documentHeight) {
                    var x: CGFloat = 40 + next() * 60
                    let lineEnd = 200 + next() * 700
                    while x < lineEnd {
                        c.setFillColor(CGColor(gray: 0.15 + next() * 0.25, alpha: 1))
                        c.fill(CGRect(x: x, y: y, width: 4 + next() * 14, height: 2))
                        x += 6 + next() * 12
                    }
                    y += 32
                }
                return c.makeImage()!
            }()

            func fineTextFrame(offset: Double) -> CGImage? {
                let c = ctx(fW, fViewport)
                c.interpolationQuality = .high
                c.draw(content, in: CGRect(
                    x: 0,
                    y: CGFloat(fViewport - documentHeight) + CGFloat(offset),
                    width: CGFloat(fW),
                    height: CGFloat(documentHeight)))
                return c.makeImage()
            }

            let positions = [0.0, 100.4, 220.7, 340.3, 500.6, 640.2]
            if let first = fineTextFrame(offset: positions[0]) {
                let fineText = VerticalStitcher(first: first, scale: 2)
                var rows: [Int] = []
                for position in positions.dropFirst() {
                    guard let next = fineTextFrame(offset: position) else { break }
                    rows.append(fineText.append(next).newRows)
                }
                check("stitch-fine-text-fractional-accepts-all",
                      rows.count == positions.count - 1 && rows.allSatisfy { $0 > 0 },
                      "appended \(rows)")
                let expectedHeight = fViewport + Int(positions.last!.rounded())
                check("stitch-fine-text-fractional-no-drift",
                      abs(fineText.totalHeight - expectedHeight) <= 1,
                      "got \(fineText.totalHeight), want \(expectedHeight)±1")

                // Same fractional trackpad positions, scrolled bottom-to-top.
                // The macOS failure mode (odd backing-pixel offsets from
                // momentum scrolling) must not resurface in the up direction.
                if let upFirst = fineTextFrame(offset: positions.last!) {
                    let fineTextUp = VerticalStitcher(first: upFirst, scale: 2)
                    var upRows: [Int] = []
                    var upRejects = 0
                    for position in positions.dropLast().reversed() {
                        guard let next = fineTextFrame(offset: position) else { break }
                        let result = fineTextUp.append(next)
                        upRows.append(result.newRows)
                        if !result.isAccepted { upRejects += 1 }
                    }
                    check("stitch-fine-text-fractional-upscroll-accepts-all",
                          upRows.count == positions.count - 1 && upRejects == 0
                            && upRows.allSatisfy { $0 > 0 },
                          "prepended \(upRows), rejects \(upRejects)")
                    check("stitch-fine-text-fractional-upscroll-no-drift",
                          abs(fineTextUp.totalHeight - expectedHeight) <= 1,
                          "got \(fineTextUp.totalHeight), want \(expectedHeight)±1")
                }

                // A real flick combines both failure modes: fractional
                // re-rasterization and less overlap than the primary 25%
                // template. Keep this distinct from the small-step case above
                // and the integer stripe recovery below.
                let recoveryViewport = 1000
                func recoveryFrame(offset: Double) -> CGImage? {
                    let c = ctx(fW, recoveryViewport)
                    c.interpolationQuality = .high
                    c.draw(content, in: CGRect(
                        x: 0,
                        y: CGFloat(recoveryViewport - documentHeight) + CGFloat(offset),
                        width: CGFloat(fW),
                        height: CGFloat(documentHeight)))
                    return c.makeImage()
                }
                let recoveryPositions = [0.0, 800.4, 880.4]
                if let recoveryFirst = recoveryFrame(offset: recoveryPositions[0]) {
                    let fractionalRecovery = VerticalStitcher(
                        first: recoveryFirst, scale: 2)
                    var recoveryRows: [Int] = []
                    for position in recoveryPositions.dropFirst() {
                        guard let next = recoveryFrame(offset: position) else { break }
                        recoveryRows.append(fractionalRecovery.append(next).newRows)
                    }
                    check("stitch-fine-text-fractional-short-overlap-recovers",
                          recoveryRows.count == recoveryPositions.count - 1
                            && recoveryRows.allSatisfy { $0 > 0 },
                          "appended \(recoveryRows)")
                    let expectedRecoveryHeight = recoveryViewport
                        + Int(recoveryPositions.last!.rounded())
                    check("stitch-fine-text-fractional-short-overlap-no-drift",
                          abs(fractionalRecovery.totalHeight
                              - expectedRecoveryHeight) <= 1,
                          "got \(fractionalRecovery.totalHeight), "
                            + "want \(expectedRecoveryHeight)±1")
                    check("stitch-fine-text-fractional-short-overlap-no-footer",
                          fractionalRecovery.footerRows == 0,
                          "false footer \(fractionalRecovery.footerRows)")
                    if let recoveredImage = fractionalRecovery.compose() {
                        let expected = ctx(fW, expectedRecoveryHeight)
                        expected.interpolationQuality = .high
                        expected.draw(content, in: CGRect(
                            x: 0,
                            y: CGFloat(expectedRecoveryHeight - documentHeight),
                            width: CGFloat(fW),
                            height: CGFloat(documentHeight)))
                        check("stitch-fine-text-fractional-short-overlap-content",
                              imagesRoughlyEqual(
                                expected.makeImage()!, recoveredImage),
                              "fractional short-overlap content mismatch")
                    } else {
                        check("stitch-fine-text-fractional-short-overlap-compose",
                              false)
                    }

                    let driftPositions = [
                        0.0, 800.4, 1600.8, 2401.2, 3201.6, 4002.0
                    ]
                    if let driftFirst = recoveryFrame(offset: driftPositions[0]) {
                        let driftRecovery = VerticalStitcher(
                            first: driftFirst, scale: 2)
                        var driftRows: [Int] = []
                        for position in driftPositions.dropFirst() {
                            guard let next = recoveryFrame(offset: position) else {
                                break
                            }
                            driftRows.append(driftRecovery.append(next).newRows)
                        }
                        let expectedDriftHeight = recoveryViewport
                            + Int(driftPositions.last!.rounded())
                        check("stitch-fine-text-fractional-short-overlap-sequence",
                              driftRows.count == driftPositions.count - 1
                                && driftRows.allSatisfy { $0 > 0 },
                              "appended \(driftRows)")
                        check("stitch-fine-text-fractional-short-overlap-carries-phase",
                              driftRecovery.totalHeight == expectedDriftHeight,
                              "got \(driftRecovery.totalHeight), "
                                + "want \(expectedDriftHeight)")
                        check("stitch-fine-text-fractional-short-overlap-sequence-no-footer",
                              driftRecovery.footerRows == 0,
                              "false footer \(driftRecovery.footerRows)")
                        if let driftImage = driftRecovery.compose() {
                            let expected = ctx(fW, expectedDriftHeight)
                            expected.interpolationQuality = .high
                            expected.draw(content, in: CGRect(
                                x: 0,
                                y: CGFloat(expectedDriftHeight - documentHeight),
                                width: CGFloat(fW),
                                height: CGFloat(documentHeight)))
                            check("stitch-fine-text-fractional-short-overlap-sequence-content",
                                  imagesRoughlyEqual(
                                    expected.makeImage()!, driftImage),
                                  "fractional short-overlap sequence mismatch")
                        } else {
                            check("stitch-fine-text-fractional-short-overlap-sequence-compose",
                                  false)
                        }
                    } else {
                        check("stitch-fine-text-fractional-short-overlap-drift-frame",
                              false)
                    }
                } else {
                    check("stitch-fine-text-fractional-short-overlap-frame", false)
                }
            } else {
                check("stitch-fine-text-fractional-frame", false)
            }
        }

        // 2g2. Raw short-overlap must preserve fractional phase -------------------
        // Not every fractional flick needs the blur fallback. On a smooth but
        // unique signal the raw short matcher can score below 2.0 at the right
        // integer row while the true displacement is still fractional. Returning
        // the integer valley here loses that phase on every fast step.
        do {
            let height = 500
            func signal(_ row: Double, band: Int) -> Double {
                128 + 100 * sin(
                    2 * Double.pi * row / 800
                    + Double(band) * Double.pi / 2)
            }
            func signature(offset: Double) -> VerticalStitcher.RowSig {
                var bands: [Double] = []
                bands.reserveCapacity(height * 4)
                for row in 0..<height {
                    for band in 0..<4 {
                        bands.append(signal(Double(row) + offset, band: band))
                    }
                }
                return VerticalStitcher.RowSig(
                    bands: bands,
                    energy: [Double](repeating: 10, count: height))
            }

            let previous = signature(offset: 0)
            let fractional = VerticalStitcher.findOverlap(
                prev: previous, next: signature(offset: 400.4),
                height: height, scale: 1, lockedFooter: 0)
            check("stitch-raw-short-overlap-preserves-fractional-phase",
                  abs((fractional?.preciseOffset ?? -1) - 400.4) < 0.15,
                  "got \(fractional?.preciseOffset ?? -1), want 400.4±0.15")

            let exact = VerticalStitcher.findOverlap(
                prev: previous, next: signature(offset: 400),
                height: height, scale: 1, lockedFooter: 0)
            check("stitch-raw-short-overlap-keeps-exact-integer",
                  abs((exact?.preciseOffset ?? -1) - 400) < 0.001,
                  "got \(exact?.preciseOffset ?? -1), want 400")
        }

        // 2h. Short-overlap recovery after a fast trackpad step -------------------
        // The primary matcher deliberately requires about 25% overlap. A fast
        // but still recoverable step can leave 10–20%; without a conservative
        // second pass, the reference frame never advances and all later slow
        // frames are rejected too.
        do {
            let fW = 400, fViewport = 500
            let content = makeStripePattern(width: fW, height: 1100, seed: 0x5A07_0A11)
            let positions = [0, 400, 440]
            var recovery: VerticalStitcher?
            var rows: [Int] = []
            for position in positions {
                guard let frame = content.cropping(to: CGRect(
                    x: 0, y: position, width: fW, height: fViewport))
                else { break }
                if let recovery {
                    rows.append(recovery.append(frame).newRows)
                } else {
                    recovery = VerticalStitcher(first: frame)
                }
            }
            check("stitch-short-overlap-recovers",
                  rows == [400, 40], "appended \(rows), want [400, 40]")
            check("stitch-short-overlap-height",
                  recovery?.totalHeight == 940,
                  "got \(recovery?.totalHeight ?? -1), want 940")
            if let composed = recovery?.compose(),
               let expected = content.cropping(to: CGRect(
                   x: 0, y: 0, width: fW, height: 940)) {
                check("stitch-short-overlap-content",
                      imagesRoughlyEqual(expected, composed),
                      "short-overlap stitch content mismatch")
            } else {
                check("stitch-short-overlap-compose", false)
            }

            let ambiguous = makePeriodicPattern(width: fW, height: 1000, period: 37)
            if let a0 = ambiguous.cropping(to: CGRect(
                   x: 0, y: 0, width: fW, height: fViewport)),
               let a400 = ambiguous.cropping(to: CGRect(
                   x: 0, y: 400, width: fW, height: fViewport)) {
                let alias = VerticalStitcher(first: a0)
                check("stitch-short-overlap-ambiguous-rejected",
                      alias.append(a400).newRows == 0)
            } else {
                check("stitch-short-overlap-ambiguous-frame", false)
            }

            if let n0 = content.cropping(to: CGRect(
                   x: 0, y: 0, width: fW, height: fViewport)),
               let n500 = content.cropping(to: CGRect(
                   x: 0, y: 500, width: fW, height: fViewport)) {
                let noOverlap = VerticalStitcher(first: n0)
                check("stitch-no-overlap-rejected", noOverlap.append(n500).newRows == 0)
            } else {
                check("stitch-no-overlap-frame", false)
            }

            func replacingRows(
                in image: CGImage, destinationStart: Int,
                from source: CGImage, sourceStart: Int, count: Int
            ) -> CGImage? {
                let rowBytes = fW * 4
                let sourceBytes = rgbaBytes(source)
                var destinationBytes = rgbaBytes(image)
                for row in 0..<count {
                    let sourceOffset = (sourceStart + row) * rowBytes
                    let destinationOffset = (destinationStart + row) * rowBytes
                    destinationBytes.replaceSubrange(
                        destinationOffset..<(destinationOffset + rowBytes),
                        with: sourceBytes[sourceOffset..<(sourceOffset + rowBytes)])
                }
                return destinationBytes.withUnsafeMutableBytes { bytes in
                    guard let context = CGContext(
                        data: bytes.baseAddress,
                        width: fW, height: fViewport,
                        bitsPerComponent: 8, bytesPerRow: rowBytes,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return nil }
                    return context.makeImage()
                }
            }

            // A copied strip shorter than the recovery evidence must not turn
            // two adjacent, non-overlapping frames into a fabricated seam.
            if let a = content.cropping(to: CGRect(
                   x: 0, y: 0, width: fW, height: fViewport)),
               let b = content.cropping(to: CGRect(
                   x: 0, y: fViewport, width: fW, height: fViewport)),
               let decoy = replacingRows(
                   in: b, destinationStart: 0,
                   from: a, sourceStart: fViewport - 64, count: 64) {
                let decoyRecovery = VerticalStitcher(first: a)
                check("stitch-short-overlap-64-row-decoy-rejected",
                      decoyRecovery.append(decoy).newRows == 0)
            } else {
                check("stitch-short-overlap-64-row-decoy-frame", false)
            }

            // A long primary template can be an exact one-off duplicate while
            // the true displacement lives just outside its search range. The
            // shorter global probe must expose both basins and veto the alias.
            if let a = content.cropping(to: CGRect(
                   x: 0, y: 0, width: fW, height: fViewport)),
               let b = content.cropping(to: CGRect(
                   x: 0, y: 400, width: fW, height: fViewport)),
               let decoy = replacingRows(
                   in: b, destinationStart: 275,
                   from: a, sourceStart: 375, count: 125) {
                let primaryDecoy = VerticalStitcher(first: a)
                check("stitch-primary-alias-with-short-overlap-rejected",
                      primaryDecoy.append(decoy).newRows == 0,
                      "ambiguous 100/400-row basins must not be guessed")
            } else {
                check("stitch-primary-alias-with-short-overlap-frame", false)
            }

            // A primary candidate that reaches into a fixed header is not a
            // valid body overlap. A one-off copied block spanning that boundary
            // must be rejected instead of silently dropping page content.
            do {
                let height = 500, headerRows = 60
                var seed: UInt64 = 0xA11A_5EAD
                func randomBands() -> [Double] {
                    var values = [Double](repeating: 0, count: height * 4)
                    for index in values.indices {
                        seed = seed &* 6364136223846793005
                            &+ 1442695040888963407
                        values[index] = Double((seed >> 32) & 0xFF)
                    }
                    return values
                }
                var previousBands = randomBands()
                var nextBands = randomBands()
                for row in 0..<headerRows {
                    for band in 0..<4 {
                        nextBands[row * 4 + band]
                            = previousBands[row * 4 + band]
                    }
                }
                // next[5..<130] = previous[375..<500]. Preserve the already
                // static header where those ranges intersect.
                for row in 0..<55 {
                    for band in 0..<4 {
                        previousBands[(375 + row) * 4 + band]
                            = previousBands[(5 + row) * 4 + band]
                    }
                }
                for row in 0..<125 {
                    for band in 0..<4 {
                        nextBands[(5 + row) * 4 + band]
                            = previousBands[(375 + row) * 4 + band]
                    }
                }
                let previous = VerticalStitcher.RowSig(
                    bands: previousBands,
                    energy: [Double](repeating: 10, count: height))
                let next = VerticalStitcher.RowSig(
                    bands: nextBands,
                    energy: [Double](repeating: 10, count: height))
                let match = VerticalStitcher.findOverlap(
                    prev: previous, next: next, height: height,
                    scale: 1, lockedFooter: 0)
                check("stitch-primary-alias-crossing-header-rejected",
                      match == nil,
                      "accepted offset \(match?.preciseOffset ?? -1) "
                        + "from an ambiguous header/body frame")
            }

            let retinaContent = makeStripePattern(
                width: fW, height: 2200, seed: 0x2A2A_8008)
            if let r0 = retinaContent.cropping(to: CGRect(
                   x: 0, y: 0, width: fW, height: 1000)),
               let r800 = retinaContent.cropping(to: CGRect(
                   x: 0, y: 800, width: fW, height: 1000)) {
                let retina = VerticalStitcher(first: r0, scale: 2)
                check("stitch-short-overlap-retina-recovers",
                      retina.append(r800).newRows == 800)
            } else {
                check("stitch-short-overlap-retina-frame", false)
            }

            // A fixed top navigation bar is not part of the moving overlap.
            // Recovery must validate only the body while keeping the header
            // once at the top of the composed shot.
            let headerH = 60
            let headerBodyH = fViewport - headerH
            let headerContent = makeStripePattern(
                width: fW, height: 1200, seed: 0x1EA0_EA01)
            let headerBand = makeStripePattern(
                width: fW, height: headerH, seed: 0xAEAD_EA01)
            func headerFrame(offset: Int) -> CGImage? {
                guard let body = headerContent.cropping(to: CGRect(
                    x: 0, y: offset, width: fW, height: headerBodyH))
                else { return nil }
                let c = ctx(fW, fViewport)
                c.draw(body, in: CGRect(
                    x: 0, y: 0, width: fW, height: headerBodyH))
                c.draw(headerBand, in: CGRect(
                    x: 0, y: headerBodyH, width: fW, height: headerH))
                return c.makeImage()
            }
            let headerPositions = [0, 350, 390]
            var headerRecovery: VerticalStitcher?
            var headerRows: [Int] = []
            for position in headerPositions {
                guard let frame = headerFrame(offset: position) else { break }
                if let headerRecovery {
                    headerRows.append(headerRecovery.append(frame).newRows)
                } else {
                    headerRecovery = VerticalStitcher(first: frame)
                }
            }
            check("stitch-short-overlap-sticky-header-appends",
                  headerRows == [350, 40],
                  "appended \(headerRows), want [350, 40]")
            if let headerImage = headerRecovery?.compose() {
                let totalBody = headerBodyH + headerPositions.last!
                let expected = ctx(fW, headerH + totalBody)
                if let body = headerContent.cropping(to: CGRect(
                    x: 0, y: 0, width: fW, height: totalBody)) {
                    expected.draw(body, in: CGRect(
                        x: 0, y: 0, width: fW, height: totalBody))
                    expected.draw(headerBand, in: CGRect(
                        x: 0, y: totalBody, width: fW, height: headerH))
                }
                check("stitch-short-overlap-sticky-header-content",
                      imagesRoughlyEqual(expected.makeImage()!, headerImage),
                      "sticky header duplicated or body seam corrupted")
            } else {
                check("stitch-short-overlap-sticky-header-compose", false)
            }
        }

        // 2h1b. Mid-session reversal must NOT split a segment ----------------------
        // The field failure behind duplicated blocks: scroll down, scroll back
        // up to re-read, continue down. Reversed frames used to reject until
        // the session re-anchored a new segment from the higher viewport and
        // re-captured everything below it. Now the reversal is a confirmed
        // move: one segment, no separator, no duplicate rows.
        do {
            let doc = makeStripePattern(width: 400, height: 2200, seed: 0x5E63_4EAD)
            let vp = 500
            let path = [0, 300, 600, 900, 600, 300, 600, 900, 1200, 1500, 1700]
            if let first = doc.cropping(to: CGRect(
                x: 0, y: path[0], width: 400, height: vp)) {
                let segmented = SegmentedVerticalStitcher(first: first)
                var splits = 0
                var rejects = 0
                for off in path.dropFirst() {
                    guard let frame = doc.cropping(to: CGRect(
                        x: 0, y: off, width: 400, height: vp)) else {
                        check("stitch-segment-reversal-crop", false); break
                    }
                    switch segmented.append(frame) {
                    case .startedSegment: splits += 1
                    case .rejected: rejects += 1
                    default: break
                    }
                }
                check("stitch-segment-reversal-single-segment",
                      splits == 0 && rejects == 0 && segmented.segmentCount == 1,
                      "splits \(splits), rejects \(rejects), segments \(segmented.segmentCount)")
                let composed = segmented.compose()
                check("stitch-segment-reversal-height", composed?.height == 2200,
                      "got \(composed?.height ?? -1), want 2200")
                if let composed {
                    check("stitch-segment-reversal-content",
                          imagesRoughlyEqual(doc, composed),
                          "reversal duplicated or dropped rows")
                }
            } else {
                check("stitch-segment-reversal-crop", false)
            }
        }

        // 2h2. Complete overlap loss re-anchors only to a proven new segment -------
        // A fast flick can move farther than the viewport. There is no honest
        // seam to infer in that case, so the session waits until later frames
        // prove a new contiguous strip, then inserts a visible boundary marker.
        do {
            func expectedSegmentedImage(
                upper: CGImage, separator: CGImage, lower: CGImage
            ) -> CGImage? {
                guard upper.width == lower.width,
                      upper.width == separator.width else { return nil }
                let height = upper.height + separator.height + lower.height
                let c = ctx(upper.width, height)
                var y = height
                for image in [upper, separator, lower] {
                    y -= image.height
                    c.draw(image, in: CGRect(
                        x: 0, y: y, width: image.width, height: image.height))
                }
                return c.makeImage()
            }

            // S-C: one valid step, a huge flick, then several slow frames.
            let width = 400, viewport = 600
            let document = makeStripePattern(
                width: width, height: 3600, seed: 0x5C00_0F11)
            let positions = [0, 150, 2650, 2690, 2730, 2770, 2810]
            if let first = document.cropping(to: CGRect(
                x: 0, y: positions[0], width: width, height: viewport)) {
                let segmented = SegmentedVerticalStitcher(first: first)
                var promotedAt: Int?
                var lastRows = 0
                for position in positions.dropFirst() {
                    guard let frame = document.cropping(to: CGRect(
                        x: 0, y: position, width: width, height: viewport))
                    else { break }
                    switch segmented.append(frame) {
                    case let .appended(rows):
                        lastRows = rows
                    case .prepended, .moved, .rejected:
                        break
                    case .startedSegment:
                        promotedAt = position
                    }
                }
                check("stitch-segment-reanchor-after-flick",
                      promotedAt == 2770 && segmented.segmentCount == 2,
                      "promotedAt \(promotedAt ?? -1), segments "
                        + "\(segmented.segmentCount)")
                check("stitch-segment-reanchor-continues",
                      lastRows == 40 && segmented.totalHeight
                        == 750 + segmented.separatorRows + 760,
                      "lastRows \(lastRows), height \(segmented.totalHeight)")
                if let upper = document.cropping(to: CGRect(
                       x: 0, y: 0, width: width, height: 750)),
                   let lower = document.cropping(to: CGRect(
                       x: 0, y: 2650, width: width, height: 760)),
                   let separator = segmented.segmentSeparator(),
                   let expected = expectedSegmentedImage(
                       upper: upper, separator: separator, lower: lower),
                   let actual = segmented.compose() {
                    check("stitch-segment-reanchor-marked-content",
                          imagesRoughlyEqual(expected, actual),
                          "segment boundary/content mismatch")
                } else {
                    check("stitch-segment-reanchor-compose", false)
                }
            } else {
                check("stitch-segment-reanchor-frame", false)
            }

            // S-F: 200 pt selection at 2x, 170 pt steps. The first three
            // candidates cannot prove the minimum 64 pt overlap; 1020→1060 can,
            // so reject #4 promotes that pending strip and 1100 continues it.
            let retinaViewport = 400
            let fineDocument: CGImage = {
                let c = ctx(width, 1800)
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: width, height: 1800))
                var seed: UInt64 = 0x5F00_2A2A
                for y in stride(from: 8, to: 1790, by: 24) {
                    seed = seed &* 6364136223846793005
                        &+ 1442695040888963407
                    let inset = Int((seed >> 32) % 90)
                    c.setFillColor(CGColor(gray: 0.18, alpha: 1))
                    c.fill(CGRect(
                        x: 24 + inset, y: y,
                        width: 180 + Int((seed >> 40) % 150), height: 2))
                }
                return c.makeImage()!
            }()
            let retinaPositions = [0, 340, 680, 1020, 1060, 1100]
            if let first = fineDocument.cropping(to: CGRect(
                x: 0, y: 0, width: width, height: retinaViewport)) {
                let segmented = SegmentedVerticalStitcher(first: first, scale: 2)
                var promotedAt: Int?
                var successfulFrames = 0
                for position in retinaPositions.dropFirst() {
                    guard let frame = fineDocument.cropping(to: CGRect(
                        x: 0, y: position,
                        width: width, height: retinaViewport)) else { break }
                    switch segmented.append(frame) {
                    case .appended:
                        successfulFrames += 1
                    case .startedSegment:
                        successfulFrames += 1
                        promotedAt = position
                    case .prepended, .moved, .rejected:
                        break
                    }
                }
                check("stitch-small-retina-reanchor",
                      promotedAt == 1060 && successfulFrames >= 2
                        && segmented.segmentCount == 2,
                      "promotedAt \(promotedAt ?? -1), successes "
                        + "\(successfulFrames), segments \(segmented.segmentCount)")
                let expectedHeight = 400 + segmented.separatorRows + 480
                check("stitch-small-retina-reanchor-height",
                      segmented.totalHeight == expectedHeight
                        && segmented.compose()?.height == expectedHeight,
                      "got \(segmented.totalHeight), want \(expectedHeight)")
                if let upper = fineDocument.cropping(to: CGRect(
                       x: 0, y: 0, width: width, height: 400)),
                   let lower = fineDocument.cropping(to: CGRect(
                       x: 0, y: 1020, width: width, height: 480)),
                   let separator = segmented.segmentSeparator(),
                   let expected = expectedSegmentedImage(
                       upper: upper, separator: separator, lower: lower),
                   let actual = segmented.compose() {
                    check("stitch-small-retina-reanchor-marked-content",
                          imagesRoughlyEqual(expected, actual))
                } else {
                    check("stitch-small-retina-reanchor-compose", false)
                }
            } else {
                check("stitch-small-retina-reanchor-frame", false)
            }

            // Each re-anchored strip starts from a full viewport, so a fixed
            // navigation bar would otherwise be repeated after every visible
            // gap marker. Keep it on the first segment only; later segments
            // may trim it only after their own first transition proves it is
            // fixed chrome.
            let segmentedHeaderHeight = 60
            let segmentedHeaderBodyHeight = viewport - segmentedHeaderHeight
            let segmentedHeaderContent = makeStripePattern(
                width: width, height: 3000, seed: 0x5E67_AEAD)
            let segmentedHeaderBand = makeStripePattern(
                width: width, height: segmentedHeaderHeight,
                seed: 0xBAA0_AEAD)
            func segmentedHeaderFrame(
                offset: Int, band: CGImage
            ) -> CGImage? {
                guard let body = segmentedHeaderContent.cropping(to: CGRect(
                    x: 0, y: offset,
                    width: width, height: segmentedHeaderBodyHeight
                )) else { return nil }
                let c = ctx(width, viewport)
                c.draw(body, in: CGRect(
                    x: 0, y: 0,
                    width: width, height: segmentedHeaderBodyHeight))
                c.draw(band, in: CGRect(
                    x: 0, y: segmentedHeaderBodyHeight,
                    width: width, height: segmentedHeaderHeight))
                return c.makeImage()
            }
            let segmentedHeaderPositions = [
                0, 200, 2000, 2041, 2083, 2126, 2170,
            ]
            if let first = segmentedHeaderFrame(
                offset: segmentedHeaderPositions[0],
                band: segmentedHeaderBand) {
                let segmented = SegmentedVerticalStitcher(first: first)
                for position in segmentedHeaderPositions.dropFirst() {
                    if let frame = segmentedHeaderFrame(
                        offset: position, band: segmentedHeaderBand) {
                        _ = segmented.append(frame)
                    }
                }
                let upperBodyHeight = segmentedHeaderBodyHeight + 200
                let lowerBodyHeight = segmentedHeaderBodyHeight + 170
                let upper = ctx(
                    width, upperBodyHeight + segmentedHeaderHeight)
                if let upperBody = segmentedHeaderContent.cropping(to: CGRect(
                       x: 0, y: 0,
                       width: width, height: upperBodyHeight)),
                   let lower = segmentedHeaderContent.cropping(to: CGRect(
                       x: 0, y: 2000,
                       width: width, height: lowerBodyHeight)),
                   let separator = segmented.segmentSeparator() {
                    upper.draw(upperBody, in: CGRect(
                        x: 0, y: 0,
                        width: width, height: upperBodyHeight))
                    upper.draw(segmentedHeaderBand, in: CGRect(
                        x: 0, y: upperBodyHeight,
                        width: width, height: segmentedHeaderHeight))
                    if let upperImage = upper.makeImage(),
                       let expected = expectedSegmentedImage(
                           upper: upperImage,
                           separator: separator,
                           lower: lower),
                       let actual = segmented.compose() {
                        let expectedHeight = upperBodyHeight
                            + segmentedHeaderHeight
                            + segmented.separatorRows + lowerBodyHeight
                        check("stitch-segment-header-only-on-first-segment",
                              segmented.segmentCount == 2
                                && segmented.currentSegment.headerRows
                                    == segmentedHeaderHeight
                                && imagesRoughlyEqual(expected, actual),
                              "segments \(segmented.segmentCount), header "
                                + "\(segmented.currentSegment.headerRows)")
                        check("stitch-segment-header-height",
                              segmented.totalHeight == expectedHeight
                                && actual.height == expectedHeight,
                              "total \(segmented.totalHeight), image \(actual.height), "
                                + "want \(expectedHeight)")
                    } else {
                        check("stitch-segment-header-compose", false)
                    }
                } else {
                    check("stitch-segment-header-crops", false)
                }
            } else {
                check("stitch-segment-header-frame", false)
            }

            // Local stability does not mean duplicate chrome. If the first
            // segment had no header, a stable header introduced later is page
            // content and must be retained in full.
            if let first = segmentedHeaderContent.cropping(to: CGRect(
                   x: 0, y: 0, width: width, height: viewport)),
               let second = segmentedHeaderContent.cropping(to: CGRect(
                   x: 0, y: 200, width: width, height: viewport)) {
                let segmented = SegmentedVerticalStitcher(first: first)
                _ = segmented.append(second)
                for position in segmentedHeaderPositions.dropFirst(2) {
                    if let frame = segmentedHeaderFrame(
                        offset: position, band: segmentedHeaderBand) {
                        _ = segmented.append(frame)
                    }
                }
                let upperHeight = viewport + 200
                let lowerBodyHeight = segmentedHeaderBodyHeight + 170
                let lower = ctx(
                    width, lowerBodyHeight + segmentedHeaderHeight)
                if let upper = segmentedHeaderContent.cropping(to: CGRect(
                       x: 0, y: 0, width: width, height: upperHeight)),
                   let body = segmentedHeaderContent.cropping(to: CGRect(
                       x: 0, y: 2000,
                       width: width, height: lowerBodyHeight)),
                   let separator = segmented.segmentSeparator() {
                    lower.draw(body, in: CGRect(
                        x: 0, y: 0,
                        width: width, height: lowerBodyHeight))
                    lower.draw(segmentedHeaderBand, in: CGRect(
                        x: 0, y: lowerBodyHeight,
                        width: width, height: segmentedHeaderHeight))
                    if let lowerImage = lower.makeImage(),
                       let expected = expectedSegmentedImage(
                           upper: upper,
                           separator: separator,
                           lower: lowerImage),
                       let actual = segmented.compose() {
                        check("stitch-segment-later-new-header-retained",
                              segmented.segmentCount == 2
                                && imagesRoughlyEqual(expected, actual),
                              "later header was removed")
                    } else {
                        check("stitch-segment-later-new-header-compose", false)
                    }
                } else {
                    check("stitch-segment-later-new-header-crops", false)
                }
            } else {
                check("stitch-segment-later-new-header-frames", false)
            }

            // Two locally fixed headers can name different sections. Keep the
            // later one unless its raw raster and height match the canonical
            // header retained from segment one.
            let differentHeaderBand = makeStripePattern(
                width: width, height: segmentedHeaderHeight,
                seed: 0xD1FF_AEAD)
            if let first = segmentedHeaderFrame(
                   offset: 0, band: segmentedHeaderBand),
               let second = segmentedHeaderFrame(
                   offset: 200, band: segmentedHeaderBand) {
                let segmented = SegmentedVerticalStitcher(first: first)
                _ = segmented.append(second)
                for position in segmentedHeaderPositions.dropFirst(2) {
                    if let frame = segmentedHeaderFrame(
                        offset: position, band: differentHeaderBand) {
                        _ = segmented.append(frame)
                    }
                }
                let upperBodyHeight = segmentedHeaderBodyHeight + 200
                let lowerBodyHeight = segmentedHeaderBodyHeight + 170
                let upper = ctx(
                    width, upperBodyHeight + segmentedHeaderHeight)
                let lower = ctx(
                    width, lowerBodyHeight + segmentedHeaderHeight)
                if let upperBody = segmentedHeaderContent.cropping(to: CGRect(
                       x: 0, y: 0,
                       width: width, height: upperBodyHeight)),
                   let lowerBody = segmentedHeaderContent.cropping(to: CGRect(
                       x: 0, y: 2000,
                       width: width, height: lowerBodyHeight)),
                   let separator = segmented.segmentSeparator() {
                    upper.draw(upperBody, in: CGRect(
                        x: 0, y: 0,
                        width: width, height: upperBodyHeight))
                    upper.draw(segmentedHeaderBand, in: CGRect(
                        x: 0, y: upperBodyHeight,
                        width: width, height: segmentedHeaderHeight))
                    lower.draw(lowerBody, in: CGRect(
                        x: 0, y: 0,
                        width: width, height: lowerBodyHeight))
                    lower.draw(differentHeaderBand, in: CGRect(
                        x: 0, y: lowerBodyHeight,
                        width: width, height: segmentedHeaderHeight))
                    if let upperImage = upper.makeImage(),
                       let lowerImage = lower.makeImage(),
                       let expected = expectedSegmentedImage(
                           upper: upperImage,
                           separator: separator,
                           lower: lowerImage),
                       let actual = segmented.compose() {
                        check("stitch-segment-different-header-retained",
                              segmented.segmentCount == 2
                                && imagesRoughlyEqual(expected, actual),
                              "different later header was removed")
                    } else {
                        check("stitch-segment-different-header-compose", false)
                    }
                } else {
                    check("stitch-segment-different-header-crops", false)
                }
            } else {
                check("stitch-segment-different-header-frames", false)
            }

            // De-duplication is optional, so its identity proof is byte-exact
            // over the full width. A tiny meaningful glyph/badge change in the
            // middle or at the edge must fail closed and retain the new header.
            let tinyCenterContext = ctx(width, segmentedHeaderHeight)
            tinyCenterContext.draw(segmentedHeaderBand, in: CGRect(
                x: 0, y: 0,
                width: width, height: segmentedHeaderHeight))
            tinyCenterContext.setFillColor(CGColor(
                srgbRed: 1, green: 0, blue: 1, alpha: 1))
            tinyCenterContext.fill(CGRect(
                x: width / 2, y: segmentedHeaderHeight / 2,
                width: 2, height: 2))
            let tinyEdgeContext = ctx(width, segmentedHeaderHeight)
            tinyEdgeContext.draw(segmentedHeaderBand, in: CGRect(
                x: 0, y: 0,
                width: width, height: segmentedHeaderHeight))
            tinyEdgeContext.setFillColor(CGColor(
                srgbRed: 1, green: 0, blue: 1, alpha: 1))
            tinyEdgeContext.fill(CGRect(
                x: 1, y: segmentedHeaderHeight / 2,
                width: 2, height: 2))
            if let tinyCenterBand = tinyCenterContext.makeImage(),
               let tinyEdgeBand = tinyEdgeContext.makeImage(),
               let canonicalFirst = segmentedHeaderFrame(
                   offset: 0, band: segmentedHeaderBand),
               let canonicalNext = segmentedHeaderFrame(
                   offset: 41, band: segmentedHeaderBand),
               let centerFirst = segmentedHeaderFrame(
                   offset: 2000, band: tinyCenterBand),
               let centerNext = segmentedHeaderFrame(
                   offset: 2041, band: tinyCenterBand),
               let edgeFirst = segmentedHeaderFrame(
                   offset: 2000, band: tinyEdgeBand),
               let edgeNext = segmentedHeaderFrame(
                   offset: 2041, band: tinyEdgeBand) {
                let canonical = VerticalStitcher(first: canonicalFirst)
                let center = VerticalStitcher(first: centerFirst)
                let edge = VerticalStitcher(first: edgeFirst)
                _ = canonical.append(canonicalNext)
                _ = center.append(centerNext)
                _ = edge.append(edgeNext)
                if let reference = canonical.topRowsImage(
                    rows: canonical.headerRows) {
                    check("stitch-segment-tiny-center-header-change-retained",
                          canonical.headerRows == segmentedHeaderHeight
                            && center.headerRows == segmentedHeaderHeight
                            && !center.topRowsMatch(
                                reference, rows: center.headerRows))
                    check("stitch-segment-tiny-edge-header-change-retained",
                          edge.headerRows == segmentedHeaderHeight
                            && !edge.topRowsMatch(
                                reference, rows: edge.headerRows))
                } else {
                    check("stitch-segment-tiny-header-reference", false)
                }
            } else {
                check("stitch-segment-tiny-header-frames", false)
            }

            // A sticky composer belongs only at the bottom of the final page,
            // not before every marked segment boundary.
            let footerViewport = 500, footerHeight = 60
            let footerBodyHeight = footerViewport - footerHeight
            let footerContent = makeStripePattern(
                width: width, height: 3000, seed: 0x5E67_F007)
            let footerBand = makeStripePattern(
                width: width, height: footerHeight, seed: 0xBAA0_F007)
            func segmentedFooterFrame(offset: Int) -> CGImage? {
                guard let body = footerContent.cropping(to: CGRect(
                    x: 0, y: offset,
                    width: width, height: footerBodyHeight)) else { return nil }
                let c = ctx(width, footerViewport)
                c.draw(footerBand, in: CGRect(
                    x: 0, y: 0, width: width, height: footerHeight))
                c.draw(body, in: CGRect(
                    x: 0, y: footerHeight,
                    width: width, height: footerBodyHeight))
                return c.makeImage()
            }
            let footerPositions = [0, 200, 2000, 2040, 2080, 2120, 2160]
            if let first = segmentedFooterFrame(offset: footerPositions[0]) {
                let segmented = SegmentedVerticalStitcher(first: first)
                for position in footerPositions.dropFirst() {
                    if let frame = segmentedFooterFrame(offset: position) {
                        _ = segmented.append(frame)
                    }
                }
                let upperBodyHeight = footerBodyHeight + 200
                let lowerBodyHeight = footerBodyHeight + 160
                let lower = ctx(width, lowerBodyHeight + footerHeight)
                if let body = footerContent.cropping(to: CGRect(
                    x: 0, y: 2000,
                    width: width, height: lowerBodyHeight)) {
                    lower.draw(footerBand, in: CGRect(
                        x: 0, y: 0, width: width, height: footerHeight))
                    lower.draw(body, in: CGRect(
                        x: 0, y: footerHeight,
                        width: width, height: lowerBodyHeight))
                }
                if let upper = footerContent.cropping(to: CGRect(
                       x: 0, y: 0,
                       width: width, height: upperBodyHeight)),
                   let separator = segmented.segmentSeparator(),
                   let lowerImage = lower.makeImage(),
                   let expected = expectedSegmentedImage(
                       upper: upper, separator: separator, lower: lowerImage),
                   let actual = segmented.compose() {
                    check("stitch-segment-footer-only-on-final-segment",
                          segmented.segmentCount == 2
                            && imagesRoughlyEqual(expected, actual),
                          "segments \(segmented.segmentCount), footer duplicated")
                    check("stitch-segment-footer-height",
                          actual.height == upperBodyHeight
                            + segmented.separatorRows
                            + lowerBodyHeight + footerHeight,
                          "got \(actual.height)")
                } else {
                    check("stitch-segment-footer-compose", false)
                }
            } else {
                check("stitch-segment-footer-frame", false)
            }

            // The gap can happen immediately after the first frame, before
            // the old segment has an accepted transition from which to latch
            // its footer. The proven footer on the new segment may infer and
            // trim the matching bottom band from that one-frame segment, but
            // it must still appear exactly once at the final page bottom.
            let immediateFooterPositions = [0, 2000, 2040, 2080, 2120, 2160]
            if let first = segmentedFooterFrame(
                offset: immediateFooterPositions[0]) {
                let segmented = SegmentedVerticalStitcher(first: first)
                for position in immediateFooterPositions.dropFirst() {
                    if let frame = segmentedFooterFrame(offset: position) {
                        _ = segmented.append(frame)
                    }
                }
                let lowerBodyHeight = footerBodyHeight + 160
                let lower = ctx(width, lowerBodyHeight + footerHeight)
                if let upper = footerContent.cropping(to: CGRect(
                       x: 0, y: 0,
                       width: width, height: footerBodyHeight)),
                   let body = footerContent.cropping(to: CGRect(
                       x: 0, y: 2000,
                       width: width, height: lowerBodyHeight)),
                   let separator = segmented.segmentSeparator() {
                    lower.draw(footerBand, in: CGRect(
                        x: 0, y: 0, width: width, height: footerHeight))
                    lower.draw(body, in: CGRect(
                        x: 0, y: footerHeight,
                        width: width, height: lowerBodyHeight))
                    if let lowerImage = lower.makeImage(),
                       let expected = expectedSegmentedImage(
                           upper: upper,
                           separator: separator,
                           lower: lowerImage),
                       let actual = segmented.compose() {
                        check("stitch-segment-first-frame-footer-only-final",
                              segmented.segmentCount == 2
                                && imagesRoughlyEqual(expected, actual),
                              "segments \(segmented.segmentCount), footer duplicated")
                        check("stitch-segment-first-frame-footer-height",
                              actual.height == footerBodyHeight
                                + segmented.separatorRows
                                + lowerBodyHeight + footerHeight,
                              "got \(actual.height)")
                    } else {
                        check("stitch-segment-first-frame-footer-compose", false)
                    }
                } else {
                    check("stitch-segment-first-frame-footer-crops", false)
                }
            } else {
                check("stitch-segment-first-frame-footer-frame", false)
            }

            // Inference may delete rows, so local footer similarity is not
            // enough. A tiny edge badge/change in a footer-like one-frame page
            // tail must make the cross-segment proof fail closed and preserve
            // that entire first viewport.
            let changedFooterContext = ctx(width, footerHeight)
            changedFooterContext.draw(footerBand, in: CGRect(
                x: 0, y: 0, width: width, height: footerHeight))
            changedFooterContext.setFillColor(CGColor(
                srgbRed: 1, green: 0, blue: 1, alpha: 1))
            changedFooterContext.fill(CGRect(
                x: 1, y: footerHeight / 2, width: 2, height: 2))
            if let changedFooterBand = changedFooterContext.makeImage(),
               let firstBody = footerContent.cropping(to: CGRect(
                   x: 0, y: 0,
                   width: width, height: footerBodyHeight)) {
                let firstContext = ctx(width, footerViewport)
                firstContext.draw(changedFooterBand, in: CGRect(
                    x: 0, y: 0, width: width, height: footerHeight))
                firstContext.draw(firstBody, in: CGRect(
                    x: 0, y: footerHeight,
                    width: width, height: footerBodyHeight))
                if let first = firstContext.makeImage() {
                    let segmented = SegmentedVerticalStitcher(first: first)
                    for position in immediateFooterPositions.dropFirst() {
                        if let frame = segmentedFooterFrame(offset: position) {
                            _ = segmented.append(frame)
                        }
                    }
                    let lowerBodyHeight = footerBodyHeight + 160
                    let lower = ctx(width, lowerBodyHeight + footerHeight)
                    if let body = footerContent.cropping(to: CGRect(
                           x: 0, y: 2000,
                           width: width, height: lowerBodyHeight)),
                       let separator = segmented.segmentSeparator() {
                        lower.draw(footerBand, in: CGRect(
                            x: 0, y: 0,
                            width: width, height: footerHeight))
                        lower.draw(body, in: CGRect(
                            x: 0, y: footerHeight,
                            width: width, height: lowerBodyHeight))
                        if let lowerImage = lower.makeImage(),
                           let expected = expectedSegmentedImage(
                               upper: first,
                               separator: separator,
                               lower: lowerImage),
                           let actual = segmented.compose() {
                            check("stitch-segment-tiny-footer-change-retained",
                                  segmented.segmentCount == 2
                                    && imagesRoughlyEqual(expected, actual),
                                  "footer-like first-frame tail was removed")
                            check("stitch-segment-tiny-footer-change-height",
                                  actual.height == footerViewport
                                    + segmented.separatorRows
                                    + lowerBodyHeight + footerHeight,
                                  "got \(actual.height)")
                        } else {
                            check("stitch-segment-tiny-footer-change-compose", false)
                        }
                    } else {
                        check("stitch-segment-tiny-footer-change-crops", false)
                    }
                } else {
                    check("stitch-segment-tiny-footer-change-first", false)
                }
            } else {
                check("stitch-segment-tiny-footer-change-band", false)
            }

            // Footer inference is safe only for a segment that never accepted
            // an append. Here the old multi-frame segment has no footer, but
            // its LAST viewport happens to end in the exact band later used as
            // a sticky footer. Trimming that band from its FIRST viewport would
            // delete unrelated page rows, so the entire old segment must stay.
            if let lateFooterBand = footerContent.cropping(to: CGRect(
                x: 0, y: 640, width: width, height: footerHeight
            )) {
                func lateFooterFrame(offset: Int) -> CGImage? {
                    guard let body = footerContent.cropping(to: CGRect(
                        x: 0, y: offset,
                        width: width, height: footerBodyHeight)) else {
                        return nil
                    }
                    let c = ctx(width, footerViewport)
                    c.draw(lateFooterBand, in: CGRect(
                        x: 0, y: 0,
                        width: width, height: footerHeight))
                    c.draw(body, in: CGRect(
                        x: 0, y: footerHeight,
                        width: width, height: footerBodyHeight))
                    return c.makeImage()
                }
                if let first = footerContent.cropping(to: CGRect(
                       x: 0, y: 0, width: width, height: footerViewport)),
                   let second = footerContent.cropping(to: CGRect(
                       x: 0, y: 200, width: width, height: footerViewport)) {
                    let segmented = SegmentedVerticalStitcher(first: first)
                    _ = segmented.append(second)
                    for position in [2000, 2040, 2080, 2120, 2160] {
                        if let frame = lateFooterFrame(offset: position) {
                            _ = segmented.append(frame)
                        }
                    }
                    let upperHeight = footerViewport + 200
                    let lowerBodyHeight = footerBodyHeight + 160
                    let lower = ctx(width, lowerBodyHeight + footerHeight)
                    if let upper = footerContent.cropping(to: CGRect(
                           x: 0, y: 0,
                           width: width, height: upperHeight)),
                       let body = footerContent.cropping(to: CGRect(
                           x: 0, y: 2000,
                           width: width, height: lowerBodyHeight)),
                       let separator = segmented.segmentSeparator() {
                        lower.draw(lateFooterBand, in: CGRect(
                            x: 0, y: 0,
                            width: width, height: footerHeight))
                        lower.draw(body, in: CGRect(
                            x: 0, y: footerHeight,
                            width: width, height: lowerBodyHeight))
                        if let lowerImage = lower.makeImage(),
                           let expected = expectedSegmentedImage(
                               upper: upper,
                               separator: separator,
                               lower: lowerImage),
                           let actual = segmented.compose() {
                            check("stitch-segment-no-false-footer-inference",
                                  segmented.segmentCount == 2
                                    && imagesRoughlyEqual(expected, actual),
                                  "segments \(segmented.segmentCount), old rows trimmed")
                            check("stitch-segment-no-false-footer-height",
                                  actual.height == upperHeight
                                    + segmented.separatorRows
                                    + lowerBodyHeight + footerHeight,
                                  "got \(actual.height)")
                        } else {
                            check("stitch-segment-no-false-footer-compose", false)
                        }
                    } else {
                        check("stitch-segment-no-false-footer-crops", false)
                    }
                } else {
                    check("stitch-segment-no-false-footer-active-frames", false)
                }
            } else {
                check("stitch-segment-no-false-footer-band", false)
            }

            // Unrelated/ambiguous frames must never turn into a segment merely
            // because four rejects elapsed.
            let unrelatedFirst = makeSolidImage(
                width: width, height: viewport, color: NSColor.red.cgColor)
            let unrelated = SegmentedVerticalStitcher(first: unrelatedFirst)
            let colors: [NSColor] = [
                .blue, .green, .yellow, .purple, .orange, .brown,
            ]
            for color in colors {
                _ = unrelated.append(makeSolidImage(
                    width: width, height: viewport, color: color.cgColor))
            }
            check("stitch-unproven-segment-not-promoted",
                  unrelated.segmentCount == 1
                    && unrelated.compose()?.height == viewport,
                  "segments \(unrelated.segmentCount)")

            let periodic = makePeriodicPattern(
                width: width, height: 1300, period: 37)
            if let p0 = periodic.cropping(to: CGRect(
                x: 0, y: 0, width: width, height: viewport)) {
                let ambiguous = SegmentedVerticalStitcher(first: p0)
                for position in [100, 200, 300, 400, 500, 600] {
                    if let frame = periodic.cropping(to: CGRect(
                        x: 0, y: position, width: width, height: viewport)) {
                        _ = ambiguous.append(frame)
                    }
                }
                check("stitch-ambiguous-segment-not-promoted",
                      ambiguous.segmentCount == 1,
                      "segments \(ambiguous.segmentCount)")
            } else {
                check("stitch-ambiguous-segment-frame", false)
            }

            // A later match against the active strip cancels an uncommitted
            // candidate, and a geometry error does not advance the reject gate.
            if let active0 = document.cropping(to: CGRect(
                x: 0, y: 0, width: width, height: viewport)),
               let active100 = document.cropping(to: CGRect(
                x: 0, y: 100, width: width, height: viewport)) {
                let resumed = SegmentedVerticalStitcher(first: active0)
                for color in [NSColor.blue, .green, .yellow] {
                    _ = resumed.append(makeSolidImage(
                        width: width, height: viewport, color: color.cgColor))
                }
                let outcome = resumed.append(active100)
                let resumedRows: Int
                if case let .appended(rows) = outcome { resumedRows = rows }
                else { resumedRows = 0 }
                _ = resumed.append(makeSolidImage(
                    width: width + 1, height: viewport,
                    color: NSColor.black.cgColor))
                check("stitch-active-resume-cancels-pending",
                      resumedRows == 100 && resumed.segmentCount == 1
                        && resumed.consecutiveRejects == 0,
                      "rows \(resumedRows), segments \(resumed.segmentCount), "
                        + "rejects \(resumed.consecutiveRejects)")
            } else {
                check("stitch-active-resume-frame", false)
            }
        }

        // 2i. capture backend fallback state ---------------------------------------
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
                    let continued = retained.append(f3).newRows
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

                // If the three sourceRect failures coincide with a flick, the
                // first full-crop frame may no longer overlap the old baseline.
                // Two mutually consistent fallback frames must start a marked
                // segment instead of leaving the backend handshake stuck.
                let switchedContent = makeStripePattern(
                    width: 200, height: 1600, seed: 0xFA11_5E67)
                if let a0 = switchedContent.cropping(to: CGRect(
                       x: 0, y: 0, width: 200, height: 400)),
                   let a100 = switchedContent.cropping(to: CGRect(
                       x: 0, y: 100, width: 200, height: 400)),
                   let b720 = switchedContent.cropping(to: CGRect(
                       x: 0, y: 720, width: 200, height: 400)),
                   let b760 = switchedContent.cropping(to: CGRect(
                       x: 0, y: 760, width: 200, height: 400)),
                   let b800 = switchedContent.cropping(to: CGRect(
                       x: 0, y: 800, width: 200, height: 400)),
                   let b840 = switchedContent.cropping(to: CGRect(
                       x: 0, y: 840, width: 200, height: 400)) {
                    let segmented = SegmentedVerticalStitcher(first: a0)
                    _ = segmented.append(a100)
                    // Leave a proven-but-uncommitted sourceRect candidate in
                    // place. Switching backends must discard it; otherwise a
                    // single fallback frame could complete a mixed-backend
                    // segment and be promoted without fallback-only proof.
                    let oldPendingFirst = segmented.append(b720)
                    let oldPendingSecond = segmented.append(b760)
                    let oldPendingStayedUncommitted: Bool
                    if case .rejected = oldPendingFirst,
                       case .rejected = oldPendingSecond {
                        oldPendingStayedUncommitted = segmented.segmentCount == 1
                    } else {
                        oldPendingStayedUncommitted = false
                    }
                    segmented.prepareForBackendTransition()
                    check("scroll-fallback-lost-overlap-detected",
                          !ScrollingCapture.validateBackendTransition(
                            stitcher: segmented.currentSegment, frame: b800))
                    let firstFallback = segmented
                        .appendBackendTransitionFrame(b800)
                    let secondFallback = segmented
                        .appendBackendTransitionFrame(b840)
                    let firstWasPending: Bool
                    if case .rejected = firstFallback { firstWasPending = true }
                    else { firstWasPending = false }
                    let secondStarted: Bool
                    if case .startedSegment = secondFallback {
                        secondStarted = true
                    } else {
                        secondStarted = false
                    }
                    let expectedHeight = 500 + segmented.separatorRows + 440
                    check("scroll-fallback-reanchors-proven-segment",
                          oldPendingStayedUncommitted
                            && firstWasPending && secondStarted
                            && segmented.segmentCount == 2
                            && segmented.totalHeight == expectedHeight,
                          "segments \(segmented.segmentCount), height "
                            + "\(segmented.totalHeight), want \(expectedHeight)")
                    check("scroll-fallback-reanchor-compose",
                          segmented.compose()?.height == expectedHeight)
                } else {
                    check("scroll-fallback-reanchor-frames", false)
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
