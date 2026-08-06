import AppKit

/// Borderless window that can become key so it receives Esc / mouse events.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum OverlayResult {
    /// Area selected: frozen screen image + selection rect in screen-local points (bottom-left origin).
    case area(screen: NSScreen, frozen: CapturedImage, rect: CGRect)
    case window(WindowInfo)
    case cancelled
}

enum OverlayMode {
    case area        // freeze screens, drag to select
    case windowPick  // hover to highlight a window, click to pick
}

/// Full-screen selection overlay across all displays.
@MainActor
final class SelectionOverlay {
    static var current: SelectionOverlay?

    private var windows: [OverlayWindow] = []
    private let mode: OverlayMode
    private let completion: @MainActor (OverlayResult) -> Void
    fileprivate var finished = false

    init(mode: OverlayMode, completion: @escaping @MainActor (OverlayResult) -> Void) {
        self.mode = mode
        self.completion = completion
    }

    static func begin(mode: OverlayMode, completion: @escaping @MainActor (OverlayResult) -> Void) {
        guard current == nil else { return }
        let overlay = SelectionOverlay(mode: mode, completion: completion)
        current = overlay
        Task { @MainActor in
            await overlay.start()
        }
    }

    @MainActor
    private func start() async {
        let screens = NSScreen.screens
        let cursorScreen = screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? screens[0]
        let windowList = mode == .windowPick ? CaptureEngine.onScreenWindows() : []

        // The screen under the cursor goes up first so the overlay appears as
        // soon as possible; the rest are frozen concurrently right after.
        if mode == .area {
            do {
                let frozen = try await CaptureEngine.shared.captureDisplay(screen: cursorScreen)
                guard !finished else { return }
                addOverlay(for: cursorScreen, frozen: frozen, windowList: windowList, makeKey: true)
            } catch {
                finish(.cancelled)
                AppServices.handleCaptureError(error)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.crosshair.set()

            let others = screens.filter { $0 != cursorScreen }
            guard !others.isEmpty else { return }
            Task { @MainActor [weak self] in
                await withTaskGroup(of: (NSScreen, CapturedImage?).self) { group in
                    for screen in others {
                        group.addTask { @MainActor in
                            (screen, try? await CaptureEngine.shared.captureDisplay(screen: screen))
                        }
                    }
                    for await (screen, frozen) in group {
                        guard let self, !self.finished, let frozen else { continue }
                        self.addOverlay(for: screen, frozen: frozen, windowList: windowList, makeKey: false)
                    }
                }
            }
            return
        }

        for screen in screens {
            addOverlay(for: screen, frozen: nil, windowList: windowList, makeKey: screen == cursorScreen)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()
    }

    @MainActor
    private func addOverlay(
        for screen: NSScreen, frozen: CapturedImage?,
        windowList: [WindowInfo], makeKey: Bool
    ) {
        let win = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.isOpaque = mode == .area
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = SelectionOverlayView(
            mode: mode,
            screen: screen,
            frozen: frozen,
            windowList: windowList,
            owner: self
        )
        win.contentView = view
        win.makeFirstResponder(view)
        windows.append(win)
        if makeKey {
            win.makeKeyAndOrderFront(nil)
        } else {
            win.orderFront(nil)
        }
    }

    func finish(_ result: OverlayResult) {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        SelectionOverlay.current = nil
        completion(result)
    }
}

// MARK: - Overlay view

final class SelectionOverlayView: NSView {
    private let mode: OverlayMode
    private let screen: NSScreen
    private let frozen: CapturedImage?
    private let windowList: [WindowInfo]
    private weak var owner: SelectionOverlay?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var mousePos: CGPoint = .zero
    private var hoverWindow: WindowInfo?

    init(mode: OverlayMode, screen: NSScreen, frozen: CapturedImage?, windowList: [WindowInfo], owner: SelectionOverlay) {
        self.mode = mode
        self.screen = screen
        self.frozen = frozen
        self.windowList = windowList
        self.owner = owner
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        ))
    }

    private var selectionRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let frozen {
            ctx.draw(frozen.cgImage, in: bounds)
        }

        // dim everything except selection
        ctx.setFillColor(NSColor.black.withAlphaComponent(mode == .area ? 0.4 : 0.25).cgColor)
        if let sel = selectionRect {
            ctx.beginPath()
            ctx.addRect(bounds)
            ctx.addRect(sel)
            ctx.fillPath(using: .evenOdd)
        } else if let hover = hoverWindowLocalRect() {
            ctx.beginPath()
            ctx.addRect(bounds)
            ctx.addRect(hover)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }

        let accent = NSColor.controlAccentColor

        if let sel = selectionRect {
            // border
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel.insetBy(dx: -0.75, dy: -0.75))
            drawSizeLabel(for: sel)
        } else if mode == .area {
            // crosshair
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: mousePos.x, y: 0))
            ctx.addLine(to: CGPoint(x: mousePos.x, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: mousePos.y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: mousePos.y))
            ctx.strokePath()
        }

        if mode == .windowPick, let hover = hoverWindowLocalRect() {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2.5)
            ctx.stroke(hover.insetBy(dx: 1, dy: 1))
            if let title = hoverWindow.map({ $0.title.isEmpty ? $0.ownerName : $0.title }) {
                drawBubble(text: title, at: CGPoint(x: hover.midX, y: hover.maxY - 28), centered: true)
            }
        }
    }

    private func drawSizeLabel(for sel: CGRect) {
        let text = "\(Int(sel.width)) × \(Int(sel.height))"
        var pos = CGPoint(x: sel.maxX + 8, y: sel.minY - 24)
        if pos.y < 4 { pos.y = sel.minY + 6 }
        if pos.x > bounds.width - 90 { pos.x = sel.maxX - 90 }
        drawBubble(text: text, at: pos, centered: false)
    }

    private func drawBubble(text: String, at point: CGPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var origin = point
        if centered { origin.x -= size.width / 2 }
        let bg = CGRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        let path = NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        str.draw(at: origin)
    }

    // MARK: Window hover helpers

    private func hoverWindowLocalRect() -> CGRect? {
        guard mode == .windowPick, let hover = hoverWindow else { return nil }
        let global = hover.frameAppKit
        return CGRect(
            x: global.minX - screen.frame.minX,
            y: global.minY - screen.frame.minY,
            width: global.width, height: global.height
        )
    }

    private func updateHover(at localPoint: CGPoint) {
        let globalPoint = CGPoint(
            x: localPoint.x + screen.frame.minX,
            y: localPoint.y + screen.frame.minY
        )
        hoverWindow = windowList.first(where: { $0.frameAppKit.contains(globalPoint) })
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        if mode == .windowPick { updateHover(at: mousePos) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mode == .area {
            dragStart = p
            dragCurrent = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .area:
            if let sel = selectionRect, sel.width > 3, sel.height > 3, let frozen {
                owner?.finish(.area(screen: screen, frozen: frozen, rect: sel))
            } else {
                owner?.finish(.cancelled)
            }
        case .windowPick:
            if let hover = hoverWindow {
                owner?.finish(.window(hover))
            } else {
                owner?.finish(.cancelled)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            owner?.finish(.cancelled)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
