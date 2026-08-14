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
    /// One session per begin() — the shared state machine every view on every
    /// display consults (exactly-once initialCapture, phase, pixel rect).
    let session: OverlaySession
    private let completion: @MainActor (OverlayResult) -> Void
    /// SINGLE source of truth for "this session is over": derived from the
    /// session phase, never a separate flag — a separate bool and the phase
    /// could disagree, letting a late secondary-display capture add windows
    /// to a completed session (or a completed phase leave windows alive).
    fileprivate var finished: Bool { session.phase == .completed }

    init(purpose: OverlayPurpose, completion: @escaping @MainActor (OverlayResult) -> Void) {
        self.mode = purpose == .windowPick ? .windowPick : .area
        self.session = OverlaySession(
            purpose: purpose, inputs: .snapshot())
        self.completion = completion
    }

    /// Every caller states its purpose — there is deliberately no
    /// mode-based entry point left: a shared `.area` would silently give
    /// Instant OCR and the scroll picker whatever review chrome the
    /// area-review purpose grows.
    static func begin(
        purpose: OverlayPurpose,
        completion: @escaping @MainActor (OverlayResult) -> Void
    ) {
        guard current == nil else { return }
        let overlay = SelectionOverlay(purpose: purpose, completion: completion)
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
            AppActivation.activateNow()
            NSCursor.crosshair.set()

            let others = screens.filter { $0 != cursorScreen }
            guard !others.isEmpty else { return }
            Task { @MainActor [weak self] in
                // Pass a Sendable index through the task group; NSScreen is
                // explicitly non-Sendable and stays isolated to MainActor.
                await withTaskGroup(of: (Int, CapturedImage?).self) { group in
                    for (index, screen) in others.enumerated() {
                        group.addTask { @MainActor in
                            (index, try? await CaptureEngine.shared.captureDisplay(screen: screen))
                        }
                    }
                    for await (index, frozen) in group {
                        guard let self, !self.finished, let frozen else { continue }
                        self.addOverlay(
                            for: others[index], frozen: frozen,
                            windowList: windowList, makeKey: false
                        )
                    }
                }
            }
            return
        }

        for screen in screens {
            addOverlay(for: screen, frozen: nil, windowList: windowList, makeKey: screen == cursorScreen)
        }
        AppActivation.activateNow()
        NSCursor.crosshair.set()
    }

    /// Test hook: drives the exact production guard a late secondary-display
    /// capture hits when it resolves after the session completed.
    func addOverlayForTesting(
        screen: NSScreen, frozen: CapturedImage?
    ) -> Int {
        addOverlay(for: screen, frozen: frozen, windowList: [], makeKey: false)
        return windows.count
    }

    @MainActor
    private func addOverlay(
        for screen: NSScreen, frozen: CapturedImage?,
        windowList: [WindowInfo], makeKey: Bool
    ) {
        // Same completed-state guard the async freeze tasks consult — a
        // window must never attach to a finished session.
        guard !finished else { return }
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
        win.orderFrontRegardless() // reliable even when activation is denied
        if makeKey {
            win.makeKeyAndOrderFront(nil)
        }
    }

    /// Idempotency latch for teardown — separate from the PHASE: a headless
    /// commitInitialCapture legitimately reaches `.completed` first, and
    /// finish() must still run its one teardown + completion afterwards.
    private var tornDown = false

    /// The ONLY terminal route: completes the session and tears down every
    /// window exactly once. All cancel/confirm paths and (later) review
    /// actions funnel through here so the session phase and the window
    /// lifecycle can never disagree. Late-view guards read the session phase;
    /// this latch only prevents double teardown/completion.
    func finish(_ result: OverlayResult) {
        guard !tornDown else { return }
        tornDown = true
        session.forceComplete()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        if SelectionOverlay.current === self {
            SelectionOverlay.current = nil
        }
        completion(result)
    }

    /// Area overlays exist on every display. Starting a selection on one must
    /// clear a stale selection on another so there is always one unambiguous
    /// region for Return/the Capture button to confirm.
    fileprivate func areaSelectionDidBegin(in activeView: SelectionOverlayView) {
        for window in windows {
            guard let view = window.contentView as? SelectionOverlayView, view !== activeView else { continue }
            view.clearAreaSelection()
        }
    }
}

// MARK: - Overlay view

final class SelectionOverlayView: NSView {
    private let mode: OverlayMode
    private let screen: NSScreen
    private let frozen: CapturedImage?
    private let windowList: [WindowInfo]
    private weak var owner: SelectionOverlay?

    private enum AreaDrag {
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
        case captureButton
    }

    private var areaSelection: CGRect?
    private var areaDrag: AreaDrag?
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

    /// Without this the very first drag after a capture is swallowed just to
    /// activate Snippr, so the user has to select the area twice.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        ))
    }

    fileprivate func clearAreaSelection() {
        guard areaSelection != nil else { return }
        areaSelection = nil
        areaDrag = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let frozen {
            ctx.draw(frozen.cgImage, in: bounds)
        }

        // dim everything except selection
        ctx.setFillColor(NSColor.black.withAlphaComponent(mode == .area ? 0.4 : 0.25).cgColor)
        if let sel = areaSelection {
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

        if let sel = areaSelection {
            // border
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel.insetBy(dx: -0.75, dy: -0.75))
            drawSelectionHandles(for: sel, in: ctx)
            drawSizeLabel(for: sel)
            drawCaptureButton(in: ctx)
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

    private func drawSelectionHandles(for rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for (_, handleRect) in EditableSelectionGeometry.handleRects(for: rect) {
            ctx.fill(handleRect)
            ctx.stroke(handleRect)
        }
    }

    private func drawSizeLabel(for sel: CGRect) {
        let text = "\(Int(sel.width)) × \(Int(sel.height))"
        var pos = CGPoint(x: sel.minX, y: sel.maxY + 8)
        if pos.y > bounds.maxY - 20 { pos.y = sel.maxY - 24 }
        if pos.x > bounds.maxX - 90 { pos.x = bounds.maxX - 90 }
        drawBubble(text: text, at: pos, centered: false)
    }

    private var captureButtonRect: CGRect? {
        guard let sel = areaSelection, sel.width >= 4, sel.height >= 4 else { return nil }
        let size = CGSize(width: 100, height: 30)
        let margin: CGFloat = 8
        var x = sel.maxX - size.width
        var y = sel.minY - size.height - margin
        x = min(bounds.maxX - size.width - margin, max(bounds.minX + margin, x))
        if y < bounds.minY + margin {
            y = sel.maxY + margin
        }
        if y + size.height > bounds.maxY - margin {
            // Full-height selections have no outside edge: keep the action
            // reachable inside the clear region near its lower-right corner.
            y = min(bounds.maxY - size.height - margin, max(bounds.minY + margin, sel.minY + margin))
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func drawCaptureButton(in ctx: CGContext) {
        guard let rect = captureButtonRect else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.setFill()
        path.fill()

        let text = "Capture  ↵" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                  withAttributes: attrs)
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
        if mode == .windowPick {
            updateHover(at: mousePos)
        } else {
            updateAreaCursor(at: mousePos)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard mode == .area else { return }

        if event.clickCount >= 2, let selection = areaSelection, selection.contains(p) {
            confirmAreaSelection()
            return
        }
        if let button = captureButtonRect, button.contains(p) {
            areaDrag = .captureButton
            return
        }
        if let selection = areaSelection,
           let handle = EditableSelectionGeometry.handle(at: p, in: selection) {
            areaDrag = .resizing(handle: handle, original: selection)
            handle.cursor.set()
            return
        }
        if let selection = areaSelection, selection.contains(p) {
            areaDrag = .moving(start: p, original: selection)
            NSCursor.closedHand.set()
            return
        }

        owner?.areaSelectionDidBegin(in: self)
        let clamped = EditableSelectionGeometry.clampedPoint(p, to: bounds)
        areaSelection = CGRect(origin: clamped, size: .zero)
        areaDrag = .creating(anchor: clamped)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch areaDrag {
        case .creating(let anchor):
            areaSelection = EditableSelectionGeometry.rect(from: anchor, to: p, within: bounds)
        case .moving(let start, let original):
            areaSelection = EditableSelectionGeometry.moved(
                original,
                by: CGPoint(x: p.x - start.x, y: p.y - start.y),
                within: bounds
            )
        case .resizing(let handle, let original):
            areaSelection = EditableSelectionGeometry.resized(
                original, using: handle, to: p, within: bounds
            )
        case .captureButton, .none:
            break
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .area:
            let p = convert(event.locationInWindow, from: nil)
            if case .captureButton = areaDrag,
               let button = captureButtonRect, button.contains(p) {
                confirmAreaSelection()
                return
            }
            areaDrag = nil
            if let selection = areaSelection, selection.width < 4 || selection.height < 4 {
                areaSelection = nil
            }
            updateAreaCursor(at: p)
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
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
            return
        }
        if mode == .area, (event.keyCode == 36 || event.keyCode == 76) { // Return / keypad Enter
            confirmAreaSelection()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        guard mode == .area else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        addCursorRect(bounds, cursor: .crosshair)
        if let selection = areaSelection {
            addCursorRect(selection, cursor: .openHand)
            for (handle, rect) in EditableSelectionGeometry.handleRects(for: selection, size: 18) {
                addCursorRect(rect, cursor: handle.cursor)
            }
        }
        if let button = captureButtonRect {
            addCursorRect(button, cursor: .pointingHand)
        }
    }

    private func updateAreaCursor(at point: CGPoint) {
        if let button = captureButtonRect, button.contains(point) {
            NSCursor.pointingHand.set()
        } else if let selection = areaSelection,
                  let handle = EditableSelectionGeometry.handle(at: point, in: selection) {
            handle.cursor.set()
        } else if let selection = areaSelection, selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func confirmAreaSelection() {
        guard let selection = areaSelection?.intersection(bounds),
              selection.width >= 4, selection.height >= 4,
              let frozen else { return }
        owner?.finish(.area(screen: screen, frozen: frozen, rect: selection))
    }
}
