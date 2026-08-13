import AppKit
import Carbon.HIToolbox

/// Scrolling screenshot, Lark-style: the user scrolls the content themselves
/// while Snippr watches the selected area and stitches each new frame
/// automatically. No synthetic scroll events — no Accessibility permission —
/// and Snippr's own overlay windows are excluded from the capture.
@MainActor
final class ScrollingCapture {
    static var active: ScrollingCapture?

    static let escHotkeyID: UInt32 = 999

    private let onFinish: @MainActor (CapturedImage?) -> Void
    nonisolated(unsafe) private var finished = false
    private var borderWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var progressLabel: NSTextField?
    var previewView: ScrollPreviewView?
    private var escLocalMonitor: Any?
    private var escHotkeyRef: EventHotKeyRef?
    private var escRegistered = false

    /// A single capture backend for a session. Keeping the fallback state
    /// explicit also prevents frames from two backends (which can differ by a
    /// pixel on scaled displays) being fed into the same stitcher.
    enum CaptureBackend {
        case sourceRect
        case fullDisplayCrop

        mutating func switchToFallback(afterConsecutiveFailures failures: Int) -> Bool {
            guard self == .sourceRect, failures >= 3 else { return false }
            self = .fullDisplayCrop
            return true
        }
    }

    /// A backend transition may retain accumulated content only when its first
    /// frame has the same geometry and confidently overlaps the current
    /// stitcher baseline. A wrong-region/success frame is never appended.
    nonisolated static func validateBackendTransition(
        stitcher: VerticalStitcher?, frame: CGImage
    ) -> Bool {
        guard let stitcher else { return true }
        return stitcher.canAccept(frame)
    }

    /// "✓ / Esc để xong" khi Esc đăng ký được, nếu không thì chỉ còn nút ✓.
    private var stopHint: String { escRegistered ? "✓ / Esc để xong" : "bấm ✓ để xong" }

    init(onFinish: @escaping @MainActor (CapturedImage?) -> Void) {
        self.onFinish = onFinish
    }

    static func begin(onFinish: @escaping @MainActor (CapturedImage?) -> Void) {
        guard active == nil else { return }
        SelectionOverlay.begin(mode: .area) { result in
            guard case let .area(screen, _, rect) = result else {
                onFinish(nil)
                return
            }
            // Too-short selections can never stitch (the matcher needs enough
            // rows for a template) — refuse up front, mirroring Windows.
            guard rect.width >= 40, rect.height >= 60 else {
                ToastHUD.show("Vùng quá nhỏ cho chụp cuộn — chọn vùng cao hơn 60 pt",
                              symbol: "rectangle.dashed")
                onFinish(nil)
                return
            }
            let session = ScrollingCapture(onFinish: onFinish)
            active = session
            Task { @MainActor in
                await session.run(screen: screen, rect: rect)
            }
        }
    }

    func run(screen: NSScreen, rect: CGRect) async {
        showChrome(screen: screen, rect: rect)
        installStop()
        defer {
            removeStop()
            hideChrome()
            ScrollingCapture.active = nil
        }

        // our chrome windows just appeared — refresh the window list once so
        // they are excluded from every captured frame, then reuse it all session
        CaptureEngine.shared.invalidateContentCache()

        let scale = screen.backingScaleFactor
        guard let captureRegion = CanonicalCaptureRegion(
            screenSize: screen.frame.size, viewRect: rect, scale: scale)
        else {
            onFinish(nil)
            return
        }
        // The setting is a page-length cap in points, so both platforms cap the
        // same logical page length regardless of pixel density.
        let maxHeightPx = CGFloat(Settings.shared.scrollMaxHeight) * scale
        var stitcher: VerticalStitcher?
        var lastHash = 0
        var captureFailures = 0
        var captureBackend = CaptureBackend.sourceRect

        // Validate an ACTUAL sourceRect screenshot using metadata attached to
        // that same compositor frame. This catches the macOS/scaled-display
        // failure mode where ScreenCaptureKit succeeds but returns another
        // region, without comparing against a later full-screen frame whose
        // animated/scrolling pixels may legitimately differ.
        var firstFrame: CapturedImage?
        if let verified = try? await CaptureEngine.shared.captureVerifiedRect(
               screen: screen, region: captureRegion,
               excludingOwnWindows: true, contentMaxAge: 300) {
            firstFrame = verified
        } else {
            captureBackend = .fullDisplayCrop
            NSLog("Snippr: sourceRect same-frame region validation failed — using full-display crop")
        }

        var backendNeedsHandshake = false

        while !finished {
            let tickStarted = Date()
            let frame: CapturedImage?
            if let initial = firstFrame {
                frame = initial
                firstFrame = nil
            } else if captureBackend == .sourceRect {
                frame = try? await captureArea(screen: screen, region: captureRegion)
            } else {
                frame = (try? await CaptureEngine.shared.captureDisplay(
                    screen: screen, excludingOwnWindows: true, contentMaxAge: 300))?
                    .cropping(to: captureRegion)
            }
            guard let frame else {
                // transient SCK error must not silently end the session
                captureFailures += 1
                if captureBackend.switchToFallback(afterConsecutiveFailures: captureFailures) {
                    // A few macOS/display combinations reject sourceRect even
                    // though full-display capture works. Switch only on an
                    // actual capture error. The old pixel-by-pixel "probe"
                    // compared two captures taken at different times; moving
                    // pages and video routinely looked like a coordinate
                    // mismatch and forced every tick onto the much slower
                    // full-display path.
                    captureFailures = 0
                    backendNeedsHandshake = stitcher != nil
                    updateProgress("Đang dùng chế độ tương thích — cuộn tiếp, xong \(stopHint)")
                    NSLog("Snippr: sourceRect capture failed repeatedly — switching to full-display crop")
                } else if captureFailures > 10 {
                    break
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            captureFailures = 0
            if backendNeedsHandshake {
                guard Self.validateBackendTransition(stitcher: stitcher, frame: frame.cgImage) else {
                    // Same pixel dimensions are not enough: scaled-display
                    // backends can rasterize a different region. Keep all
                    // accumulated content, but do not mix an unverified frame.
                    updateProgress("Đang đồng bộ chế độ tương thích — giữ nguyên trang đã ghép")
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    continue
                }
                backendNeedsHandshake = false
            }
            let hash = Self.quickHash(frame.cgImage)
            let changed = hash != lastHash
            if changed {
                lastHash = hash
                if let s = stitcher {
                    if s.append(frame.cgImage) > 0 {
                        appendPreview(s.lastSlice)
                        updateProgress("Đã ghép \(Int(CGFloat(s.totalHeight) / scale)) pt — cuộn tiếp, xong \(stopHint)")
                    } else {
                        updateProgress("Chưa khớp được — cuộn chậm lại một chút")
                    }
                    if CGFloat(s.totalHeight) >= maxHeightPx { break }
                } else {
                    stitcher = VerticalStitcher(first: frame.cgImage, scale: scale)
                    startPreview(with: frame.cgImage)
                    updateProgress("Cuộn từ từ — ảnh ghép hiện bên cạnh · \(stopHint)")
                }
            }

            // SCScreenshotManager itself can take tens of milliseconds. Adding
            // a fixed 180 ms afterwards made the effective macOS sampling rate
            // far lower than Windows' 180 ms timer; a normal trackpad gesture
            // could move beyond the overlap before the next frame and the
            // session could never recover. Target a total cadence instead,
            // polling faster while pixels are moving and backing off at rest.
            let targetInterval = changed ? 0.075 : 0.14
            let remaining = targetInterval - Date().timeIntervalSince(tickStarted)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        let result = stitcher?.compose().map { CapturedImage(cgImage: $0, scale: scale) }
        onFinish(result)
    }

    /// Captures ONLY the selected rect (SCStreamConfiguration.sourceRect), so a
    /// tick costs the rect's pixels instead of the whole display's. The window
    /// list is cached for the whole session (our chrome doesn't change).
    private func captureArea(
        screen: NSScreen, region: CanonicalCaptureRegion
    ) async throws -> CapturedImage? {
        try await CaptureEngine.shared.captureVerifiedRect(
            screen: screen, region: region,
            excludingOwnWindows: true, contentMaxAge: 300)
    }

    // MARK: live preview (the user watches the stitched page grow)

    private let previewPixelWidth = 400
    /// Rolling window: only the most recent content is kept, matching what the
    /// bottom-aligned panel can actually show. Keeps per-tick preview work O(1)
    /// instead of recompositing the whole page every frame.
    private let previewMaxHeight = 1400
    private var previewImage: CGImage?

    private func scaledForPreview(_ image: CGImage) -> CGImage? {
        let scale = CGFloat(previewPixelWidth) / CGFloat(image.width)
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(
            data: nil, width: previewPixelWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: previewPixelWidth, height: h))
        return ctx.makeImage()
    }

    private func startPreview(with frame: CGImage) {
        previewImage = scaledForPreview(frame)
        pushPreview()
    }

    private func appendPreview(_ slice: CGImage?) {
        guard let slice, let scaled = scaledForPreview(slice) else { return }
        let prevH = previewImage?.height ?? 0
        let newH = min(previewMaxHeight, prevH + scaled.height)
        guard let ctx = CGContext(
            data: nil, width: previewPixelWidth, height: newH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // newest slice at the bottom; older content above, clipped at the top
        ctx.draw(scaled, in: CGRect(x: 0, y: 0, width: previewPixelWidth, height: scaled.height))
        if let prev = previewImage {
            ctx.draw(prev, in: CGRect(
                x: 0, y: CGFloat(scaled.height),
                width: CGFloat(previewPixelWidth), height: CGFloat(prev.height)
            ))
        }
        previewImage = ctx.makeImage()
        pushPreview()
    }

    private func pushPreview() {
        previewView?.image = previewImage
        previewView?.needsDisplay = true
    }

    /// Cheap change detector: downsample the frame to a fixed tiny buffer and
    /// hash those bytes. Unlike hashing `dataProvider.data`, this never
    /// materializes (or strides over) the full-size frame buffer.
    /// Sampled mean absolute channel difference between two same-sized images.
    static func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        func bytes(_ img: CGImage) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
            guard let ctx = CGContext(
                data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                bytesPerRow: img.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return buf
        }
        guard let ba = bytes(a), let bb = bytes(b) else { return 255 }
        var diff = 0
        var samples = 0
        var i = 0
        while i < ba.count {
            diff += abs(Int(ba[i]) - Int(bb[i]))
            samples += 1
            i += 397 * 4
        }
        return Double(diff) / Double(max(1, samples))
    }

    /// The buffer keeps (almost) full VERTICAL resolution and only compresses
    /// horizontally: a 64x64 thumbnail averaged text rows away — sparse gray
    /// text on white has near-constant density per block, so the hash barely
    /// changed while a real page scrolled and every frame was dropped as
    /// "no change" (the v1.2.0 "nothing ever stitches" bug).
    static func quickHash(_ image: CGImage) -> Int {
        let w = 64
        let h = min(1024, max(64, image.height / 2))
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hasher = Hasher()
        buf.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    // MARK: stop signals (Esc works globally via Carbon — no Accessibility needed)

    private func installStop() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4553) /* 'SNES' */, id: Self.escHotkeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape), 0, hotKeyID, GetApplicationEventTarget(), 0, &escHotkeyRef)
        escRegistered = status == noErr && escHotkeyRef != nil
        if !escRegistered {
            NSLog("Snippr: could not register global Esc for scrolling capture (status \(status))")
        }
        HotkeyManager.shared.auxHandler = { [weak self] id in
            if id == Self.escHotkeyID { self?.finished = true }
        }
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.finished = true
                return nil
            }
            return event
        }
    }

    private func removeStop() {
        if let ref = escHotkeyRef {
            UnregisterEventHotKey(ref)
            escHotkeyRef = nil
        }
        escRegistered = false
        HotkeyManager.shared.auxHandler = nil
        if let m = escLocalMonitor {
            NSEvent.removeMonitor(m)
            escLocalMonitor = nil
        }
    }

    @objc private func finishTapped() {
        finished = true
    }

    // test hooks
    func finishForTesting() { finished = true }
    var previewPanelForTesting: NSPanel? { controlPanel }

    // MARK: chrome (border + control bar — both excluded from capture)

    private func showChrome(screen: NSScreen, rect: CGRect) {
        let border = NSWindow(
            contentRect: CGRect(
                x: rect.minX + screen.frame.minX - 3,
                y: rect.minY + screen.frame.minY - 3,
                width: rect.width + 6, height: rect.height + 6
            ),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        border.level = .screenSaver
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        borderView.layer?.borderWidth = 3
        borderView.layer?.cornerRadius = 4
        border.contentView = borderView
        border.orderFrontRegardless()
        borderWindow = border

        // live preview panel beside the area: header (status + ✓) on top,
        // the growing stitched page below — "vừa chụp vừa xem"
        let panelWidth: CGFloat = 220
        let headerHeight: CGFloat = 64
        let panelHeight: CGFloat = min(screen.visibleFrame.height * 0.72, 620)

        let rectGlobal = CGRect(
            x: rect.minX + screen.frame.minX, y: rect.minY + screen.frame.minY,
            width: rect.width, height: rect.height
        )
        var panelX = rectGlobal.maxX + 14
        if panelX + panelWidth > screen.visibleFrame.maxX - 8 {
            panelX = rectGlobal.minX - panelWidth - 14
        }
        panelX = max(panelX, screen.visibleFrame.minX + 8)
        var panelY = rectGlobal.maxY - panelHeight
        panelY = min(max(panelY, screen.visibleFrame.minY + 8),
                     screen.visibleFrame.maxY - panelHeight - 8)

        let panel = NSPanel(
            contentRect: CGRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 12

        let label = NSTextField(wrappingLabelWithString: "Cuộn trang từ từ — ảnh ghép hiện tại đây")
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        progressLabel = label

        let done = NSButton(title: "✓ Xong", target: self, action: #selector(finishTapped))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.font = .systemFont(ofSize: 12, weight: .semibold)

        let header = NSStackView(views: [label, done])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 12)

        let preview = ScrollPreviewView()
        previewView = preview

        let column = NSStackView(views: [header, preview])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            preview.widthAnchor.constraint(equalTo: column.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),
        ])
        panel.contentView = container
        panel.orderFrontRegardless()
        controlPanel = panel
    }

    private func updateProgress(_ text: String) {
        progressLabel?.stringValue = text
    }

    private func hideChrome() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
        controlPanel?.orderOut(nil)
        controlPanel = nil
    }
}

/// Shows the stitched page scaled to fit the panel width, pinned to the
/// bottom so the newest content is always what the user sees.
final class ScrollPreviewView: NSView {
    var image: CGImage?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 12
        let area = bounds.insetBy(dx: inset, dy: 0)
        guard let image else {
            // explicit light gray — dynamic label colors can resolve to black
            // here and look broken on the dark panel
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1),
            ]
            ("Chờ khung hình đầu tiên…" as NSString).draw(
                at: NSPoint(x: inset, y: bounds.midY), withAttributes: attrs)
            return
        }
        let scale = area.width / CGFloat(image.width)
        let drawH = CGFloat(image.height) * scale
        ctx.saveGState()
        ctx.clip(to: area)
        // bottom-aligned: image bottom (= newest slice) sits at the view bottom
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: area.minX, y: area.minY, width: area.width, height: drawH))
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.stroke(CGRect(x: area.minX, y: area.minY,
                          width: area.width, height: min(drawH, area.height)), width: 1)
    }
}

// MARK: - Stitcher

/// Stitches equal-width frames vertically by locating the previous frame's
/// bottom strip inside each new frame. Frames that can't be matched reliably
/// are skipped instead of guessed, so output never contains corrupt seams.
///
/// Memory: every stored slice is materialized into its own tightly-sized
/// buffer. (CGImage.cropping shares the parent's backing store — before this,
/// each accepted slice kept that tick's ENTIRE captured frame alive, which on
/// long sessions added up to gigabytes.)
final class VerticalStitcher {
    private(set) var slices: [CGImage] = []
    private var lastFrame: CGImage
    private var lastSig: RowSig?
    /// Signatures of the session's FIRST frame — the reference a claimed
    /// sticky footer is validated against on every later append.
    private var firstSig: RowSig?
    let width: Int
    /// Backing scale of the frames (2 on retina). Pixel-unit thresholds are
    /// multiplied by this so both platforms compare identical content-space
    /// quantities (Windows runs at 1).
    let scale: CGFloat
    private(set) var totalHeight: Int
    /// Sticky rows detected at the bottom of the viewport (e.g. a fixed
    /// footer/chat bar). LATCHED on the first accepted append and constant for
    /// the whole session: per-pair estimates flap when a cursor blinks inside
    /// the bar, and slicing each frame with a different footer value baked bar
    /// fragments into the page mid-seam. compose() re-attaches the footer once
    /// at the very end.
    private(set) var footerRows = 0
    private var footerLatched = false
    /// Raster output can only append whole rows, while a 1x trackpad may move
    /// content by half a backing pixel. Carry the rounding remainder forward
    /// so 23.5 + 23.5 appends 24 + 23 rows, not 24 + 24.
    private var fractionalRowResidual = 0.0

    struct RowSig {
        let bands: [Double]   // h * 4 mean-gray band values
        let energy: [Double]  // h horizontal-gradient energies
    }

    init(first: CGImage, scale: CGFloat = 1) {
        let owned = first.materialized() ?? first
        slices = [owned]
        lastFrame = owned
        lastSig = nil
        width = owned.width
        totalHeight = owned.height
        self.scale = max(1, scale)
    }

    /// The most recently appended slice — used for the live preview.
    private(set) var lastSlice: CGImage?

    /// Non-mutating transition probe used when capture falls back from
    /// sourceRect to a full-display crop. Equal dimensions alone are not proof
    /// of equal coordinates; require the same unique content overlap that a
    /// real append would require before mixing backend frames.
    func canAccept(_ frame: CGImage) -> Bool {
        guard frame.width == width, frame.height == lastFrame.height,
              let nextSig = Self.rowSignatures(frame),
              let prevSig = lastSig ?? Self.rowSignatures(lastFrame),
              let match = Self.findOverlap(
                prev: prevSig, next: nextSig, height: frame.height, scale: scale,
                lockedFooter: footerLatched ? footerRows : nil)
        else { return false }
        let footer = footerLatched ? footerRows : match.footerRows
        return footerIsStable(footer, next: nextSig)
    }

    /// Append new content from `frame`. Returns the number of new rows
    /// (0 when nothing new or the frame couldn't be matched).
    @discardableResult
    func append(_ frame: CGImage) -> Int {
        guard frame.width == width, frame.height == lastFrame.height else { return 0 }
        guard let nextSig = Self.rowSignatures(frame) else { return 0 }
        let prevSig: RowSig
        if let cached = lastSig {
            prevSig = cached
        } else {
            guard let computed = Self.rowSignatures(lastFrame) else { return 0 }
            prevSig = computed
            lastSig = computed // rejected ticks must not recompute this
        }
        if firstSig == nil { firstSig = prevSig } // prev of the 1st append IS frame #1

        guard let match = Self.findOverlap(
            prev: prevSig, next: nextSig, height: frame.height, scale: scale,
            lockedFooter: footerLatched ? footerRows : nil
        ) else {
            return 0
        }
        let footer = footerLatched ? footerRows : match.footerRows

        // A true sticky footer is identical to the FIRST frame's bottom band
        // for the whole session. Pitch-aligned scrolling content that merely
        // matched the previous frame drifts away from it — reject the frame
        // instead of silently dropping/duplicating page rows.
        guard footerIsStable(footer, next: nextSig) else { return 0 }

        let contentHeight = frame.height - footer
        let accumulatedOffset = match.preciseOffset + fractionalRowResidual
        let rows = min(Int(accumulatedOffset.rounded()), contentHeight)
        guard rows > 0 else { return 0 }
        // new content sits just above the (possibly empty) footer band
        guard let slice = frame.cropping(to: CGRect(
            x: 0, y: contentHeight - rows, width: width, height: rows
        ))?.materialized() else { return 0 }
        slices.append(slice)
        lastSlice = slice
        totalHeight += rows
        fractionalRowResidual = accumulatedOffset - Double(rows)
        lastFrame = frame.materialized() ?? frame
        lastSig = nextSig
        footerRows = footer
        footerLatched = true
        return rows
    }

    private func footerIsStable(_ footer: Int, next: RowSig) -> Bool {
        guard footer > 0, let first = firstSig else { return true }
        var stable = 0
        for y in (lastFrame.height - footer)..<lastFrame.height {
            let b = y * 4
            let d = (abs(first.bands[b] - next.bands[b])
                + abs(first.bands[b + 1] - next.bands[b + 1])
                + abs(first.bands[b + 2] - next.bands[b + 2])
                + abs(first.bands[b + 3] - next.bands[b + 3])) / 4
            if d < 2.0 { stable += 1 } // tolerates a blinking cursor row
        }
        guard stable * 10 >= footer * 7 else {
            Perf.reject("footer drift \(stable)/\(footer) vs first frame")
            return false
        }
        return true
    }

    struct Match {
        let preciseOffset: Double
        let footerRows: Int
    }

    /// How many rows of new content `next` has relative to `previous`;
    /// nil when confidence is too low. Safeguards against ugly output:
    /// - 4-band row signatures (a plain per-row mean can't tell repetitive UI
    ///   rows apart, which duplicated whole blocks);
    /// - detail-weighted rows (misaligned text dominates the score; empty
    ///   background can't hide the error or drown the uniqueness signal);
    /// - static-bottom detection (a sticky footer inside the rect used to
    ///   corrupt every seam or stall matching entirely);
    /// - a two-pass uniqueness margin — if the second-best offset outside the
    ///   winner's plateau is nearly as good, the page is self-similar there
    ///   and guessing would corrupt the seam, so the frame is skipped.
    static func findOverlap(
        prev: RowSig, next: RowSig, height h: Int, scale: CGFloat,
        lockedFooter: Int? = nil
    ) -> Match? {
        let minHeight = Int(40 * scale)
        guard h > minHeight, prev.bands.count == h * 4, next.bands.count == h * 4 else { return nil }

        // Per-row difference at offset 0: identifies rows that did NOT move.
        var rowDiff = [Double](repeating: 0, count: h)
        var changedRows = 0
        let changeEps = 1.5
        for y in 0..<h {
            let base = y * 4
            let d = (abs(prev.bands[base] - next.bands[base])
                + abs(prev.bands[base + 1] - next.bands[base + 1])
                + abs(prev.bands[base + 2] - next.bands[base + 2])
                + abs(prev.bands[base + 3] - next.bands[base + 3])) / 4
            rowDiff[y] = d
            if d > changeEps { changedRows += 1 }
        }
        // essentially identical frames → no scroll happened
        guard changedRows > h / 20 else {
            Perf.reject("static changed=\(changedRows)/\(h)")
            return nil
        }

        // Trailing static run at the bottom = sticky footer candidate. Only
        // meaningful because other rows DID change (checked above). Once the
        // session latched a footer, that value is used verbatim so every
        // slice is cut with the same geometry.
        var footer: Int
        if let locked = lockedFooter {
            footer = min(locked, h / 3)
        } else {
            // Trailing static run, allowed to bridge ONE small dynamic band
            // (a blinking cursor / spinner inside the sticky bar would
            // otherwise truncate the detected footer on half the frame pairs).
            let staticEps = 0.8
            let maxGap = Int(8 * scale)
            let limit = h / 3
            footer = 0
            var i = 0
            var gapUsed = false
            while i < limit {
                if rowDiff[h - 1 - i] < staticEps {
                    i += 1
                    footer = i
                    continue
                }
                var gap = 0
                while i + gap < limit, gap < maxGap, rowDiff[h - 1 - i - gap] >= staticEps {
                    gap += 1
                }
                if !gapUsed, gap < maxGap, i + gap < limit, rowDiff[h - 1 - i - gap] < staticEps {
                    gapUsed = true
                    i += gap
                    continue
                }
                break
            }
            let minFooter = Int(6 * scale)
            if footer < minFooter { footer = 0 }
        }

        let hEff = h - footer
        guard hEff > minHeight else {
            Perf.reject("hEff \(hEff) too small (footer \(footer))")
            return nil
        }

        let k = max(Int(32 * scale), hEff / 4)
        guard hEff - k >= 1 else {
            Perf.reject("k \(k) >= hEff \(hEff)")
            return nil
        }

        // rows are weighted by their detail (horizontal gradient energy)
        var weights = [Double](repeating: 0, count: k)
        var weightSum = 0.0
        for i in 0..<k {
            let w = max(prev.energy[hEff - k + i], 0.5)
            weights[i] = w
            weightSum += w
        }
        guard weightSum > 0 else { return nil }

        // Pass 1: score every offset. (Storing the scores keeps pass 2 free of
        // the order-dependence the old single-pass second-best tracking had:
        // a chain of small improvements could silently swallow a real alias.)
        let count = hEff - k + 1
        var scores = [Double](repeating: 0, count: count)
        var bestOffset = -1
        var bestScore = Double.greatestFiniteMagnitude
        for s in 0..<count {
            let start = hEff - k - s
            var diff: Double = 0
            for i in 0..<k {
                let a = (hEff - k + i) * 4
                let b = (start + i) * 4
                let d = (abs(prev.bands[a] - next.bands[b])
                    + abs(prev.bands[a + 1] - next.bands[b + 1])
                    + abs(prev.bands[a + 2] - next.bands[b + 2])
                    + abs(prev.bands[a + 3] - next.bands[b + 3])) / 4
                diff += weights[i] * d
            }
            diff /= weightSum
            scores[s] = diff
            if diff < bestScore {
                bestScore = diff
                bestOffset = s
            }
        }

        // Pass 2: the runner-up must sit OUTSIDE the winner's plateau.
        let exclusion = max(6, Int(6 * scale))
        var secondScore = Double.greatestFiniteMagnitude
        for s in 0..<count where abs(s - bestOffset) > exclusion {
            if scores[s] < secondScore { secondScore = scores[s] }
        }

        // Fractional trackpad positions are a special refinement, not extra
        // global candidates. Let the integer matcher locate the only plausible
        // overlap first, then test half-row interpolation just around it. If
        // interpolation competed at every offset, smoothing could create a
        // tempting false minimum at offset zero on detailed pages.
        var subpixelScore = Double.greatestFiniteMagnitude
        var subpixelOffset = -1.0
        if bestOffset > 0 {
            let templateStart = hEff - k
            let nearby = max(1, bestOffset - 1)...min(count - 1, bestOffset + 1)
            // (previous-row delta, next-row delta, round result upward)
            let phases = [(-1, 0, false), (1, 0, true),
                          (0, -1, true), (0, 1, false)]
            for s in nearby {
                let start = hEff - k - s
                for (prevDelta, nextDelta, roundUp) in phases {
                    var diff = 0.0
                    var localWeight = 0.0
                    for i in 0..<k {
                        let py = templateStart + i
                        let ny = start + i
                        let py2 = py + prevDelta
                        let ny2 = ny + nextDelta
                        guard py2 >= 0, py2 < hEff, ny2 >= 0, ny2 < hEff else { continue }
                        let a = py * 4
                        let a2 = py2 * 4
                        let b = ny * 4
                        let b2 = ny2 * 4
                        var d = 0.0
                        for band in 0..<4 {
                            let p = (prev.bands[a + band] + prev.bands[a2 + band]) * 0.5
                            let n = (next.bands[b + band] + next.bands[b2 + band]) * 0.5
                            d += abs(p - n)
                        }
                        diff += weights[i] * d / 4
                        localWeight += weights[i]
                    }
                    guard localWeight > weightSum * 0.9 else { continue }
                    diff /= localWeight
                    if diff < subpixelScore {
                        subpixelScore = diff
                        // `roundUp` identifies s + 0.5; the mirrored phase is
                        // s - 0.5. Preserve it as a real-valued displacement —
                        // append() carries its rounding residual across frames.
                        subpixelOffset = Double(s) + (roundUp ? 0.5 : -0.5)
                    }
                }
            }
        }

        if Perf.enabled {
            FileHandle.standardError.write(
                "match off=\(bestOffset) best=\(String(format: "%.2f", bestScore)) sub=\(String(format: "%.1f", subpixelOffset)):\(String(format: "%.2f", subpixelScore)) second=\(String(format: "%.2f", secondScore)) footer=\(footer)\n"
                    .data(using: .utf8)!)
        }
        // The true overlap is a near-perfect match (~0.0) because both frames
        // rasterize the same content; line-pitch aliases score low-but-nonzero
        // (~0.4–2). So uniqueness is a RATIO test with a small epsilon, plus
        // an absolute-gap fallback for noisy pages (animations in overlap).
        guard bestOffset > 0 else {
            Perf.reject("gate off=\(bestOffset) best=\(String(format: "%.2f", bestScore))")
            return nil
        }
        // no offsets outside the winner's plateau = zero uniqueness evidence
        // (tiny effective heights after footer subtraction) — don't guess
        guard secondScore < Double.greatestFiniteMagnitude else {
            Perf.reject("vacuous second (count \(count))")
            return nil
        }
        let unique = secondScore > bestScore * 3 + 0.15
            || secondScore - bestScore > 2.5
        // On a 1x display a trackpad can stop at half a backing pixel. Core
        // Animation then re-rasterizes every text edge and raises the absolute
        // difference (3–6 instead of ~0), even though the correct offset remains
        // overwhelmingly better than every alternative. Accept that case only
        // with much stronger uniqueness evidence; this is deliberately not a
        // blanket threshold increase, so repetitive pages remain rejected.
        let fractionalButCertain = bestScore < 6.0
            && secondScore > bestScore * 4
            && secondScore - bestScore > 12
        let modeledSubpixel = subpixelOffset > 0
            && subpixelScore < 6.0
            && subpixelScore < bestScore * 0.75
            && secondScore > subpixelScore * 4
            && secondScore - subpixelScore > 12
        guard (bestScore < 2.0 || fractionalButCertain || modeledSubpixel), unique else {
            Perf.reject("not unique best=\(String(format: "%.2f", bestScore)) second=\(String(format: "%.2f", secondScore)) off=\(bestOffset)")
            return nil
        }
        return Match(
            preciseOffset: modeledSubpixel ? subpixelOffset : Double(bestOffset),
            footerRows: footer)
    }

    /// Per-row: mean gray of 4 horizontal bands + gradient energy. A narrow
    /// margin is deliberately ignored on both sides. macOS draws its overlay
    /// scroller on top of page pixels at the edge; the thumb moves and fades
    /// between captures even when the page overlap is exact. Sampling it made
    /// the right-most band alone push a correct match over the rejection gate.
    static func rowSignatures(_ image: CGImage) -> RowSig? {
        let w = image.width, h = image.height
        guard w >= 8, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let edgeInset = min(32, max(8, w / 25))
        let sampleStart = min(edgeInset, (w - 4) / 2)
        let sampleEnd = w - sampleStart
        let sampledWidth = max(4, sampleEnd - sampleStart)
        let bandWidth = max(1, sampledWidth / 4)
        let colStride = max(1, bandWidth / 24)
        var bands = [Double](repeating: 0, count: h * 4)
        var energy = [Double](repeating: 0, count: h)
        for y in 0..<h {
            let rowBase = y * w
            var grad = 0
            var gradCount = 0
            for band in 0..<4 {
                let x0 = sampleStart + band * bandWidth
                let x1 = band == 3 ? sampleEnd : sampleStart + (band + 1) * bandWidth
                var sum = 0
                var count = 0
                var x = x0
                var prevPx = -1
                while x < x1 {
                    let px = Int(buf[rowBase + x])
                    sum += px
                    count += 1
                    if prevPx >= 0 {
                        grad += abs(px - prevPx)
                        gradCount += 1
                    }
                    prevPx = px
                    x += colStride
                }
                bands[y * 4 + band] = Double(sum) / Double(max(1, count))
            }
            energy[y] = Double(grad) / Double(max(1, gradCount))
        }
        return RowSig(bands: bands, energy: energy)
    }

    func compose() -> CGImage? {
        guard !slices.isEmpty else { return nil }

        // A detected sticky footer was excluded from every appended slice, but
        // the FIRST frame still carries it at its bottom — which would land in
        // the middle of the page. Move it: trim it off the first slice and
        // re-attach the footer band (from the last frame) at the very end.
        var parts = slices
        if footerRows > 0, parts.count > 1,
           let first = parts.first, first.height > footerRows,
           lastFrame.height > footerRows {
            let trimmed = first.cropping(to: CGRect(
                x: 0, y: 0, width: width, height: first.height - footerRows
            ))?.materialized()
            let footer = lastFrame.cropping(to: CGRect(
                x: 0, y: lastFrame.height - footerRows, width: width, height: footerRows
            ))?.materialized()
            if let trimmed, let footer {
                parts[0] = trimmed
                parts.append(footer)
            }
        }

        let h = parts.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(
            data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var y = h
        for slice in parts {
            y -= slice.height
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: slice.width, height: slice.height))
        }
        return ctx.makeImage()
    }
}
