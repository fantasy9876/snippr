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
        var stitcher: SegmentedVerticalStitcher?
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
                    stitcher?.prepareForBackendTransition()
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
                if let segmented = stitcher,
                   !Self.validateBackendTransition(
                    stitcher: segmented.currentSegment, frame: frame.cgImage
                   ) {
                    // A backend switch can coincide with a fast flick. Waiting
                    // forever for an overlap against the old backend would
                    // recreate the session lock-out. Build a pending strip only
                    // from fallback frames; promote it after it proves one
                    // internal transition, with the same visible gap marker.
                    lastHash = Self.quickHash(frame.cgImage)
                    switch segmented.appendBackendTransitionFrame(frame.cgImage) {
                    case let .startedSegment(segmentImage):
                        if let separator = segmented.segmentSeparator() {
                            startPreview(with: separator)
                        }
                        appendPreview(segmentImage)
                        updateProgress(
                            "Đã đổi chế độ chụp và bắt đầu đoạn "
                            + "\(segmented.segmentCount); vạch sáng đánh dấu chỗ thiếu")
                        backendNeedsHandshake = false
                    case .appended, .rejected:
                        updateProgress(
                            "Đang đồng bộ chế độ tương thích — cuộn chậm để nối tiếp")
                    }
                    if backendNeedsHandshake {
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                    continue
                }
                stitcher?.discardPendingSegment()
                backendNeedsHandshake = false
            }
            let hash = Self.quickHash(frame.cgImage)
            let changed = hash != lastHash
            if changed {
                lastHash = hash
                if let s = stitcher {
                    switch s.append(frame.cgImage) {
                    case .appended:
                        appendPreview(s.lastSlice)
                        updateProgress(
                            "Đã ghép \(Int(CGFloat(s.totalHeight) / scale)) pt "
                            + "— cuộn tiếp, xong \(stopHint)")
                    case let .startedSegment(segmentImage):
                        if let separator = s.segmentSeparator() {
                            startPreview(with: separator)
                        }
                        appendPreview(segmentImage)
                        updateProgress(
                            "Mất một đoạn do cuộn quá nhanh — đang ghi đoạn "
                            + "\(s.segmentCount); vạch sáng đánh dấu chỗ thiếu")
                    case .rejected:
                        updateProgress("Chưa khớp được — cuộn chậm lại một chút")
                    }
                    if CGFloat(s.totalHeight) >= maxHeightPx { break }
                } else {
                    stitcher = SegmentedVerticalStitcher(
                        first: frame.cgImage, scale: scale)
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
        border.sharingType = .none
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
        panel.sharingType = .none
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

/// Owns a sequence of independently verified vertical strips. A long flick can
/// leave no shared pixels at all; after several changed-but-unmatchable frames,
/// keeping the old reference would dead-lock the rest of the session. Starting
/// a new segment restores progress without claiming an overlap that cannot be
/// proven. The final image contains a conspicuous striped separator at every
/// such boundary, so a discontinuity is never disguised as a valid seam.
final class SegmentedVerticalStitcher {
    enum AppendOutcome {
        case appended(Int)
        case rejected(consecutive: Int)
        case startedSegment(CGImage)
    }

    static let reanchorAfterRejects = 4

    private(set) var currentSegment: VerticalStitcher
    private var pendingSegment: VerticalStitcher?
    private var completedSegments: [CGImage] = []
    private var canonicalHeader: CGImage?
    private var canonicalHeaderRows = 0
    private var currentOmittedHeaderRows = 0
    private(set) var consecutiveRejects = 0
    private(set) var segmentCount = 1
    let width: Int
    let viewportHeight: Int
    let scale: CGFloat

    init(first: CGImage, scale: CGFloat = 1) {
        let initial = VerticalStitcher(first: first, scale: scale)
        currentSegment = initial
        width = first.width
        viewportHeight = first.height
        self.scale = max(1, scale)
    }

    var lastSlice: CGImage? { currentSegment.lastSlice }

    var totalHeight: Int {
        let completedHeight = completedSegments.reduce(0) { $0 + $1.height }
        let currentHeight = currentSegment.totalHeight
            - currentOmittedHeaderRows
        return completedHeight + currentHeight
            + max(0, segmentCount - 1) * separatorRows
    }

    @discardableResult
    func append(_ frame: CGImage) -> AppendOutcome {
        // A geometry change is a backend/configuration error, not evidence of
        // scrolling. Never let repeated wrong-sized frames trigger re-anchor.
        guard frame.width == width, frame.height == viewportHeight else {
            return .rejected(consecutive: consecutiveRejects)
        }

        let rows = currentSegment.append(frame)
        if rows > 0 {
            if currentOmittedHeaderRows > 0,
               currentSegment.headerRows != currentOmittedHeaderRows {
                currentOmittedHeaderRows = 0
            }
            consecutiveRejects = 0
            pendingSegment = nil
            return .appended(rows)
        }

        consecutiveRejects += 1
        if let pending = pendingSegment {
            if pending.append(frame) == 0 {
                // This candidate did not form a contiguous strip either.
                // Replace it instead of accumulating unrelated screenshots.
                pendingSegment = VerticalStitcher(first: frame, scale: scale)
            }
        } else {
            pendingSegment = VerticalStitcher(first: frame, scale: scale)
        }

        // Four failures alone are not enough evidence: a single animation or
        // unrelated frame must never enter the output. Promote only after the
        // pending segment has independently verified at least one transition.
        guard consecutiveRejects >= Self.reanchorAfterRejects,
              let outcome = promotePendingSegment() else {
            return .rejected(consecutive: consecutiveRejects)
        }
        return outcome
    }

    func canAccept(_ frame: CGImage) -> Bool {
        currentSegment.canAccept(frame)
    }

    /// Consumes frames from a newly selected capture backend when its first
    /// image cannot overlap the old backend baseline. Only frames from this
    /// method enter the pending strip, so no coordinate systems are mixed.
    @discardableResult
    func appendBackendTransitionFrame(_ frame: CGImage) -> AppendOutcome {
        guard frame.width == width, frame.height == viewportHeight else {
            return .rejected(consecutive: 0)
        }
        if let pending = pendingSegment {
            if pending.append(frame) == 0 {
                pendingSegment = VerticalStitcher(first: frame, scale: scale)
            }
        } else {
            pendingSegment = VerticalStitcher(first: frame, scale: scale)
        }
        return promotePendingSegment()
            ?? .rejected(consecutive: 0)
    }

    func discardPendingSegment() {
        pendingSegment = nil
        consecutiveRejects = 0
    }

    /// Pending evidence is backend-specific. Call exactly when capture changes
    /// coordinate/rasterization backend so sourceRect and full-crop frames can
    /// never form one pending segment.
    func prepareForBackendTransition() {
        discardPendingSegment()
    }

    private func promotePendingSegment() -> AppendOutcome? {
        guard let pending = pendingSegment,
              pending.totalHeight > viewportHeight else { return nil }
        if segmentCount == 1 {
            canonicalHeaderRows = currentSegment.headerRows
            canonicalHeader = currentSegment.topRowsImage(
                rows: canonicalHeaderRows)
        }
        let pendingOmittedHeaderRows = omittedHeaderRows(from: pending)
        guard let completed = currentSegment.compose(
                includeHeader: currentOmittedHeaderRows == 0,
                includeFooter: false,
                inferredFooterRows: currentSegment.slices.count == 1
                    && currentSegment.footerRows == 0
                    && pending.footerRows > 0
                    && currentSegment.bottomRowsMatch(
                        pending, rows: pending.footerRows)
                    ? pending.footerRows : 0),
              // Preview keeps the raw first viewport of the new segment. Header
              // de-duplication is a final-compose optimization and can be
              // revoked if later frames disprove that the chrome is stable.
              let pendingImage = pending.compose() else { return nil }
        completedSegments.append(completed)
        currentSegment = pending
        currentOmittedHeaderRows = pendingOmittedHeaderRows
        pendingSegment = nil
        consecutiveRejects = 0
        segmentCount += 1
        return .startedSegment(pendingImage)
    }

    /// A locally fixed top band can be a different section header or a banner
    /// introduced later in the page. Omit it only when it is the same raster
    /// chrome (and height) as the header retained in segment one. Ambiguity is
    /// fail-safe: keep the later band rather than delete unique page content.
    private func omittedHeaderRows(from segment: VerticalStitcher) -> Int {
        guard canonicalHeaderRows > 0,
              segment.headerRows == canonicalHeaderRows,
              let canonicalHeader else {
            return 0
        }
        return segment.topRowsMatch(
            canonicalHeader, rows: canonicalHeaderRows)
            ? canonicalHeaderRows : 0
    }

    var separatorRows: Int { max(12, Int(12 * scale)) }

    /// Visible, content-independent boundary used both in the live preview and
    /// final output. Alternating bands remain obvious on light and dark pages.
    func segmentSeparator() -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: separatorRows,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(
            srgbRed: 0.96, green: 0.58, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: separatorRows))
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        let dashWidth = max(8, Int(8 * scale))
        var x = 0
        while x < width {
            ctx.fill(CGRect(
                x: x, y: separatorRows / 3,
                width: min(dashWidth, width - x),
                height: max(2, separatorRows / 3)))
            x += dashWidth * 2
        }
        return ctx.makeImage()
    }

    func compose() -> CGImage? {
        guard let current = currentSegment.compose(
            includeHeader: currentOmittedHeaderRows == 0) else { return nil }
        let segments = completedSegments + [current]
        guard segments.count > 1 else { return current }
        guard let separator = segmentSeparator() else { return nil }
        let height = segments.reduce(0) { $0 + $1.height }
            + (segments.count - 1) * separator.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var y = height
        for (index, segment) in segments.enumerated() {
            y -= segment.height
            ctx.draw(segment, in: CGRect(
                x: 0, y: y, width: width, height: segment.height))
            if index + 1 < segments.count {
                y -= separator.height
                ctx.draw(separator, in: CGRect(
                    x: 0, y: y, width: width, height: separator.height))
            }
        }
        return ctx.makeImage()
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
    /// Fixed top chrome is kept on the first page segment only. Later segments
    /// can prove it from their first accepted transition, then omit that
    /// duplicate header when composing across a visible gap marker.
    private(set) var headerRows = 0
    private var headerLatched = false
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
        let nextHeaderRows: Int
        if !headerLatched {
            nextHeaderRows = stableHeaderPrefix(
                candidateRows: match.headerRows, next: nextSig)
        } else if headerRows > 0 {
            // Tighten the proven prefix against every accepted frame. The
            // matcher may bridge a blinking-control gap for alignment, but
            // composition trims only the continuously stable prefix; it must
            // never consume the first coincidentally-equal body row.
            nextHeaderRows = stableHeaderPrefix(
                candidateRows: headerRows, next: nextSig)
        } else {
            nextHeaderRows = headerRows
        }

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
        headerRows = nextHeaderRows
        headerLatched = true
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

    private func stableHeaderPrefix(
        candidateRows: Int, next: RowSig
    ) -> Int {
        guard candidateRows > 0, let first = firstSig else { return 0 }
        var stable = 0
        for y in 0..<candidateRows {
            let base = y * 4
            let difference = (
                abs(first.bands[base] - next.bands[base])
                + abs(first.bands[base + 1] - next.bands[base + 1])
                + abs(first.bands[base + 2] - next.bands[base + 2])
                + abs(first.bands[base + 3] - next.bands[base + 3])
            ) / 4
            guard difference < 0.8 else { break }
            stable += 1
        }
        return stable >= Int(6 * scale) ? stable : 0
    }

    /// Proves that two independently-built segments share the same bottom
    /// chrome. This is used only when a gap happened immediately after the
    /// first frame, before the old segment had a second frame from which to
    /// latch `footerRows`. The new segment must already have detected a stable
    /// footer; byte-exact full-raster agreement with the old segment prevents
    /// trimming an unrelated page tail merely because its row means look alike.
    func bottomRowsMatch(_ other: VerticalStitcher, rows: Int) -> Bool {
        guard width == other.width,
              lastFrame.height == other.lastFrame.height,
              rows > 0,
              rows <= lastFrame.height / 3,
              let ours = lastFrame.cropping(to: CGRect(
                x: 0, y: lastFrame.height - rows,
                width: width, height: rows)),
              let theirs = other.lastFrame.cropping(to: CGRect(
                x: 0, y: other.lastFrame.height - rows,
                width: width, height: rows)) else {
            return false
        }
        return Self.imagesMatchExactly(ours, theirs)
    }

    /// Strict cross-segment identity proof for de-duplicating a fixed header.
    /// Local stability is insufficient: a later section can introduce a new
    /// sticky title. Compare the original raw header rasters and fail closed on
    /// even modest content changes; retaining a duplicate near a marked gap is
    /// safer than removing a unique banner.
    func topRowsImage(rows: Int) -> CGImage? {
        guard rows > 0,
              rows == headerRows,
              let first = slices.first,
              first.height >= rows else { return nil }
        return first.cropping(to: CGRect(
            x: 0, y: 0, width: width, height: rows))?.materialized()
    }

    func topRowsMatch(_ reference: CGImage, rows: Int) -> Bool {
        guard rows > 0,
              rows == headerRows,
              reference.width == width,
              reference.height == rows,
              let ours = topRowsImage(rows: rows) else {
            return false
        }

        return Self.imagesMatchExactly(ours, reference)
    }

    private static func imagesMatchExactly(
        _ lhsImage: CGImage, _ rhsImage: CGImage
    ) -> Bool {
        guard lhsImage.width == rhsImage.width,
              lhsImage.height == rhsImage.height else { return false }
        func rgba(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](
                repeating: 0, count: image.width * image.height * 4)
            guard let context = CGContext(
                data: &bytes,
                width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(
                x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        guard let lhs = rgba(lhsImage), let rhs = rgba(rhsImage) else {
            return false
        }
        return lhs == rhs
    }

    struct Match {
        let preciseOffset: Double
        let headerRows: Int
        let footerRows: Int
        let confidenceScore: Double
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

        // Sparse text can leave a same-colour run at the bottom of two frames,
        // especially when the scroll distance is close to a line-height
        // multiple. That is not necessarily a fixed footer. Evaluate both the
        // detected-footer and complete-viewport geometries before latching one.
        // A real low-detail bar can still produce a confident no-footer match
        // because body rows dominate the weighted score. Latch the footer only
        // when excluding it makes the match materially better; ties remain
        // no-footer because a coincidental blank page tail is indistinguishable
        // from a fixed bar on this frame pair and must not drop real rows.
        let withoutFooter: Match? = lockedFooter == nil && footer > 0
            ? findOverlap(
                prev: prev, next: next, height: h, scale: scale,
                lockedFooter: 0)
            : nil
        func resolveFooterHypothesis(_ withFooter: Match?) -> Match? {
            guard let withoutFooter else { return withFooter }
            guard let withFooter else { return withoutFooter }
            guard abs(withoutFooter.preciseOffset - withFooter.preciseOffset) <= 1
            else {
                Perf.reject(
                    "footer hypotheses disagree "
                    + "\(String(format: "%.2f", withoutFooter.preciseOffset))/"
                    + "\(String(format: "%.2f", withFooter.preciseOffset))")
                return nil
            }
            let footerAdvantage = withoutFooter.confidenceScore
                - withFooter.confidenceScore
            if footerAdvantage > 0.05 {
                return withFooter
            }
            return withoutFooter
        }

        let hEff = h - footer
        guard hEff > minHeight else {
            Perf.reject("hEff \(hEff) too small (footer \(footer))")
            return resolveFooterHypothesis(nil)
        }

        // A fixed top navigation bar stays at the same screen rows while the
        // body moves underneath it. Primary matching uses a bottom template
        // and naturally avoids the bar, but whole-overlap recovery must skip
        // this leading static run when validating the moving body.
        let header: Int = {
            let staticEps = 0.8
            let maxGap = Int(8 * scale)
            let limit = hEff / 3
            var rows = 0
            var index = 0
            var gapUsed = false
            while index < limit {
                if rowDiff[index] < staticEps {
                    index += 1
                    rows = index
                    continue
                }
                var gap = 0
                while index + gap < limit,
                      gap < maxGap,
                      rowDiff[index + gap] >= staticEps {
                    gap += 1
                }
                if !gapUsed, gap < maxGap, index + gap < limit,
                   rowDiff[index + gap] < staticEps {
                    gapUsed = true
                    index += gap
                    continue
                }
                break
            }
            return rows >= Int(6 * scale) ? rows : 0
        }()

        let k = max(Int(32 * scale), hEff / 4)
        guard hEff - k >= 1 else {
            Perf.reject("k \(k) >= hEff \(hEff)")
            return resolveFooterHypothesis(nil)
        }

        // rows are weighted by their detail (horizontal gradient energy)
        var weights = [Double](repeating: 0, count: k)
        var weightSum = 0.0
        for i in 0..<k {
            let w = max(prev.energy[hEff - k + i], 0.5)
            weights[i] = w
            weightSum += w
        }
        guard weightSum > 0 else { return resolveFooterHypothesis(nil) }

        // Pass 1: score every offset. (Storing the scores keeps pass 2 free of
        // the order-dependence the old single-pass second-best tracking had:
        // a chain of small improvements could silently swallow a real alias.)
        let count = hEff - k + 1
        func scoreOffsets(
            previousBands: [Double], nextBands: [Double]
        ) -> (scores: [Double], bestOffset: Int, bestScore: Double) {
            var scores = [Double](repeating: 0, count: count)
            var bestOffset = -1
            var bestScore = Double.greatestFiniteMagnitude
            for s in 0..<count {
                let start = hEff - k - s
                var diff = 0.0
                for i in 0..<k {
                    let a = (hEff - k + i) * 4
                    let b = (start + i) * 4
                    let d = (abs(previousBands[a] - nextBands[b])
                        + abs(previousBands[a + 1] - nextBands[b + 1])
                        + abs(previousBands[a + 2] - nextBands[b + 2])
                        + abs(previousBands[a + 3] - nextBands[b + 3])) / 4
                    diff += weights[i] * d
                }
                diff /= weightSum
                scores[s] = diff
                if diff < bestScore {
                    bestScore = diff
                    bestOffset = s
                }
            }
            return (scores, bestOffset, bestScore)
        }
        let rawScores = scoreOffsets(
            previousBands: prev.bands, nextBands: next.bands)
        let scores = rawScores.scores
        let bestOffset = rawScores.bestOffset
        let bestScore = rawScores.bestScore

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
        // Offset zero carries no new rows, and a candidate without a runner-up
        // has no uniqueness evidence. Keep both as raw rejection conditions,
        // but continue through the blurred primary path before trying the
        // short-overlap recovery so fallback order is deterministic.
        let hasRawCandidate = bestOffset > 0
            && secondScore < Double.greatestFiniteMagnitude
        let unique = hasRawCandidate
            && (secondScore > bestScore * 3 + 0.15
                || secondScore - bestScore > 2.5)
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
        let rawPrimaryAccepted = (bestScore < 2.0
            || fractionalButCertain || modeledSubpixel) && unique
        let rawPrimaryWithinMovingBody = header == 0
            || bestOffset <= hEff - header - k
        let rawPrimaryGloballyUnique = rawPrimaryAccepted
            && rawPrimaryWithinMovingBody
            && primaryCandidateHasUniqueShortEvidence(
                previousBands: prev.bands, nextBands: next.bands,
                previousEnergy: prev.energy, effectiveHeight: hEff,
                scale: scale, primaryTemplateRows: k,
                headerRows: header, candidateOffset: bestOffset)
        if rawPrimaryGloballyUnique {
            return resolveFooterHypothesis(Match(
                preciseOffset: modeledSubpixel ? subpixelOffset : Double(bestOffset),
                headerRows: header,
                footerRows: footer,
                confidenceScore: modeledSubpixel ? subpixelScore : bestScore))
        }

        // Thin text captured between backing pixels can re-rasterize every
        // horizontal edge. The raw matcher still locates the correct offset,
        // but its absolute score rises above the conservative 2.0 gate. Keep
        // all proven raw paths untouched; only after they reject, retry the
        // same candidates with a small vertical box filter applied to the
        // scoring signal. Static/footer detection and output pixels remain raw.
        let blurredPrev = verticallyBoxBlurredBands(prev.bands, height: hEff, radius: 2)
        let blurredNext = verticallyBoxBlurredBands(next.bands, height: hEff, radius: 2)
        let blurred = scoreOffsets(
            previousBands: blurredPrev, nextBands: blurredNext)
        var blurredSecondScore = Double.greatestFiniteMagnitude
        for s in 0..<count where abs(s - blurred.bestOffset) > exclusion {
            if blurred.scores[s] < blurredSecondScore {
                blurredSecondScore = blurred.scores[s]
            }
        }
        let blurredUnique = blurredSecondScore > blurred.bestScore * 3 + 0.15
            || blurredSecondScore - blurred.bestScore > 2.5
        let blurredAccepted = unique
            && blurred.bestOffset > 0
            && abs(blurred.bestOffset - bestOffset) <= 1
            && blurred.bestScore < 2.0
            && blurredSecondScore < Double.greatestFiniteMagnitude
            && blurredUnique
        let blurredPrimaryWithinMovingBody = header == 0
            || blurred.bestOffset <= hEff - header - k
        let blurredPrimaryGloballyUnique = blurredAccepted
            && blurredPrimaryWithinMovingBody
            && primaryCandidateHasUniqueShortEvidence(
                previousBands: blurredPrev, nextBands: blurredNext,
                previousEnergy: prev.energy, effectiveHeight: hEff,
                scale: scale, primaryTemplateRows: k,
                headerRows: header,
                candidateOffset: blurred.bestOffset)
        if blurredPrimaryGloballyUnique {
            // Refine the integer minimum with the vertex of its local score
            // parabola. append() carries the fractional remainder between frames,
            // preventing long captures from drifting by repeated row rounding.
            var preciseOffset = Double(blurred.bestOffset)
            if blurred.bestOffset > 0, blurred.bestOffset + 1 < count {
                let left = blurred.scores[blurred.bestOffset - 1]
                let middle = blurred.scores[blurred.bestOffset]
                let right = blurred.scores[blurred.bestOffset + 1]
                let curvature = left - 2 * middle + right
                if curvature > 0.0001 {
                    let delta = max(-0.5, min(0.5, 0.5 * (left - right) / curvature))
                    preciseOffset += delta
                }
            }
            if Perf.enabled {
                let line = "blur-match off=\(blurred.bestOffset) precise="
                    + "\(String(format: "%.3f", preciseOffset)) best="
                    + "\(String(format: "%.2f", blurred.bestScore)) second="
                    + "\(String(format: "%.2f", blurredSecondScore))\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
            return resolveFooterHypothesis(Match(
                preciseOffset: preciseOffset,
                headerRows: header, footerRows: footer,
                confidenceScore: blurred.bestScore))
        }

        let withoutHeaderRecovery = findShortOverlap(
            prev: prev, next: next, effectiveHeight: hEff,
            scale: scale, primaryTemplateRows: k,
            headerRows: 0, footerRows: footer)
        let withHeaderRecovery = header > 0
            ? findShortOverlap(
                prev: prev, next: next, effectiveHeight: hEff,
                scale: scale, primaryTemplateRows: k,
                headerRows: header, footerRows: footer)
            : nil
        let recovered: Match?
        switch (withoutHeaderRecovery, withHeaderRecovery) {
        case let (withoutHeader?, withHeader?):
            if abs(withoutHeader.preciseOffset - withHeader.preciseOffset) <= 1 {
                recovered = withoutHeader.confidenceScore
                    <= withHeader.confidenceScore ? withoutHeader : withHeader
            } else {
                Perf.reject(
                    "header hypotheses disagree "
                    + "\(String(format: "%.2f", withoutHeader.preciseOffset))/"
                    + "\(String(format: "%.2f", withHeader.preciseOffset))")
                recovered = nil
            }
        case let (withoutHeader?, nil):
            recovered = withoutHeader
        case let (nil, withHeader?):
            recovered = withHeader
        case (nil, nil):
            recovered = nil
        }
        if let recovered {
            return resolveFooterHypothesis(recovered)
        }
        Perf.reject(
            "confidence raw=\(String(format: "%.2f", bestScore))/"
            + "\(String(format: "%.2f", secondScore)) blur="
            + "\(String(format: "%.2f", blurred.bestScore))/"
            + "\(String(format: "%.2f", blurredSecondScore)) off="
            + "\(bestOffset)/\(blurred.bestOffset)")
        return resolveFooterHypothesis(nil)
    }

    /// Vertical box filter for fallback scoring only. Edge samples are
    /// replicated so the signal stays the same length and coordinate system.
    /// Prefix sums keep the retry O(height), rather than multiplying the
    /// already expensive offset search by the five-tap kernel width.
    private static func verticallyBoxBlurredBands(
        _ bands: [Double], height: Int, radius: Int
    ) -> [Double] {
        guard height > 0, radius > 0, bands.count >= height * 4 else { return bands }
        let kernelWidth = radius * 2 + 1
        var result = [Double](repeating: 0, count: height * 4)
        for band in 0..<4 {
            var prefix = [Double](repeating: 0, count: height + 1)
            for y in 0..<height {
                prefix[y + 1] = prefix[y] + bands[y * 4 + band]
            }
            let first = bands[band]
            let last = bands[(height - 1) * 4 + band]
            for y in 0..<height {
                let low = max(0, y - radius)
                let high = min(height - 1, y + radius)
                var sum = prefix[high + 1] - prefix[low]
                if y < radius { sum += Double(radius - y) * first }
                let overflow = y + radius - (height - 1)
                if overflow > 0 { sum += Double(overflow) * last }
                result[y * 4 + band] = sum / Double(kernelWidth)
            }
        }
        return result
    }

    /// A long primary template can match one duplicated card while a shorter
    /// true overlap exists just outside the primary range. Compare the primary
    /// basin's short score only with candidates in that recovery-only range;
    /// aliases already inside the primary range were disambiguated by the
    /// longer template. This avoids whole-overlap checks, which would compare
    /// a fixed top header with moving body, and keeps the safety scan small.
    private static func primaryCandidateHasUniqueShortEvidence(
        previousBands: [Double], nextBands: [Double],
        previousEnergy: [Double], effectiveHeight hEff: Int,
        scale: CGFloat, primaryTemplateRows primaryK: Int,
        headerRows: Int, candidateOffset: Int
    ) -> Bool {
        let movingHeight = hEff - headerRows
        let shortK = max(Int(64 * scale), movingHeight / 5 - 1)
        let recoveryStart = max(1, movingHeight - primaryK + 1)
        let searchMax = movingHeight - shortK
        guard shortK > 0, shortK < primaryK,
              candidateOffset > 0, candidateOffset <= searchMax else {
            return shortK >= primaryK
        }
        guard recoveryStart <= searchMax else { return true }

        var weights = [Double](repeating: 0, count: shortK)
        var weightSum = 0.0
        for index in 0..<shortK {
            let weight = max(previousEnergy[hEff - shortK + index], 0.5)
            weights[index] = weight
            weightSum += weight
        }
        guard weightSum > 0 else { return false }

        func score(at offset: Int) -> Double {
            let nextStart = hEff - shortK - offset
            var value = 0.0
            for index in 0..<shortK {
                let a = (hEff - shortK + index) * 4
                let b = (nextStart + index) * 4
                let difference = (abs(previousBands[a] - nextBands[b])
                    + abs(previousBands[a + 1] - nextBands[b + 1])
                    + abs(previousBands[a + 2] - nextBands[b + 2])
                    + abs(previousBands[a + 3] - nextBands[b + 3])) / 4
                value += weights[index] * difference
            }
            return value / weightSum
        }

        let candidateScore = score(at: candidateOffset)
        let exclusion = max(6, Int(6 * scale))
        var recoveryScore = Double.greatestFiniteMagnitude
        for offset in recoveryStart...searchMax
            where abs(offset - candidateOffset) > exclusion {
            recoveryScore = min(recoveryScore, score(at: offset))
        }
        guard recoveryScore < Double.greatestFiniteMagnitude else { return true }
        return recoveryScore > candidateScore * 3 + 0.15
            || recoveryScore - candidateScore > 2.5
    }

    /// Conservative second pass for a fast scroll that leaves less than the
    /// primary matcher's ~25% template, but still has real overlapping pixels.
    /// The short strip may only propose an offset outside the primary range;
    /// the entire overlap and both halves must then independently verify it.
    /// A jump of one viewport or more remains rejected because missing pixels
    /// cannot be reconstructed safely.
    private static func findShortOverlap(
        prev: RowSig, next: RowSig, effectiveHeight hEff: Int,
        scale: CGFloat, primaryTemplateRows primaryK: Int,
        headerRows: Int, footerRows: Int
    ) -> Match? {
        let movingHeight = hEff - headerRows
        // Keep roughly 20% moving-body evidence. One row below the exact
        // fifth leaves a right-hand score sample at the 80% boundary, which
        // is required to recover the fractional trackpad phase without
        // materially weakening the overlap gate.
        let recoveryK = max(Int(64 * scale), movingHeight / 5 - 1)
        let searchMin = max(1, movingHeight - primaryK + 1)
        let searchMax = movingHeight - recoveryK
        guard recoveryK < primaryK, searchMin <= searchMax else { return nil }

        func weights(start: Int, count: Int) -> (values: [Double], sum: Double) {
            var values = [Double](repeating: 0, count: count)
            var sum = 0.0
            for i in 0..<count {
                let value = max(prev.energy[start + i], 0.5)
                values[i] = value
                sum += value
            }
            return (values, sum)
        }

        func alignedScore(
            previousBands: [Double], nextBands: [Double],
            prevStart: Int, nextStart: Int, count: Int,
            weights: [Double], weightSum: Double
        ) -> Double {
            guard count > 0, weightSum > 0 else { return .greatestFiniteMagnitude }
            var score = 0.0
            for i in 0..<count {
                let a = (prevStart + i) * 4
                let b = (nextStart + i) * 4
                let d = (abs(previousBands[a] - nextBands[b])
                    + abs(previousBands[a + 1] - nextBands[b + 1])
                    + abs(previousBands[a + 2] - nextBands[b + 2])
                    + abs(previousBands[a + 3] - nextBands[b + 3])) / 4
                score += weights[i] * d
            }
            return score / weightSum
        }

        let templateWeights = weights(start: hEff - recoveryK, count: recoveryK)
        guard templateWeights.sum > 0 else { return nil }

        let exclusion = max(6, Int(6 * scale))
        let minHalf = Int(16 * scale)

        typealias Evaluation = (
            accepted: Bool,
            bestOffset: Int,
            bestScore: Double,
            secondScore: Double,
            fullScore: Double,
            firstHalfScore: Double,
            secondHalfScore: Double,
            scores: [Double]
        )

        func evaluate(
            previousBands: [Double], nextBands: [Double]
        ) -> Evaluation {
            // The winner is restricted to the recovery-only range. Runner-up
            // evidence intentionally includes offsets in the primary range too;
            // excluding them makes periodic pages look falsely unique.
            var scores = [Double](
                repeating: .greatestFiniteMagnitude, count: searchMax + 1)
            for offset in 0...searchMax {
                scores[offset] = alignedScore(
                    previousBands: previousBands, nextBands: nextBands,
                    prevStart: hEff - recoveryK,
                    nextStart: hEff - recoveryK - offset,
                    count: recoveryK,
                    weights: templateWeights.values,
                    weightSum: templateWeights.sum)
            }
            var bestOffset = -1
            var bestScore = Double.greatestFiniteMagnitude
            for offset in searchMin...searchMax where scores[offset] < bestScore {
                bestOffset = offset
                bestScore = scores[offset]
            }

            var secondScore = Double.greatestFiniteMagnitude
            if bestOffset >= searchMin {
                for offset in 0...searchMax
                    where abs(offset - bestOffset) > exclusion {
                    secondScore = min(secondScore, scores[offset])
                }
            }
            let overlap = movingHeight - max(0, bestOffset)
            let split = overlap / 2

            func rangeScore(
                prevStart: Int, nextStart: Int, count: Int
            ) -> Double {
                guard count > 0 else { return .greatestFiniteMagnitude }
                let rangeWeights = weights(start: prevStart, count: count)
                return alignedScore(
                    previousBands: previousBands, nextBands: nextBands,
                    prevStart: prevStart, nextStart: nextStart, count: count,
                    weights: rangeWeights.values, weightSum: rangeWeights.sum)
            }
            let fullScore = bestOffset >= 0
                ? rangeScore(
                    prevStart: headerRows + bestOffset,
                    nextStart: headerRows, count: overlap)
                : Double.greatestFiniteMagnitude
            let firstHalfScore = bestOffset >= 0
                ? rangeScore(
                    prevStart: headerRows + bestOffset,
                    nextStart: headerRows, count: split)
                : Double.greatestFiniteMagnitude
            let secondHalfScore = bestOffset >= 0
                ? rangeScore(
                    prevStart: headerRows + bestOffset + split,
                    nextStart: headerRows + split,
                    count: overlap - split)
                : Double.greatestFiniteMagnitude

            let stronglyUnique = secondScore < Double.greatestFiniteMagnitude
                && secondScore > bestScore * 4 + 0.15
                && secondScore - bestScore > 2.5
            let accepted = bestOffset >= searchMin
                && bestScore < 2.0
                && stronglyUnique
                && split >= minHalf
                && overlap - split >= minHalf
                && fullScore < 2.0
                && firstHalfScore < 2.0
                && secondHalfScore < 2.0
            return (
                accepted, bestOffset, bestScore, secondScore,
                fullScore, firstHalfScore, secondHalfScore, scores)
        }

        func refinedOffset(_ evaluation: Evaluation) -> Double {
            let offset = evaluation.bestOffset
            var precise = Double(offset)
            if offset > 0, offset + 1 < evaluation.scores.count {
                let left = evaluation.scores[offset - 1]
                let middle = evaluation.scores[offset]
                let right = evaluation.scores[offset + 1]
                let curvature = left - 2 * middle + right
                if curvature > 0.0001 {
                    let delta = max(
                        -0.5, min(0.5, 0.5 * (left - right) / curvature))
                    precise += delta
                }
                if Perf.enabled {
                    let line = "short-refine off=\(offset) left="
                        + "\(String(format: "%.3f", left)) mid="
                        + "\(String(format: "%.3f", middle)) right="
                        + "\(String(format: "%.3f", right)) precise="
                        + "\(String(format: "%.3f", precise))\n"
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
            }
            return precise
        }

        let raw = evaluate(previousBands: prev.bands, nextBands: next.bands)
        if raw.accepted {
            if Perf.enabled {
                let line = "short-overlap off=\(raw.bestOffset) k=\(recoveryK) "
                    + "best=\(String(format: "%.2f", raw.bestScore)) "
                    + "second=\(String(format: "%.2f", raw.secondScore)) "
                    + "full=\(String(format: "%.2f", raw.fullScore))\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
            // An exact raw overlap has a cusp-shaped zero minimum, not a true
            // parabola. Refining asymmetric neighbouring scores would invent a
            // fractional displacement. A non-zero but confidently accepted raw
            // valley can still be a real fractional trackpad phase, though, so
            // refine only that case and carry its residual across frames.
            let precise = raw.bestScore < 0.01
                ? Double(raw.bestOffset)
                : refinedOffset(raw)
            return Match(
                preciseOffset: precise,
                headerRows: headerRows, footerRows: footerRows,
                confidenceScore: raw.bestScore)
        }

        // A fast trackpad flick can be both out of the primary search range
        // and between backing pixels. Retry the conservative short-overlap
        // gates on the same scoring-only blur as the primary fallback. The
        // blurred valley must agree with the raw proposal; output stays raw.
        let blurredPrev = verticallyBoxBlurredBands(
            prev.bands, height: hEff, radius: 2)
        let blurredNext = verticallyBoxBlurredBands(
            next.bands, height: hEff, radius: 2)
        let blurred = evaluate(
            previousBands: blurredPrev, nextBands: blurredNext)
        guard blurred.accepted,
              abs(blurred.bestOffset - raw.bestOffset) <= 1 else { return nil }

        let precise = refinedOffset(blurred)
        if Perf.enabled {
            let line = "blur-short-overlap off=\(blurred.bestOffset) precise="
                + "\(String(format: "%.3f", precise)) k=\(recoveryK) "
                + "best=\(String(format: "%.2f", blurred.bestScore)) "
                + "second=\(String(format: "%.2f", blurred.secondScore)) "
                + "full=\(String(format: "%.2f", blurred.fullScore))\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        return Match(
            preciseOffset: precise,
            headerRows: headerRows, footerRows: footerRows,
            confidenceScore: blurred.bestScore)
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

    func compose(
        includeHeader: Bool = true,
        includeFooter: Bool = true,
        inferredFooterRows: Int = 0
    ) -> CGImage? {
        guard !slices.isEmpty else { return nil }

        // The first slice carries any fixed header/footer chrome. Across a
        // marked gap, later segments omit their proven duplicate header; a
        // detected footer is removed from every completed segment and attached
        // once from the final segment's last frame.
        var parts = slices
        let effectiveFooterRows = footerRows > 0
            ? footerRows
            : max(0, min(inferredFooterRows, lastFrame.height / 3))
        let effectiveHeaderRows = includeHeader ? 0 : headerRows
        if let first = parts.first,
           first.height > effectiveHeaderRows + effectiveFooterRows,
           lastFrame.height > effectiveFooterRows,
           effectiveHeaderRows > 0 || effectiveFooterRows > 0 {
            let trimmed = first.cropping(to: CGRect(
                x: 0, y: effectiveHeaderRows,
                width: width,
                height: first.height
                    - effectiveHeaderRows - effectiveFooterRows
            ))?.materialized()
            if let trimmed {
                parts[0] = trimmed
                if includeFooter, effectiveFooterRows > 0,
                   let footer = lastFrame.cropping(to: CGRect(
                    x: 0, y: lastFrame.height - effectiveFooterRows,
                    width: width, height: effectiveFooterRows
                   ))?.materialized() {
                    parts.append(footer)
                }
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
