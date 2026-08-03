import AppKit
import Carbon.HIToolbox

/// Scrolling screenshot: select an area, auto-scroll the content underneath,
/// capture each step and stitch the frames vertically.
@MainActor
final class ScrollingCapture {
    static var active: ScrollingCapture?

    enum Direction { case down, up }

    private let direction: Direction
    private let onFinish: @MainActor (CapturedImage?) -> Void
    nonisolated(unsafe) private var cancelled = false
    private var escHotkeyRef: EventHotKeyRef?
    private var borderWindow: NSWindow?
    private var progressLabel: NSTextField?

    init(direction: Direction, onFinish: @escaping @MainActor (CapturedImage?) -> Void) {
        self.direction = direction
        self.onFinish = onFinish
    }

    static func begin(direction: Direction, onFinish: @escaping @MainActor (CapturedImage?) -> Void) {
        guard active == nil else { return }
        guard AXIsProcessTrusted() else {
            // system prompt also adds Snippr to the Accessibility list
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            ToastHUD.show("Scrolling capture needs Accessibility permission", symbol: "exclamationmark.triangle.fill", duration: 4)
            onFinish(nil)
            return
        }
        SelectionOverlay.begin(mode: .area) { result in
            guard case let .area(screen, _, rect) = result else {
                onFinish(nil)
                return
            }
            let session = ScrollingCapture(direction: direction, onFinish: onFinish)
            active = session
            Task { @MainActor in
                await session.run(screen: screen, rect: rect)
            }
        }
    }

    @MainActor
    private func run(screen: NSScreen, rect: CGRect) async {
        showBorder(screen: screen, rect: rect)
        registerEscHotkey()
        defer {
            unregisterEscHotkey()
            hideBorder()
            ScrollingCapture.active = nil
        }

        let scale = screen.backingScaleFactor
        let maxHeightPx = CGFloat(Settings.shared.scrollMaxHeight)
        let delay = 0.95 - 0.75 * Settings.shared.scrollSpeed // seconds between steps

        // Move cursor into the middle of the area so scroll events hit the right view
        let globalRect = CGRect(
            x: rect.minX + screen.frame.minX, y: rect.minY + screen.frame.minY,
            width: rect.width, height: rect.height
        )
        let primaryHeight = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
        let cgCenter = CGPoint(x: globalRect.midX, y: primaryHeight - globalRect.midY)
        CGWarpMouseCursorPosition(cgCenter)
        try? await Task.sleep(nanoseconds: 200_000_000)

        var stitcher: VerticalStitcher?
        var lastFrameHash: Int = 0
        var identicalCount = 0
        var steps = 0

        while !cancelled {
            steps += 1
            guard steps <= 250 else { break }

            guard let frame = try? await captureArea(screen: screen, rect: rect) else { break }

            let hash = Self.quickHash(frame.cgImage)
            if hash == lastFrameHash {
                identicalCount += 1
                if identicalCount >= 2 { break } // reached the end of the page
            } else {
                identicalCount = 0
            }
            lastFrameHash = hash

            if let s = stitcher {
                let grown = s.append(frame.cgImage, direction: direction)
                updateProgress("\(Int(CGFloat(s.totalHeight) / scale)) pt")
                if !grown { break }
                if CGFloat(s.totalHeight) >= maxHeightPx { break }
            } else {
                stitcher = VerticalStitcher(first: frame.cgImage)
            }

            postScroll(pixels: rect.height * 0.68)
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.12) * 1_000_000_000))
        }

        let result = stitcher?.compose().map { CapturedImage(cgImage: $0, scale: scale) }
        onFinish(cancelled ? nil : result ?? nil)
    }

    private func captureArea(screen: NSScreen, rect: CGRect) async throws -> CapturedImage? {
        let full = try await CaptureEngine.shared.captureDisplay(screen: screen)
        return full.cropping(toViewRect: rect)
    }

    private func postScroll(pixels: CGFloat) {
        var amount = Int32(-pixels) // negative wheel = content scrolls down
        if direction == .up { amount = -amount }
        if Settings.shared.scrollingReverse { amount = -amount }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private static func quickHash(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var hasher = Hasher()
        let stride = max(1, data.count / 4096)
        var i = 0
        while i < data.count {
            hasher.combine(data[i])
            i += stride
        }
        return hasher.finalize()
    }

    // MARK: cancel / UI

    private func registerEscHotkey() {
        var hotKeyID = EventHotKeyID(signature: OSType(0x534E4553) /* 'SNES' */, id: 999)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, hotKeyID, GetApplicationEventTarget(), 0, &escHotkeyRef)
        _ = hotKeyID
        // reuse HotkeyManager's installed handler pipeline? Esc arrives as hotkey id 999 via same Carbon handler
        // Simplest: poll-based check via local monitor as fallback
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) { self?.cancelled = true }
        }
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) { self?.cancelled = true; return nil }
            return event
        }
    }

    private var escMonitor: Any?
    private var escLocalMonitor: Any?

    private func unregisterEscHotkey() {
        if let ref = escHotkeyRef { UnregisterEventHotKey(ref); escHotkeyRef = nil }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
    }

    @MainActor
    private func showBorder(screen: NSScreen, rect: CGRect) {
        let win = NSWindow(
            contentRect: CGRect(
                x: rect.minX + screen.frame.minX - 3,
                y: rect.minY + screen.frame.minY - 3,
                width: rect.width + 6, height: rect.height + 6
            ),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 3
        border.layer?.cornerRadius = 4

        let label = NSTextField(labelWithString: "Scrolling… press Esc to stop")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.drawsBackground = true
        label.alignment = .center
        label.frame = CGRect(x: 6, y: 6, width: 210, height: 18)
        border.addSubview(label)
        progressLabel = label

        win.contentView = border
        win.orderFrontRegardless()
        borderWindow = win
    }

    private func updateProgress(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.progressLabel?.stringValue = "Scrolling… \(text) (Esc to stop)"
        }
    }

    @MainActor
    private func hideBorder() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }
}

// MARK: - Stitcher

/// Stitches equal-width frames vertically by finding the overlap offset
/// between the accumulated image tail and each new frame.
final class VerticalStitcher {
    private(set) var slices: [CGImage] = [] // in display order, top to bottom
    private var lastFrame: CGImage
    let width: Int
    private(set) var totalHeight: Int

    init(first: CGImage) {
        slices = [first]
        lastFrame = first
        width = first.width
        totalHeight = first.height
    }

    /// Append the next frame. Returns false if no new content was found.
    func append(_ frame: CGImage, direction: ScrollingCapture.Direction) -> Bool {
        guard frame.width == width else { return false }
        guard let offset = Self.findOverlap(previous: lastFrame, next: frame) else {
            // no reliable match: assume full new frame
            appendSlice(frame, newRows: frame.height, direction: direction)
            lastFrame = frame
            return true
        }
        if offset <= 0 { return false } // identical content — nothing scrolled
        appendSlice(frame, newRows: offset, direction: direction)
        lastFrame = frame
        return true
    }

    private func appendSlice(_ frame: CGImage, newRows: Int, direction: ScrollingCapture.Direction) {
        let rows = min(newRows, frame.height)
        let cropRect: CGRect
        switch direction {
        case .down:
            // new content is at the bottom of the frame
            cropRect = CGRect(x: 0, y: frame.height - rows, width: width, height: rows)
        case .up:
            cropRect = CGRect(x: 0, y: 0, width: width, height: rows)
        }
        guard let slice = frame.cropping(to: cropRect) else { return }
        if direction == .down {
            slices.append(slice)
        } else {
            slices.insert(slice, at: 0)
        }
        totalHeight += rows
    }

    /// How many rows of new content `next` contains relative to `previous`.
    /// Returns nil when confidence is too low.
    static func findOverlap(previous: CGImage, next: CGImage) -> Int? {
        let h = previous.height
        guard h == next.height, previous.width == next.width, h > 40 else { return nil }
        guard let prevG = grayRows(previous), let nextG = grayRows(next) else { return nil }

        // Template: bottom K rows of previous. Find them inside next.
        let k = max(24, h / 5)
        let template = Array(prevG[(h - k)...])
        var bestOffset = -1
        var bestScore = Double.greatestFiniteMagnitude

        // If content scrolled by S rows, template appears in next at row (h - k - S).
        for s in 0...(h - k) {
            let start = h - k - s
            var diff: Double = 0
            for i in 0..<k {
                diff += abs(template[i] - nextG[start + i])
            }
            diff /= Double(k)
            if diff < bestScore {
                bestScore = diff
                bestOffset = s
            }
        }
        // require a decent match; typical matched rows diff < 2.0 (0..255 scale)
        guard bestOffset >= 0, bestScore < 6.0 else { return nil }
        return bestOffset
    }

    /// Mean gray value per row (sampled columns) — cheap row signature.
    private static func grayRows(_ image: CGImage) -> [Double]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let sampleCols = min(96, w)
        let colStride = max(1, w / sampleCols)
        var rows = [Double](repeating: 0, count: h)
        for y in 0..<h {
            var sum = 0
            var count = 0
            var x = 0
            while x < w {
                sum += Int(buf[y * w + x])
                count += 1
                x += colStride
            }
            // CGContext row 0 is top; keep top-down order to match CGImage cropping coords
            rows[y] = Double(sum) / Double(max(1, count))
        }
        return rows
    }

    /// Compose all slices into the final tall image.
    func compose() -> CGImage? {
        guard !slices.isEmpty else { return nil }
        let h = slices.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(
            data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext origin is bottom-left; draw top slice at the top
        var y = h
        for slice in slices {
            y -= slice.height
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: slice.width, height: slice.height))
        }
        return ctx.makeImage()
    }
}
