import AppKit
import Carbon.HIToolbox

/// Scrolling screenshot, Lark-style: the user scrolls the content themselves
/// while Snippr watches the selected area and stitches each new frame
/// automatically. No synthetic scroll events — no Accessibility permission —
/// and Snippr's own overlay windows are excluded from the capture.
@MainActor
final class ScrollingCapture {
    static var active: ScrollingCapture?

    enum Direction { case down, up } // legacy menu compatibility; stitching is top-to-bottom

    static let escHotkeyID: UInt32 = 999

    private let onFinish: @MainActor (CapturedImage?) -> Void
    nonisolated(unsafe) private var finished = false
    private var borderWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var progressLabel: NSTextField?
    private var escLocalMonitor: Any?
    private var escHotkeyRef: EventHotKeyRef?

    init(onFinish: @escaping @MainActor (CapturedImage?) -> Void) {
        self.onFinish = onFinish
    }

    static func begin(direction: Direction, onFinish: @escaping @MainActor (CapturedImage?) -> Void) {
        guard active == nil else { return }
        SelectionOverlay.begin(mode: .area) { result in
            guard case let .area(screen, _, rect) = result else {
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

    private func run(screen: NSScreen, rect: CGRect) async {
        showChrome(screen: screen, rect: rect)
        installStop()
        defer {
            removeStop()
            hideChrome()
            ScrollingCapture.active = nil
        }

        let scale = screen.backingScaleFactor
        let maxHeightPx = CGFloat(Settings.shared.scrollMaxHeight)
        var stitcher: VerticalStitcher?
        var lastHash = 0

        while !finished {
            guard let frame = try? await captureArea(screen: screen, rect: rect) else { break }
            let hash = Self.quickHash(frame.cgImage)
            if hash != lastHash {
                lastHash = hash
                if let s = stitcher {
                    if s.append(frame.cgImage, direction: .down) {
                        updateProgress("Đã ghép \(Int(CGFloat(s.totalHeight) / scale)) pt — cuộn tiếp, xong thì bấm ✓ hoặc Esc")
                    } else {
                        updateProgress("Chưa khớp được — cuộn chậm lại một chút")
                    }
                    if CGFloat(s.totalHeight) >= maxHeightPx { break }
                } else {
                    stitcher = VerticalStitcher(first: frame.cgImage)
                    updateProgress("Cuộn trang từ từ — Snippr tự ghép · bấm ✓ hoặc Esc khi xong")
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let result = stitcher?.compose().map { CapturedImage(cgImage: $0, scale: scale) }
        onFinish(result)
    }

    private func captureArea(screen: NSScreen, rect: CGRect) async throws -> CapturedImage? {
        let full = try await CaptureEngine.shared.captureDisplay(screen: screen, excludingOwnWindows: true)
        return full.cropping(toViewRect: rect)
    }

    static func quickHash(_ image: CGImage) -> Int {
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

    // MARK: stop signals (Esc works globally via Carbon — no Accessibility needed)

    private func installStop() {
        var hotKeyID = EventHotKeyID(signature: OSType(0x534E4553) /* 'SNES' */, id: Self.escHotkeyID)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, hotKeyID, GetApplicationEventTarget(), 0, &escHotkeyRef)
        _ = hotKeyID
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
        HotkeyManager.shared.auxHandler = nil
        if let m = escLocalMonitor {
            NSEvent.removeMonitor(m)
            escLocalMonitor = nil
        }
    }

    @objc private func finishTapped() {
        finished = true
    }

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

        // control bar sits above the area (below it when there's no room)
        let barWidth: CGFloat = 480
        let barHeight: CGFloat = 34
        var barY = rect.maxY + screen.frame.minY + 10
        if barY + barHeight > screen.visibleFrame.maxY {
            barY = rect.minY + screen.frame.minY - barHeight - 10
        }
        let barX = min(
            max(rect.midX + screen.frame.minX - barWidth / 2, screen.frame.minX + 8),
            screen.frame.maxX - barWidth - 8
        )

        let panel = NSPanel(
            contentRect: CGRect(x: barX, y: barY, width: barWidth, height: barHeight),
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
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 9

        let label = NSTextField(labelWithString: "Cuộn trang từ từ — Snippr tự ghép ảnh")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        progressLabel = label

        let done = NSButton(title: "✓ Xong", target: self, action: #selector(finishTapped))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.font = .systemFont(ofSize: 12, weight: .semibold)

        let stack = NSStackView(views: [label, NSView(), done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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

// MARK: - Stitcher

/// Stitches equal-width frames vertically by locating the previous frame's
/// bottom strip inside each new frame. Frames that can't be matched reliably
/// are skipped instead of guessed, so output never contains corrupt seams.
final class VerticalStitcher {
    private(set) var slices: [CGImage] = []
    private var lastFrame: CGImage
    let width: Int
    private(set) var totalHeight: Int

    init(first: CGImage) {
        slices = [first]
        lastFrame = first
        width = first.width
        totalHeight = first.height
    }

    /// Append new content from `frame`. Returns false when the frame brought
    /// nothing new or couldn't be matched (caller may ask the user to scroll slower).
    func append(_ frame: CGImage, direction: ScrollingCapture.Direction) -> Bool {
        guard frame.width == width else { return false }
        guard let offset = Self.findOverlap(previous: lastFrame, next: frame), offset > 0 else {
            return false
        }
        let rows = min(offset, frame.height)
        guard let slice = frame.cropping(to: CGRect(
            x: 0, y: frame.height - rows, width: width, height: rows
        )) else { return false }
        slices.append(slice)
        totalHeight += rows
        lastFrame = frame
        return true
    }

    /// How many rows of new content `next` has relative to `previous`;
    /// nil when confidence is too low (scrolled too far, animations, ...).
    static func findOverlap(previous: CGImage, next: CGImage) -> Int? {
        let h = previous.height
        guard h == next.height, previous.width == next.width, h > 40 else { return nil }
        guard let prevG = grayRows(previous), let nextG = grayRows(next) else { return nil }

        let k = max(24, h / 5)
        let template = Array(prevG[(h - k)...])
        var bestOffset = -1
        var bestScore = Double.greatestFiniteMagnitude

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
        guard bestOffset >= 0, bestScore < 6.0 else { return nil }
        return bestOffset
    }

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
            rows[y] = Double(sum) / Double(max(1, count))
        }
        return rows
    }

    func compose() -> CGImage? {
        guard !slices.isEmpty else { return nil }
        let h = slices.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(
            data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var y = h
        for slice in slices {
            y -= slice.height
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: slice.width, height: slice.height))
        }
        return ctx.makeImage()
    }
}
