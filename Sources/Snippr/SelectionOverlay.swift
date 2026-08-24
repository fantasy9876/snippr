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
    /// Area-review ran its whole flow in place (router side effects done) —
    /// the caller has nothing left to route.
    case handled
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
    /// Tests inject router spies here; production leaves it nil (= .live).
    var routerDependenciesOverride: CaptureActionRouter.Dependencies?
    /// SINGLE source of truth for "this session is over": derived from the
    /// session phase, never a separate flag — a separate bool and the phase
    /// could disagree, letting a late secondary-display capture add windows
    /// to a completed session (or a completed phase leave windows alive).
    fileprivate var finished: Bool { session.phase == .completed }

    init(
        purpose: OverlayPurpose,
        inputs: OverlaySessionInputs? = nil,
        completion: @escaping @MainActor (OverlayResult) -> Void
    ) {
        self.mode = purpose == .windowPick ? .windowPick : .area
        self.session = OverlaySession(
            purpose: purpose, inputs: inputs ?? .snapshot())
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
        guard let cursorScreen = screens.first(
            where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? screens.first
        else {
            finish(.cancelled) // screenless environment: nothing to select on
            return
        }
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
    /// Production teardown, exposed so a gate ends the session the way the app
    /// does instead of poking the surface directly.
    func dismissForTesting() { finish(.cancelled) }

    func finish(_ result: OverlayResult) {
        // Cancel BEFORE the views and `current` go away: a late result must not
        // land on a surface nobody can repaint.
        // cancelAllRedactionJobs already cancels per annotation, so calling
        // both would bump each generation twice and repaint twice.
        for view in windows.compactMap({ $0.contentView as? SelectionOverlayView }) {
            view.annotationSurface?.cancelAllRedactionJobs()
        }
        guard !tornDown else { return }
        tornDown = true
        session.forceComplete()
        for w in windows {
            if let view = w.contentView as? SelectionOverlayView {
                view.releaseSamplerCache()
                // Drops the tracking areas and anything scheduled: this window
                // is about to be ordered out from under them.
                view.hoverHint.detachAll()
            }
            w.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.arrow.set()
        if SelectionOverlay.current === self {
            SelectionOverlay.current = nil
        }
        completion(result)
    }

    /// The review began on one display's view: make its window key so
    /// keyboard shortcuts land there, and leave every other display dimmed.
    fileprivate func reviewDidBegin(in activeView: SelectionOverlayView) {
        activeView.window?.makeKeyAndOrderFront(nil)
        activeView.window?.makeFirstResponder(activeView)
    }

    /// Factory entry for UI-harness tests: builds the overlay around an
    /// injected frozen image instead of capturing displays, driving the same
    /// production windows/views/session.
    /// Factory tests MUST inject inputs and dependencies: the harness can
    /// run on a user machine, and reading live Settings or the live router
    /// could copy to the real clipboard or write real files.
    static func beginForTesting(
        purpose: OverlayPurpose,
        inputs: OverlaySessionInputs,
        frozen: CapturedImage,
        screen: NSScreen,
        dependencies: CaptureActionRouter.Dependencies,
        completion: @escaping @MainActor (OverlayResult) -> Void
    ) -> SelectionOverlay? {
        guard current == nil else { return nil }
        let overlay = SelectionOverlay(
            purpose: purpose, inputs: inputs, completion: completion)
        overlay.routerDependenciesOverride = dependencies
        current = overlay
        overlay.addOverlay(
            for: screen, frozen: frozen, windowList: [], makeKey: false)
        return overlay
    }

    var activeReviewViewForTesting: SelectionOverlayView? {
        for window in windows {
            if let view = window.contentView as? SelectionOverlayView,
               view.hasAreaSelectionForTesting {
                return view
            }
        }
        return windows.first?.contentView as? SelectionOverlayView
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

final class SelectionOverlayView: NSView, RedactionSurfaceDelegate {
    private let mode: OverlayMode
    private let screen: NSScreen
    private let frozen: CapturedImage?
    private let windowList: [WindowInfo]
    private weak var owner: SelectionOverlay?

    private enum AreaDrag {
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
    }

    private var areaSelection: CGRect?
    private var areaDrag: AreaDrag?
    /// Slice 4: shared annotation state (pixel space, absolute). Created on
    /// review begin so scale matches the frozen image.
    private(set) var annotationSurface: AnnotationSurface?
    private var annotationDragging = false
    private var textField: NSTextField?
    private var textFieldPixelOrigin: CGPoint = .zero
    private var strokeHUD: StrokePreviewView?
    private var strokeHUDHide: DispatchWorkItem?
    private var mousePos: CGPoint = .zero
    /// False after exit / screen change so Tab cannot reuse .zero or a
    /// pixel from a previous visit. Updated on enter/move/down/drag/up.
    private var pointerInside = false
    /// Last cursor this view set, written only by `applyCursor`.
    private var currentCursor: AppCursor?
    private var hoverWindow: WindowInfo?

    nonisolated(unsafe) static var frozenBlitCountForTesting = 0

    init(mode: OverlayMode, screen: NSScreen, frozen: CapturedImage?, windowList: [WindowInfo], owner: SelectionOverlay) {
        self.mode = mode
        self.screen = screen
        self.frozen = frozen
        self.windowList = windowList
        self.owner = owner
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        setupFrozenBackground()
    }

    /// The frozen display is committed to a background layer exactly ONCE;
    /// resize/drag redraws must not re-blit the full-resolution source
    /// (plan product rule #5). The spy counter proves it.
    private func setupFrozenBackground() {
        guard let frozen else { return }
        let background = CALayer()
        background.contents = frozen.cgImage
        background.contentsGravity = .resize
        background.frame = CGRect(origin: .zero, size: frame.size)
        background.zPosition = -1
        layer?.addSublayer(background)
        Self.frozenBlitCountForTesting += 1
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let frozen { PixelSamplerCache.release(frozen.cgImage) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else {
            invalidatePointer()
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(overlayScreenDidChange),
            name: NSWindow.didChangeScreenNotification,
            object: window)
    }

    @objc private func overlayScreenDidChange(_ notification: Notification) {
        invalidatePointer()
    }

    private func updatePointer(from event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        pointerInside = true
    }

    private func invalidatePointer() {
        pointerInside = false
    }

    private func pointerViewPoint() -> CGPoint? {
        pointerInside ? mousePos : nil
    }

    fileprivate func releaseSamplerCache() {
        if let frozen { PixelSamplerCache.release(frozen.cgImage) }
    }

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

    /// Reviewing = the SESSION is reviewing (or a save is in flight). Every
    /// view on every display reads the same session state.
    fileprivate var isReviewing: Bool {
        let phase = owner?.session.phase
        return phase == .reviewing || phase == .saving
    }

    /// While the Save sheet is up the WHOLE canvas is locked: no drags, no
    /// Esc/outside-click teardown, no Close — the native sheet owns
    /// cancellation and the typed callback returns the session to review.
    fileprivate var isSaving: Bool { owner?.session.phase == .saving }

    /// The session has already produced its result, or there is no session
    /// left at all. Nothing may mutate the document or the overlay after that:
    /// `finish` cancels the surfaces BEFORE its torn-down guard, so replaying
    /// a cancel bumps every redaction's generation again, and a retained
    /// button still carries a live target and action.
    fileprivate var isFinished: Bool {
        guard let owner else { return true }
        return owner.session.phase == .completed
    }

    fileprivate func handleEscape() {
        if isSaving || isFinished { return }
        if hideBackdropMini() { return }
        owner?.finish(.cancelled)
    }
    func handleEscapeForTesting() { handleEscape() }
    func handleOutsideClickForTesting() {
        if isSaving || isFinished { return }
        owner?.finish(.cancelled)
    }

    var hasAreaSelectionForTesting: Bool { areaSelection != nil }
    var areaSelectionForTesting: CGRect? { areaSelection }
    var areaDragActiveForTesting: Bool { areaDrag != nil }
    /// Which corner/edge a live mouseDown grabbed, if any. The gate that
    /// proves inset handles are wired uses this instead of re-deriving
    /// geometry: what it reads is what the user grabbed.
    var areaDragHandleForTesting: SelectionHandle? {
        if case .resizing(let handle, _) = areaDrag { return handle }
        return nil
    }
    /// The cursor production last put on screen — not a re-derivation. The
    /// gate drives real mouse events and reads this, so it fails if the
    /// (tool, hit) table stops being wired into the event handlers even
    /// though the table itself is still right.
    var currentCursorForTesting: AppCursor? { currentCursor }
    var isAnnotationDraggingForTesting: Bool { annotationDragging }
    var isReviewingForTesting: Bool { isReviewing }
    var reviewToolbarFrameForTesting: CGRect? {
        let frames = [reviewToolRail, reviewActionBar].compactMap { view in
            view?.isHidden == false ? view?.frame : nil
        }
        guard var result = frames.first else { return nil }
        for frame in frames.dropFirst() { result = result.union(frame) }
        return result
    }
    /// The hint catalog — see the panel's seam: `toolTip` is deliberately nil
    /// on every button the hint watches.
    var reviewToolbarButtonsForTesting: [(tag: Int, tooltip: String)] {
        toolbarButtons.map {
            ($0.tag, hoverHint.textForTesting($0) ?? "")
        }
    }
    var nativeTooltipsForTesting: [String?] {
        toolbarButtons.map(\.toolTip)
    }
    var reviewToolbarButtonFramesForTesting: [CGRect] {
        toolbarButtons.map { $0.convert($0.bounds, to: self) }
    }
    /// Drives a real drag through the production mouse handlers of this view,
    /// so a gate can create an annotation the way a user does.
    /// A drag that stops between the drag and the release, so a gate can run
    /// the real routes while the mouse is still down and then finish.
    func annotationDragForTesting(
        from a: CGPoint, to b: CGPoint, whileDown: (() -> Void)? = nil
    ) {
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: convert(p, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, a) { mouseDown(with: down) }
        if let drag = event(.leftMouseDragged, b) { mouseDragged(with: drag) }
        whileDown?()
        if let up = event(.leftMouseUp, b) { mouseUp(with: up) }
    }

    func clickReviewToolbarButtonForTesting(tag: Int) {
        toolbarButtons.first { $0.tag == tag }?.performClick(nil)
    }

    /// Test hook: runs the production selection→commit path without raw
    /// mouse plumbing (QA prefers small state hooks over synthesized clicks).
    /// The surface repaints this view when a redaction resolves.
    func surfaceNeedsRedactionRepaint() { needsDisplay = true }

    func selectForTesting(rect: CGRect) {
        owner?.areaSelectionDidBegin(in: self)
        areaSelection = rect
        commitInitialSelection(rect)
        needsDisplay = true
    }

    func performReviewActionForTesting(_ intent: CaptureIntent) {
        performReviewAction(intent)
    }

    /// Test hook: a review-phase resize/move lands on this exact production
    /// path (selection + pixel-rect + toolbar relayout).
    func adjustSelectionForTesting(rect: CGRect) {
        guard isReviewing else { return }
        areaSelection = rect
        syncSessionPixelRect()
        layoutReviewToolbar()
        needsDisplay = true
    }

    // MARK: Review toolbar

    private var reviewToolRail: NSView?
    private var reviewActionBar: NSView?
    private var toolToolbarButtons: [NSButton] = []
    private var actionToolbarButtons: [NSButton] = []
    private var toolbarButtons: [NSButton] = []
    private var backdropMini: OverlayBackdropMiniView?
    let hoverHint = HoverHint()

    private static let colorPresets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .black, .white,
    ]
    private var colorIndex = 0

    private func makeReviewToolbarContainer() -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 8
        return container
    }

    private func makeReviewToolbarButton(
        symbol: String, tooltip: String, tag: Int, tint: NSColor
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = SliceBSymbols.image(
            named: symbol, fallback: "questionmark.square.dashed")
        button.contentTintColor = tint
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.tag = tag
        button.target = self
        button.action = #selector(reviewToolbarButtonPressed(_:))
        return button
    }

    private func buildReviewToolbars() -> (tool: NSView, action: NSView) {
        let toolContainer = makeReviewToolbarContainer()
        let actionContainer = makeReviewToolbarContainer()
        var toolButtons: [NSButton] = []
        for tool in OverlayAnnotationTool.areaReviewTools {
            let button = makeReviewToolbarButton(
                symbol: tool.symbol, tooltip: tool.tooltip,
                tag: tool.toolbarTag,
                tint: tool == .select ? .controlAccentColor : .white)
            toolContainer.addSubview(button)
            toolButtons.append(button)
        }
        // A document style, so it opens the preset menu instead of entering a
        // drawing mode — the same shape the editor's Backdrop button has. It
        // sits with the tools, next to the magnifier, not with the pickers.
        let backdropButton = makeReviewToolbarButton(
            symbol: "photo.artframe", tooltip: "Backdrop (D)",
            tag: OverlayAnnotationTool.backdropToolbarTag,
            tint: backdropTint)
        toolContainer.addSubview(backdropButton)
        toolButtons.append(backdropButton)
        let colorButton = makeReviewToolbarButton(
            symbol: "circle.fill", tooltip: "Color",
            tag: OverlayAnnotationTool.colorToolbarTag,
            tint: Self.colorPresets[colorIndex])
        toolContainer.addSubview(colorButton)
        toolButtons.append(colorButton)
        let undoButton = makeReviewToolbarButton(
            symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)",
            tag: OverlayAnnotationTool.undoToolbarTag, tint: .white)
        toolContainer.addSubview(undoButton)
        toolButtons.append(undoButton)
        let redoButton = makeReviewToolbarButton(
            symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)",
            tag: OverlayAnnotationTool.redoToolbarTag, tint: .white)
        toolContainer.addSubview(redoButton)
        toolButtons.append(redoButton)

        var actionButtons: [NSButton] = []
        for (index, item) in OverlayActionCatalog.items.enumerated() {
            let button = makeReviewToolbarButton(
                symbol: item.symbol, tooltip: item.tooltip,
                tag: index, tint: .white)
            actionContainer.addSubview(button)
            actionButtons.append(button)
        }
        let close = makeReviewToolbarButton(
            symbol: "xmark", tooltip: "Close (Esc)", tag: -1, tint: .white)
        actionContainer.addSubview(close)
        actionButtons.append(close)

        toolToolbarButtons = toolButtons
        actionToolbarButtons = actionButtons
        toolbarButtons = toolButtons + actionButtons
        // AppKit's own tooltips never appear here: this window deliberately
        // never activates, and NSToolTipManager only serves the active app.
        hoverHint.attach(to: toolbarButtons)
        return (toolContainer, actionContainer)
    }

    /// Annotation controls form a wrapped vertical rail beside the crop;
    /// terminal actions form a wrapped horizontal strip below it. Each group
    /// flips independently at an edge and falls inside only when an outside
    /// placement is impossible. They remain separate siblings so the empty
    /// space between an L-shaped layout never intercepts canvas input.
    fileprivate func layoutReviewToolbar() {
        guard isReviewing, let selection = areaSelection else {
            reviewToolRail?.isHidden = true
            reviewActionBar?.isHidden = true
            hideBackdropMini()
            return
        }
        let toolRail: NSView
        let actionBar: NSView
        if let existingTool = reviewToolRail,
           let existingAction = reviewActionBar {
            toolRail = existingTool
            actionBar = existingAction
        } else {
            let built = buildReviewToolbars()
            toolRail = built.tool
            actionBar = built.action
            addSubview(toolRail)
            addSubview(actionBar)
            reviewToolRail = toolRail
            reviewActionBar = actionBar
        }
        guard let layout = OverlayToolbarLayout.area(
            selection: selection, bounds: bounds,
            toolCount: toolToolbarButtons.count,
            actionCount: actionToolbarButtons.count)
        else {
            toolRail.isHidden = true
            actionBar.isHidden = true
            return
        }
        toolRail.isHidden = false
        actionBar.isHidden = false
        toolRail.frame = layout.toolFrame
        actionBar.frame = layout.actionFrame
        for (button, frame) in zip(
            toolToolbarButtons, layout.toolButtonFramesLocal) {
            button.frame = frame
        }
        for (button, frame) in zip(
            actionToolbarButtons, layout.actionButtonFramesLocal) {
            button.frame = frame
        }
        // ALL buttons (Close included) lock while a save is in flight.
        let enabled = owner?.session.acceptsCommits ?? false
        for button in toolbarButtons { button.isEnabled = enabled }
        updateHistoryButtons()
        layoutBackdropMini()
    }

    private func updateHistoryButtons() {
        let unlocked = owner?.session.phase == .reviewing
        for button in toolbarButtons {
            switch button.tag {
            case OverlayAnnotationTool.undoToolbarTag:
                button.isEnabled = unlocked && (annotationSurface?.canUndo ?? false)
            case OverlayAnnotationTool.redoToolbarTag:
                button.isEnabled = unlocked && (annotationSurface?.canRedo ?? false)
            default:
                break
            }
        }
    }

    private func selectAnnotationTool(_ tool: OverlayAnnotationTool) {
        // The authoritative selection point: keyboard, toolbar, accessibility
        // and programmatic routes all land here, so dismissing the hint in the
        // click handler alone would leave a hint describing the OLD tool on
        // screen after a keyboard switch.
        hoverHint.hide()
        annotationSurface?.tool = tool
        for button in toolbarButtons
            where OverlayAnnotationTool.tool(forToolbarTag: button.tag) != nil {
            button.contentTintColor =
                button.tag == tool.toolbarTag ? .controlAccentColor : .white
        }
        if tool != .text { endTextEntry(commit: true) }
        // The pointer answers to the tool, so it changes with the tool —
        // waiting for the next mouseMoved leaves the OLD tool's cursor on
        // screen over a canvas that now does something else.
        window?.invalidateCursorRects(for: self)
        if pointerInside { updateAreaCursor(at: mousePos) }
    }

    // MARK: Backdrop

    private var backdropStyle: BackdropStyle {
        annotationSurface?.backdropStyle ?? .none
    }
    private var backdropPreset: BackdropPreset {
        annotationSurface?.backdropPreset ?? .none
    }
    private var backdropTint: NSColor {
        backdropStyle.kind == .none ? .white : .controlAccentColor
    }

    /// Overlay preview/export follow the live Settings corner the way the
    /// v0 menu did: handles, clip and plate must agree, and a gate that
    /// flips `Settings.backdropCornerStyle` after applying Ocean still
    /// probes the large radius.
    private var overlayDrawStyle: BackdropStyle {
        var s = backdropStyle
        s.cornerStyle = SliceBBackdrop.cornerStyle
        return s
    }

    /// Built separately from being shown, same policy as the editor sidebar:
    /// opening changes nothing, only choosing a control applies a style.
    private func makeBackdropMini() -> OverlayBackdropMiniView {
        let mini = OverlayBackdropMiniView(
            frame: CGRect(origin: .zero, size: OverlayQuickBackdrop.size))
        mini.isHidden = true
        mini.onChoose = { [weak self] style in
            _ = self?.applyBackdropStyle(style)
        }
        mini.onOpenEditor = { [weak self] in
            self?.openBackdropEditor()
        }
        mini.onOpenEditorHover = { [weak self] hovered in
            guard let self else { return }
            if hovered {
                self.applyCursor(.pointingHand)
            } else {
                self.applyCursor(self.areaCursor(at: self.mousePos))
            }
        }
        return mini
    }

    @discardableResult
    private func hideBackdropMini() -> Bool {
        guard let mini = backdropMini, !mini.isHidden else { return false }
        mini.isHidden = true
        return true
    }

    private func showBackdropMini(from sender: NSButton) {
        hoverHint.hide()
        if backdropMini == nil {
            let mini = makeBackdropMini()
            addSubview(mini, positioned: .above, relativeTo: nil)
            backdropMini = mini
            hoverHint.attach(to: mini.hintButtons)
        }
        guard let mini = backdropMini else { return }
        if !mini.isHidden {
            hideBackdropMini()
            return
        }
        if backdropStyle.kind == .none,
           let last = Settings.shared.backdropLastStyle, last.kind != .none {
            mini.sync(style: last)
        } else {
            mini.sync(style: backdropStyle)
        }
        mini.isHidden = false
        layoutBackdropMini()
    }

    private func layoutBackdropMini() {
        guard let mini = backdropMini, !mini.isHidden else { return }
        guard isReviewing, let selection = areaSelection,
              let button = toolbarButtons.first(where: {
                  $0.tag == OverlayAnnotationTool.backdropToolbarTag
              })
        else {
            mini.isHidden = true
            return
        }
        let size = OverlayQuickBackdrop.size
        let anchor = button.convert(button.bounds, to: self)
        let occupied = [reviewToolRail, reviewActionBar].compactMap { bar in
            bar.flatMap { $0.isHidden ? nil : $0.frame }
        }
        if let placed = OverlayToolbarLayout.popover(
            size: size, anchor: anchor, avoid: selection, bounds: bounds,
            occupied: occupied)
        {
            mini.frame = placed.frame
            mini.isHidden = false
        } else {
            mini.isHidden = true
        }
    }

    func showBackdropMiniForTesting() {
        guard let button = toolbarButtons.first(where: {
            $0.tag == OverlayAnnotationTool.backdropToolbarTag
        }) else { return }
        if backdropMini?.isHidden == false { return }
        showBackdropMini(from: button)
    }

    var backdropMiniIsShownForTesting: Bool {
        backdropMini?.isHidden == false
    }

    var backdropMiniFrameForTesting: CGRect? {
        guard let mini = backdropMini, !mini.isHidden else { return nil }
        return mini.frame
    }

    func backdropMiniControlForTesting(_ identifier: String) -> NSButton? {
        backdropMini?.control(identifier: identifier)
    }

    var backdropMiniViewForTesting: OverlayBackdropMiniView? {
        guard let mini = backdropMini, !mini.isHidden else { return nil }
        return mini
    }

    func openBackdropEditorForTesting() { openBackdropEditor() }

    @discardableResult
    func applyBackdropStyle(_ style: BackdropStyle) -> Bool {
        guard owner?.session.phase == .reviewing, let surface = annotationSurface
        else { return false }
        guard !annotationDragging, areaDrag == nil else { return false }
        let next = style.clamped()
        guard next.kind == .none || backdropPeakFits(next) else {
            ToastHUD.show(
                "Vùng chọn quá lớn cho Backdrop",
                symbol: "exclamationmark.triangle.fill",
                on: window?.screen ?? screen, above: window?.level)
            return false
        }
        guard surface.applyBackdropStyle(next) else { return false }
        Settings.shared.rememberBackdropStyle(next)
        refreshBackdropButton()
        backdropMini?.sync(style: surface.backdropStyle)
        updateTextEntryClip()
        needsDisplay = true
        return true
    }

    @discardableResult
    func applyBackdropPreset(_ preset: BackdropPreset) -> Bool {
        applyBackdropStyle(.from(preset: preset))
    }

    /// Mirrors the editor's peak arithmetic exactly: reserve what the outer
    /// frame will need, then ask whether the inner render still fits in what
    /// is left. Both buffers are alive during a compose.
    private func backdropPeakFits(_ style: BackdropStyle) -> Bool {
        guard let frozen else { return false }
        let width = frozen.cgImage.width
        let height = frozen.cgImage.height
        let reserve = SliceBBackdrop.reservedBytes(
            forInnerWidth: width, height: height, style: style,
            pixelScale: frozen.scale)
        guard let innerBudget = SliceBExport.budget(
            SliceBExport.defaultBudgetBytes, minus: reserve),
            let innerBytes = SliceBExport.byteCount(
                width: width, height: height)
        else { return false }
        return innerBytes <= innerBudget
    }

    /// Popover "Open in Editor…": the crop plus overlay marks as the
    /// document, the current overlay style as live Backdrop state. Baking
    /// the frame first would put a second plate around it the moment the
    /// sidebar changed padding. Spotlight dim is compose-once global
    /// state, not a local mark — flatten everything except the holes and
    /// hand the live annotations to the editor so a second hole cannot
    /// stack darkness. Copy/Save/OCR still bake through `reviewPayload`.
    /// The toolbar's macwindow action still sends the composed picture —
    /// that path has no document to carry a style.
    private func openBackdropEditor() {
        hoverHint.hide()
        guard !annotationDragging, areaDrag == nil else { return }
        guard let owner, owner.session.acceptsCommits,
              let selection = areaSelection?.intersection(bounds),
              selection.width >= 4, selection.height >= 4,
              let frozen
        else { return }
        let prospectiveText = prospectiveTextAnnotation()
        let canonical = syncSessionPixelRect() ?? selection
        func payloadFailed() {
            let message = lastPayloadFailure == .backdrop
                ? "Không dựng được nền Backdrop — thử preset khác"
                : "Không xuất được ảnh có nét vẽ — thử lại"
            if let toast = owner.routerDependenciesOverride?.toast {
                toast(message)
            } else {
                ToastHUD.show(
                    message, on: window?.screen ?? screen, above: window?.level)
            }
        }
        guard let payload = reviewPayload(prospectiveText: prospectiveText)
        else { payloadFailed(); return }
        guard let editorPayload = reviewPayload(
            prospectiveText: prospectiveText, omittingSpotlights: true)
        else { payloadFailed(); return }
        let handoff = SpotlightAnnotation.handoffForCroppedEditor(
            from: annotationSurface?.annotations ?? [],
            cropPixels: owner.session.pixelRect,
            imageHeight: CGFloat(frozen.cgImage.height))
        endTextEntry(commit: true)
        hideBackdropMini()
        var passStyle: BackdropStyle? = overlayDrawStyle
        if passStyle?.kind == .none { passStyle = nil }
        let global = globalRect(for: canonical)
        owner.finish(.handled)
        // One payload, both seams: a test spy and production live receive
        // the same unbaked crop + live holes + backdrop. Splitting this
        // let the 1.2.14 bake regress under a green gate.
        let editorHandoff = EditorHandoff(
            image: editorPayload.semantic,
            annotations: handoff,
            backdrop: passStyle,
            openPanel: true)
        let deps = owner.routerDependenciesOverride ?? .live
        deps.setLastCapture(payload.visual)
        deps.setLastAreaRect(global)
        deps.openEditor(editorHandoff)
    }

    /// Clips the live caption to the crop the export will produce — rounded
    /// when a frame is on, square when it is not.
    ///
    /// The overlay draws its own content clipped, but a text field is a
    /// SUBVIEW and ignores that entirely: without this a caption typed near a
    /// corner shows on screen and is missing from the export, the same
    /// mismatch the editor had. The mask lives on the field, so nothing that
    /// is drawn or magnified gets rasterized.
    fileprivate func updateTextEntryClip() {
        guard let field = textField else { return }
        let plate = backdropPreviewGeometry()?.0 ?? areaSelection
        guard let plate else {
            field.layer?.mask = nil
            return
        }
        field.wantsLayer = true
        let radius = backdropStyle.kind == .none
            ? 0
            : SliceBBackdrop.cornerRadius(
                documentPoints: plate.size, style: SliceBBackdrop.cornerStyle)
        let mask = (field.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = field.bounds
        mask.path = CGPath(
            roundedRect: convert(plate, to: field),
            cornerWidth: radius, cornerHeight: radius, transform: nil)
        mask.contentsScale = window?.backingScaleFactor ?? 2
        field.layer?.mask = mask
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving between a 1x and a 2x display changes the backing scale
        // without changing anything else, and a mask rendered for the old
        // scale stays stepped until something else happens to touch it.
        updateTextEntryClip()
    }

    private func refreshBackdropButton() {
        for button in toolbarButtons
        where button.tag == OverlayAnnotationTool.backdropToolbarTag {
            button.contentTintColor = backdropTint
        }
        // Same reason as the editor's document view: what is reviewed has to
        // live in the space the export is composed in, or a P3 display shows
        // colours the framed export has already clipped.
        window?.colorSpace = backdropStyle.kind == .none ? nil : .sRGB
    }

    private func performHistoryAction(redo: Bool) {
        guard owner?.session.phase == .reviewing,
              let surface = annotationSurface else { return }
        let changed = redo ? surface.redo() : surface.undo()
        if changed {
            // Undo/redo can move the preset — it lives in the same timeline.
            refreshBackdropButton()
            updateTextEntryClip()
            needsDisplay = true
        }
    }

    @objc private func reviewToolbarButtonPressed(_ sender: NSButton) {
        hoverHint.hide()
        if isSaving || isFinished { return }
        // The same rule the keyboard follows. A toolbar click, an
        // accessibility action or any programmatic route reaches this method
        // without passing a key handler, so the guard belongs here too. A crop
        // drag counts: it is mid-transaction just as an annotation drag is.
        if annotationDragging || areaDrag != nil { return }
        if sender.tag == -1 {
            owner?.finish(.cancelled)
            return
        }
        if let tool = OverlayAnnotationTool.tool(forToolbarTag: sender.tag) {
            selectAnnotationTool(tool)
            return
        }
        if sender.tag == OverlayAnnotationTool.colorToolbarTag {
            colorIndex = (colorIndex + 1) % Self.colorPresets.count
            annotationSurface?.color = Self.colorPresets[colorIndex]
            sender.contentTintColor = Self.colorPresets[colorIndex]
            return
        }
        if sender.tag == OverlayAnnotationTool.undoToolbarTag {
            performHistoryAction(redo: false)
            return
        }
        if sender.tag == OverlayAnnotationTool.redoToolbarTag {
            performHistoryAction(redo: true)
            return
        }
        if sender.tag == OverlayAnnotationTool.backdropToolbarTag {
            showBackdropMini(from: sender)
            return
        }
        guard sender.tag >= 0,
              sender.tag < OverlayActionCatalog.items.count else { return }
        performReviewAction(OverlayActionCatalog.items[sender.tag].intent)
    }

    /// One review intention = one router commit with the CURRENT crop.
    /// Terminal lifecycle per QA: Copy commits then closes; Pin/OCR/editor
    /// tear the overlay down BEFORE presenting; Save keeps the overlay in
    /// `.saving` and returns to review on cancel/failure.
    fileprivate func performReviewAction(_ intent: CaptureIntent) {
        hoverHint.hide()
        guard !annotationDragging, areaDrag == nil else { return }
        guard let owner, owner.session.acceptsCommits,
              let selection = areaSelection?.intersection(bounds),
              selection.width >= 4, selection.height >= 4,
              frozen != nil
        else { return }
        // A terminal click must never race the in-flight text entry: the typed
        // text has to reach the export without the user pressing Return first.
        // It is rendered as a PROSPECTIVE annotation rather than committed
        // here, because a compose that fails afterwards must leave the field
        // exactly as the user left it — committing first would add the text
        // and fork the redo branch for an action that never ran.
        let prospectiveText = prospectiveTextAnnotation()
        // The rect AFTER quantization: what the router is told the capture
        // covers has to be the crop that was actually exported.
        let canonical = syncSessionPixelRect() ?? selection
        guard let payload = reviewPayload(prospectiveText: prospectiveText)
        else {
            // fail-closed like the panel: keep review + drawings, tell the
            // user, run NO action. Nothing above this line mutated anything.
            let message = lastPayloadFailure == .backdrop
                ? "Không dựng được nền Backdrop — thử preset khác"
                : "Không xuất được ảnh có nét vẽ — thử lại"
            if let toast = owner.routerDependenciesOverride?.toast {
                toast(message)
            } else {
                // the overlay is live at .screenSaver on THIS screen — a
                // default .statusBar toast would be invisible behind it
                ToastHUD.show(
                    message, on: window?.screen ?? screen, above: window?.level)
            }
            return
        }
        // BOTH payloads exist: only now does the document change.
        endTextEntry(commit: true)
        // OCR and Translate read the DOCUMENT: a decorative frame adds no text
        // and would shift every recognized box off the source. Everything that
        // produces a picture gets the composed one.
        let decorated = Self.usesDecoration(intent)
        let snapshot = decorated ? payload.visual : payload.semantic
        // OCR/Translate consume the crop but the app still remembers the
        // framed picture, so Repeat/pin/editor pick up what the user saw.
        let lastCaptureOverride = decorated ? nil : payload.visual
        let global = globalRect(for: canonical)
        let inputs = owner.session.inputs

        let baseDependencies = owner.routerDependenciesOverride

        switch intent {
        case .copy:
            CaptureActionRouter.commit(
                snapshot, source: .areaReview, intent: .copy,
                inputs: inputs, finalGlobalRect: global,
                dependencies: baseDependencies)
            owner.finish(.handled)
        case .save:
            // The snapshot above already succeeded, so freezing the document
            // here is safe; a failed render returned earlier with the jobs
            // still alive. Cancel BEFORE entering .saving and showing the sheet.
            annotationSurface?.cancelAllRedactionJobs()
            guard owner.session.transition(to: .saving) else { return }
            layoutReviewToolbar() // disable buttons while the panel is up
            // The panel must attach to the overlay window as a sheet — a
            // detached panel would sit BEHIND the .screenSaver-level overlay.
            var dependencies = baseDependencies ?? .live
            if baseDependencies == nil {
                let hostWindow = window
                dependencies.saveAs = { image, done in
                    SaveService.shared.saveAs(image, for: hostWindow, completion: done)
                }
            }
            CaptureActionRouter.commit(
                snapshot, source: .areaReview, intent: .save,
                inputs: inputs, finalGlobalRect: global,
                dependencies: dependencies,
                resolution: { [weak owner, weak self] outcome in
                    guard let owner else { return }
                    if outcome == .completed {
                        owner.finish(.handled)
                    } else {
                        owner.session.transition(to: .reviewing)
                        self?.layoutReviewToolbar()
                    }
                })
        case .pin, .ocr, .translate, .openEditor:
            // teardown BEFORE presenting so the .screenSaver-level overlay
            // can't cover the new surface
            owner.finish(.handled)
            CaptureActionRouter.commit(
                snapshot, source: .areaReview, intent: intent,
                inputs: inputs, finalGlobalRect: global,
                dependencies: baseDependencies,
                lastCaptureOverride: lastCaptureOverride)
        case .initialCapture, .scrollFinished:
            break
        }
    }

    fileprivate func clearAreaSelection() {
        guard areaSelection != nil else { return }
        areaSelection = nil
        areaDrag = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    /// Independent evidence that production drawing really ran during a gate's
    /// snapshot, rather than a cached layer being handed back.
    private(set) var drawCallsForTesting = 0

    override func draw(_ dirtyRect: NSRect) {
        drawCallsForTesting += 1
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The frozen screen lives in the cached background layer set up
        // once in setupFrozenBackground() — redraws here only paint the
        // dim/frame/handles, never the 5K source again.

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

        // The frame goes down BEFORE the marks and BEFORE anything reads the
        // frozen background: it paints over the raw screen inside the crop as
        // well as around it, and the crop is then redrawn through the rounded
        // clip. Drawing only the surround would leave the four corner cutouts
        // showing raw pixels the export has replaced with gradient.
        let backdropClip = drawBackdropPreview(in: ctx)

        if let surface = annotationSurface, !surface.isEmpty,
           let sel = areaSelection, let frozen {
            let scale = frozen.scale
            ctx.saveGState()
            if let backdropClip {
                ctx.addPath(backdropClip)
                ctx.clip()
            } else {
                ctx.clip(to: sel)
            }
            ctx.scaleBy(x: 1 / scale, y: 1 / scale)
            // The crop the export will make, in bottom-left image pixels: the
            // session's rect is top-left because it indexes the frozen image.
            let px = owner?.session.pixelRect ?? .zero
            let visibleBL = px.width >= 1 && px.height >= 1
                ? CGRect(
                    x: px.minX,
                    y: CGFloat(frozen.cgImage.height) - px.maxY,
                    width: px.width, height: px.height)
                : nil
            surface.drawForPreview(
                in: ctx, base: frozen.cgImage, visiblePixels: visibleBL)
            ctx.restoreGState()
        }

        // The same hairline compose draws, at the same point in the order:
        // after the document AND its marks, inside the plate's clip, and
        // BEFORE any review chrome — the selection border and handles are
        // overlay furniture the export never sees.
        if let backdropClip, let (plate, _) = backdropPreviewGeometry() {
            ctx.saveGState()
            ctx.addPath(backdropClip)
            ctx.clip()
            SliceBBackdrop.drawPlateHairline(
                in: ctx, rect: plate, pixelScale: 1)
            ctx.restoreGState()
        }

        let accent = NSColor.controlAccentColor

        if let sel = areaSelection {
            // border
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel.insetBy(dx: -0.75, dy: -0.75))
            drawSelectionHandles(for: sel, in: ctx)
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

    /// Draws the framed document the export will produce, in view points,
    /// and returns the rounded path the crop's own content must be clipped to.
    /// Returns nil when there is no frame, so callers keep their square clip.
    ///
    /// Geometry comes from `BackdropLayout` — the same type the editor,
    /// the fit, the size badge and the export read — so what the user reviews
    /// here cannot drift from what compose emits.
    @discardableResult
    private func drawBackdropPreview(in ctx: CGContext) -> CGPath? {
        guard isReviewing, overlayDrawStyle.kind != .none,
              let (sel, layout) = backdropPreviewGeometry() else { return nil }
        guard let frozen else { return nil }
        let scale = frozen.scale
        let pad = layout.padPoints
        let outer = sel.insetBy(dx: -pad, dy: -pad)
        let radius = SliceBBackdrop.cornerRadius(
            documentPoints: sel.size, style: SliceBBackdrop.cornerStyle)
        let rounded = CGPath(
            roundedRect: sel, cornerWidth: radius, cornerHeight: radius,
            transform: nil)

        ctx.saveGState()
        // Confined to the frame's own rect: drawFrame fills the whole context
        // it is handed, which here is the entire screen.
        ctx.clip(to: outer)
        ctx.translateBy(x: outer.minX, y: outer.minY)
        // POINTS, so pixelScale is 1: the radius and shadow are point metrics
        // and compose applies the document scale to the same numbers.
        SliceBBackdrop.drawFrame(
            in: ctx, size: outer.size,
            target: CGRect(
                origin: CGPoint(x: pad, y: pad), size: sel.size),
            style: overlayDrawStyle, pixelScale: 1,
            // Grain period is fixed in document pixels; this context is in
            // points, so it has to be told the document's scale.
            documentPixelsPerUserUnit: scale)
        ctx.restoreGState()

        // The frame just covered the crop as well; put the document back
        // through the same rounded clip the composed image uses.
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(
            frozen.cgImage,
            in: CGRect(origin: .zero, size: CGSize(
                width: CGFloat(frozen.cgImage.width) / scale,
                height: CGFloat(frozen.cgImage.height) / scale)))
        ctx.restoreGState()
        return rounded
    }

    /// The rect the preview frames, and its layout — both derived from the
    /// SAME pixel authority the export crops by.
    ///
    /// `areaSelection` is fractional and moves with the pointer; the payload
    /// crops by `session.pixelRect`, which is that selection quantized ONCE.
    /// Deriving the preview from the fractional rect put the frame's padding,
    /// its grain phase and its hairline half a point away from the exported
    /// ones at scale 2 — a preview that disagrees with the export is the exact
    /// failure this whole slice is meant to close.
    private func backdropPreviewGeometry() -> (CGRect, BackdropLayout)? {
        guard let owner, let frozen else { return nil }
        let px = owner.session.pixelRect
        guard px.width >= 1, px.height >= 1 else { return nil }
        let scale = frozen.scale
        let layout = BackdropLayout(
            innerPixels: px.size, pixelScale: scale,
            style: overlayDrawStyle)
        guard !layout.isCollapsed else { return nil }
        // Pixel rect -> view points. The pixel rect is TOP-left origin (it
        // indexes the frozen image); the view is bottom-left.
        let imageHeightPoints = CGFloat(frozen.cgImage.height) / scale
        let rect = CGRect(
            x: px.minX / scale,
            y: imageHeightPoints - px.maxY / scale,
            width: px.width / scale, height: px.height / scale)
        return (rect, layout)
    }

    /// Gate visibility: the exact outer rect the preview draws, in view
    /// points, so a gate can prove preview and export agree on geometry.
    var backdropPreviewOuterRectForTesting: CGRect? {
        guard overlayDrawStyle.kind != .none,
              let (sel, layout) = backdropPreviewGeometry() else { return nil }
        return sel.insetBy(dx: -layout.padPoints, dy: -layout.padPoints)
    }

    /// Radius the plate actually draws. No plate (or style None) keeps the
    /// handles on the geometric corners — same as capture, which has no
    /// preset yet.
    private func reviewCornerRadius(for rect: CGRect) -> CGFloat {
        guard isReviewing, overlayDrawStyle.kind != .none else { return 0 }
        return SliceBBackdrop.cornerRadius(
            documentPoints: rect.size, style: SliceBBackdrop.cornerStyle)
    }

    private func drawSelectionHandles(for rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for (_, handleRect) in EditableSelectionGeometry.handleRects(
            for: rect,
            cornerRadius: reviewCornerRadius(for: rect),
            shrinkToArc: true
        ) {
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

    private func showStrokeHUD(width: CGFloat, color: NSColor) {
        let hud: StrokePreviewView
        if let existing = strokeHUD {
            hud = existing
        } else {
            hud = StrokePreviewView(
                frame: CGRect(x: 0, y: 0, width: 190, height: 44))
            addSubview(hud, positioned: .above, relativeTo: nil)
            strokeHUD = hud
        }
        hud.strokeWidth = width
        hud.color = color
        let anchor = areaSelection ?? bounds
        let margin: CGFloat = 8
        let maxX = max(bounds.minX + margin,
                       bounds.maxX - hud.frame.width - margin)
        let maxY = max(bounds.minY + margin,
                       bounds.maxY - hud.frame.height - margin)
        hud.frame.origin = CGPoint(
            x: min(max(anchor.midX - hud.frame.width / 2,
                       bounds.minX + margin), maxX),
            y: min(max(anchor.minY + 16, bounds.minY + margin), maxY))
        hud.isHidden = false
        hud.needsDisplay = true
        strokeHUDHide?.cancel()
        let work = DispatchWorkItem { [weak hud] in hud?.isHidden = true }
        strokeHUDHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    override func scrollWheel(with event: NSEvent) {
        guard mode == .area else {
            super.scrollWheel(with: event)
            return
        }
        // Ownership FIRST, before the surface is unwrapped. During the initial
        // crop creation there is no annotation surface yet, so unwrapping
        // first sent the event to super — the one drag where the wheel was
        // still getting through — and a retained finished view would forward
        // it as well.
        if isSaving || isFinished || annotationDragging || areaDrag != nil {
            annotationSurface?.resetStrokeScrollAccumulator()
            return
        }
        guard let surface = annotationSurface else {
            super.scrollWheel(with: event)
            return
        }
        guard owner?.session.phase == .reviewing,
              !textEditingActive,
              surface.adjustsStrokeWidth
        else {
            surface.resetStrokeScrollAccumulator()
            super.scrollWheel(with: event)
            return
        }
        let mods = event.modifierFlags
        if mods.contains(.command) || mods.contains(.control)
            || mods.contains(.shift) {
            super.scrollWheel(with: event)
            return
        }
        if let changed = surface.adjustStrokeWidthForScroll(
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas) {
            showStrokeHUD(width: changed.width, color: changed.color)
        }
        // Eligible tools consume even a sub-threshold precise gesture.
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(from: event)
        if mode == .windowPick {
            updateHover(at: mousePos)
        } else {
            updateAreaCursor(at: mousePos)
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        invalidatePointer()
    }

    override func mouseDown(with event: NSEvent) {
        hoverHint.hide()
        updatePointer(from: event)
        let p = convert(event.locationInWindow, from: nil)
        guard mode == .area else { return }
        // Same rule as the drag: once the session has produced its result,
        // a click can start nothing.
        if isSaving || isFinished { return }
        if let mini = backdropMini, !mini.isHidden {
            if mini.frame.contains(p) { return }
            hideBackdropMini()
            return
        }
        if textEditingActive {
            // While the text field is first responder, a click on the canvas
            // must NOT move/resize the frame or cancel the session — the
            // field and the responder chain own the interaction until the
            // entry commits or cancels (plan: click-outside closes the
            // overlay, but never while a text field is active).
            return
        }

        if event.clickCount >= 2, isReviewing, !textEditingActive,
           let selection = areaSelection, selection.contains(p) {
            // double-click in the frame = Copy and close, regardless of the
            // active drawing tool (QA invariant 5; terminal wins over tools)
            performReviewAction(.copy)
            return
        }
        if isReviewing, !textEditingActive,
           let surface = annotationSurface, surface.tool != .select,
           let selection = areaSelection, selection.contains(p) {
            // active drawing tool: drag = draw, click (text) = place field
            if surface.tool == .text {
                beginTextEntry(atView: p)
                return
            }
            if surface.beginDrag(atPixel: pixelPoint(fromView: p)) {
                annotationDragging = true
                needsDisplay = true
                return
            }
        }
        if let selection = areaSelection,
           let handle = EditableSelectionGeometry.handle(
            at: p, in: selection,
            cornerRadius: reviewCornerRadius(for: selection)
           ) {
            areaDrag = .resizing(handle: handle, original: selection)
            applyCursor(.resize(handle))
            return
        }
        if let selection = areaSelection, selection.contains(p) {
            areaDrag = .moving(start: p, original: selection)
            applyCursor(.closedHand)
            return
        }
        if isReviewing {
            // click outside the frame during review = cancel (Lightshot)
            owner?.finish(.cancelled)
            return
        }

        owner?.areaSelectionDidBegin(in: self)
        let clamped = EditableSelectionGeometry.clampedPoint(p, to: bounds)
        areaSelection = CGRect(origin: clamped, size: .zero)
        areaDrag = .creating(anchor: clamped)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updatePointer(from: event)
        guard mode == .area else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Once the document is frozen — finished, or handed off and saving —
        // a drag in flight is ABANDONED rather than continued. Carrying on
        // would keep adding pen points, or resizing a shape, on a document
        // that has already been exported.
        if isFinished || isSaving {
            if annotationDragging {
                annotationSurface?.abandonDrag()
                annotationDragging = false
            }
            areaDrag = nil
            needsDisplay = true
            return
        }
        if annotationDragging {
            annotationSurface?.continueDrag(toPixel: pixelPoint(fromView: p))
            needsDisplay = true
            return
        }
        var adjustedReviewCrop = false
        switch areaDrag {
        case .creating(let anchor):
            areaSelection = EditableSelectionGeometry.rect(from: anchor, to: p, within: bounds)
        case .moving(let start, let original):
            areaSelection = EditableSelectionGeometry.moved(
                original,
                by: CGPoint(x: p.x - start.x, y: p.y - start.y),
                within: bounds
            )
            adjustedReviewCrop = true
        case .resizing(let handle, let original):
            areaSelection = EditableSelectionGeometry.resized(
                original, using: handle, to: p, within: bounds
            )
            adjustedReviewCrop = true
        case .none:
            break
        }
        if adjustedReviewCrop, owner?.session.phase == .reviewing {
            // Keep the visible toolbar and the session's pixel authority on
            // the same crop during the drag.  Waiting for mouseUp leaves the
            // toolbar behind and creates a visible jump on release.
            // Syncing also moves the caption's clip with the crop.
            syncSessionPixelRect()
            layoutReviewToolbar()
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        updatePointer(from: event)
        switch mode {
        case .area:
            let p = convert(event.locationInWindow, from: nil)
            if annotationDragging {
                // A terminal action may have frozen the document while the
                // mouse was still down. Finalizing now would add a mark the
                // export never saw, and enqueue OCR against a session that is
                // already closing, so the draft is dropped instead.
                // Any phase that no longer accepts commits, not only
                // `.saving`: the document is frozen in all of them.
                if owner?.session.acceptsCommits != true {
                    annotationSurface?.abandonDrag()
                } else {
                    annotationSurface?.endDrag()
                    if let frozen {
                        annotationSurface?.startPendingTextRedaction(
                            base: frozen.cgImage)
                        // Sampled from the document, so an existing pixelation
                        // is already covering the pixels the callout enlarges.
                        annotationSurface?.fillPendingMagnifier(
                            base: frozen.cgImage)
                    }
                }
                annotationDragging = false
                needsDisplay = true
                return
            }
            let wasCreating: Bool
            if case .creating = areaDrag { wasCreating = true } else { wasCreating = false }
            let wasAdjusting = areaDrag != nil && !wasCreating
            areaDrag = nil
            if let selection = areaSelection, selection.width < 4 || selection.height < 4 {
                areaSelection = nil
            }
            // Mouse-up IS the capture (no Capture button, no Enter needed).
            if wasCreating, let selection = areaSelection {
                commitInitialSelection(selection)
            } else if wasAdjusting,
                      owner?.session.phase == .reviewing {
                // EXACTLY reviewing: `isReviewing` also covers `.saving`, and
                // the crop must not move under an image already handed off.
                // review resize/move finished: selection is the new live crop
                syncSessionPixelRect()
                layoutReviewToolbar()
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
        if textEditingActive {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc
            // Esc still cancels — it is the way out of a drag the user no
            // longer wants — but the draft is dropped and the host's drag
            // state cleared FIRST. Otherwise a mouseUp arriving after teardown
            // finalizes onto a surface whose host is already gone.
            if annotationDragging {
                annotationSurface?.abandonDrag()
                annotationDragging = false
                needsDisplay = true
            }
            areaDrag = nil
            handleEscape()
            return
        }
        // NOTHING routes while a drag is live — Return and the digits and the
        // tool map alike. The draft is already in the document and its
        // finalizing transaction is half-built, so a route here can strand the
        // spotlight being replaced, leave a zero-area draft behind, or export
        // a half-drawn mark and let mouseUp mutate the document afterwards.
        if annotationDragging || areaDrag != nil { return }
        if isReviewing, (event.keyCode == 36 || event.keyCode == 76) {
            // Return / keypad Enter during review = Copy and close. (Esc and
            // click-outside cancel; the overlay never applies the editor's
            // escCopy/escSave settings — QA invariant 5.)
            performReviewAction(.copy)
            return
        }
        let flags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        if owner?.session.phase == .reviewing,
           handleColorPickKey(event, flags: flags) {
            return
        }
        // Shift-only + B selects text redaction; plain B stays Pixelate and
        // plain S stays Spotlight.
        if owner?.session.phase == .reviewing, flags == .shift,
           event.charactersIgnoringModifiers?.lowercased() == "b" {
            selectAnnotationTool(.pixelateText)
            return
        }
        // Plain 1-9 set spotlight darkness, BEFORE the tool map. Reviewing
        // only — never while saving — and a modified digit does nothing.
        if owner?.session.phase == .reviewing, flags.isEmpty,
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...9).contains(digit) {
            annotationSurface?.setSpotlightDim(CGFloat(digit) / 10)
            return
        }
        // D opens the preset chooser, exactly as the button does — the hint
        // advertises the key, so it has to work.
        if owner?.session.phase == .reviewing, flags.isEmpty,
           event.charactersIgnoringModifiers?.lowercased() == "d",
           let button = toolbarButtons.first(where: {
               $0.tag == OverlayAnnotationTool.backdropToolbarTag
           }) {
            showBackdropMini(from: button)
            return
        }
        if owner?.session.phase == .reviewing,
           flags.isEmpty,
           let key = event.charactersIgnoringModifiers,
           let tool = OverlayAnnotationTool.tool(
               forShortcutKey: key, in: OverlayAnnotationTool.areaReviewTools) {
            selectAnnotationTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textEditingActive {
            // ⌘C/⌘Z/⌘V belong to the active text field
            return super.performKeyEquivalent(with: event)
        }
        // Same rule as keyDown, and CONSUMED: forwarding to super would let
        // the responder or menu chain run the very command being blocked.
        if annotationDragging || areaDrag != nil { return true }
        let pickFlags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        // `.saving` is part of `isReviewing` but must reject picker mutation.
        if owner?.session.phase == .reviewing,
           handleColorPickKey(event, flags: pickFlags) {
            return true
        }
        if isSaving, isColorPickKey(event, flags: pickFlags) {
            return true
        }
        if isReviewing,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            performReviewAction(.copy)
            return true
        }
        let flags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        if isReviewing,
           event.charactersIgnoringModifiers?.lowercased() == "z",
           flags == [.command] || flags == [.command, .shift] {
            // Save in flight is consumed but frozen. After cancel the same
            // exact shortcut reaches the preserved history branch.
            performHistoryAction(redo: flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isColorPickKey(
        _ event: NSEvent, flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard event.keyCode == 48 else { return false } // Tab
        return flags.isEmpty || flags == .shift
    }

    @discardableResult
    private func handleColorPickKey(
        _ event: NSEvent, flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard isColorPickKey(event, flags: flags) else { return false }
        pickColorAtMouse(darkest: flags == .shift)
        return true
    }

    private func pickColorAtMouse(darkest: Bool) {
        guard let frozen, !isSaving else { return }
        guard let viewPt = pointerViewPoint() else {
            ToastHUD.show(
                "No pixel", symbol: "eyedropper",
                on: screen, above: window?.level)
            return
        }
        let pixel = pixelPoint(fromView: viewPt)
        let color = darkest
            ? PixelColorSampler.darkest(image: frozen.cgImage, around: pixel)
            : PixelColorSampler.sample(image: frozen.cgImage, at: pixel)
        guard let color else {
            ToastHUD.show(
                "No pixel", symbol: "eyedropper",
                on: screen, above: window?.level)
            return
        }
        let hex = PixelColorSampler.hexString(from: color)
        SaveService.copyText(hex)
        ToastHUD.show(
            hex, symbol: "eyedropper",
            on: screen, above: window?.level)
    }

    func pickColorHexForTesting(at viewPoint: CGPoint, darkest: Bool) -> String? {
        guard let frozen else { return nil }
        let pixel = pixelPoint(fromView: viewPoint)
        let color = darkest
            ? PixelColorSampler.darkest(image: frozen.cgImage, around: pixel)
            : PixelColorSampler.sample(image: frozen.cgImage, at: pixel)
        return color.map(PixelColorSampler.hexString(from:))
    }

    var pointerInsideForTesting: Bool { pointerInside }
    func mouseExitedForTesting() { invalidatePointer() }

    // MARK: text annotation entry

    fileprivate func beginTextEntry(atView p: CGPoint) {
        endTextEntry(commit: true)
        let field = NSTextField(frame: CGRect(
            x: p.x, y: p.y - 12, width: 220, height: 26))
        field.font = .boldSystemFont(ofSize: 18)
        field.textColor = annotationSurface?.color ?? .systemRed
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = textFieldDelegate
        addSubview(field)
        textField = field
        updateTextEntryClip()
        textFieldPixelOrigin = pixelPoint(fromView: CGPoint(x: p.x, y: p.y - 12))
        window?.makeFirstResponder(field)
    }

    /// Commits (or discards) the in-flight text field. Return in the field
    /// ends editing via the delegate — never the capture-terminal path.
    fileprivate func endTextEntry(commit: Bool) {
        guard let field = textField else { return }
        // Reentrancy: removing/resigning the field fires the delegate's
        // controlTextDidEndEditing → onEnd → endTextEntry AGAIN. Read the
        // value (validateEditing needs the live editor), then clear the ivar
        // BEFORE remove/resign so the nested call sees nil — the entry must
        // commit exactly once, never twice.
        let value = field.stringValue
        let origin = textFieldPixelOrigin
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        // A delegate callback can arrive after the session has finished; the
        // normal terminal routes commit the field BEFORE the snapshot, so this
        // only ever discards text that would have missed the export anyway.
        if commit, !value.isEmpty, owner?.session.phase == .reviewing {
            annotationSurface?.addText(value, atPixel: origin)
            needsDisplay = true
        }
    }

    func beginTextEntryForTesting(atView p: CGPoint) {
        beginTextEntry(atView: p)
    }
    func commitTextEntryForTesting(text: String) {
        // write through the ACTIVE field editor: endTextEntry reads
        // stringValue, whose getter validateEditing()s the (otherwise empty)
        // editor text back over a value set directly on the cell
        if let editor = textField?.currentEditor() as? NSTextView {
            editor.insertText(
                text,
                replacementRange: NSRange(
                    location: 0, length: (editor.string as NSString).length))
        } else {
            textField?.stringValue = text
        }
        endTextEntry(commit: true)
    }
    /// Types into the LIVE field without ending the entry, so a gate can run
    /// a terminal action while the text is still uncommitted — which is the
    /// state the prospective-render path exists for.
    func typeTextForTesting(_ text: String) {
        if let editor = textField?.currentEditor() as? NSTextView {
            editor.insertText(
                text,
                replacementRange: NSRange(
                    location: 0, length: (editor.string as NSString).length))
        } else {
            textField?.stringValue = text
        }
    }
    var textFieldForTesting: NSTextField? { textField }

    private lazy var textFieldDelegate = OverlayTextFieldDelegate(
        onEnd: { [weak self] in self?.endTextEntry(commit: true) })

    /// The ONE cursor table for area mode, listed in the order `mouseDown`
    /// consults its branches — later entries win an overlap, which is also
    /// how a window resolves overlapping cursor rects.
    ///
    /// So: an active drawing tool owns the INSIDE of the crop, handles
    /// included, because `mouseDown` checks `tool != .select` before it
    /// checks the handles and a drag there draws. The handle squares still
    /// straddle the edge, and the part of them outside the crop keeps its
    /// resize cursor — which is exactly where `mouseDown` does resize.
    /// Corners come after the mid-edges for the same reason
    /// `EditableSelectionGeometry.handle(at:)` gives them priority.
    private func areaCursorRects() -> [(rect: CGRect, cursor: AppCursor)] {
        guard mode == .area else { return [(bounds, .crosshair)] }
        var rects: [(rect: CGRect, cursor: AppCursor)] = [(bounds, .crosshair)]
        guard let selection = areaSelection else { return rects }
        let tool = annotationSurface?.tool ?? .select
        let drawing = isReviewing && !textEditingActive && tool != .select
        if !drawing { rects.append((selection, .openHand)) }
        let handleRects = EditableSelectionGeometry.handleRects(
            for: selection, size: 18,
            cornerRadius: reviewCornerRadius(for: selection))
        let handleOrder: [SelectionHandle] = [
            .bottom, .top, .left, .right,
            .bottomLeft, .bottomRight, .topLeft, .topRight,
        ]
        for handle in handleOrder {
            guard let entry = handleRects.first(where: { $0.0 == handle })
            else { continue }
            rects.append((entry.1, .resize(handle)))
        }
        if drawing { rects.append((selection, AppCursor.drawing(tool))) }
        if let mini = backdropMini, !mini.isHidden {
            let editor = convert(mini.openEditorButtonFrame, from: mini)
            rects.append((editor, .pointingHand))
        }
        return rects
    }

    /// Point lookup over that same table, last match first. Two readers of
    /// one table instead of two implementations: `resetCursorRects` and the
    /// `mouseMoved` path cannot drift apart and disagree about what the
    /// pointer means.
    func areaCursor(at point: CGPoint) -> AppCursor {
        if case .moving = areaDrag { return .closedHand }
        for entry in areaCursorRects().reversed()
        where entry.rect.contains(point) {
            return entry.cursor
        }
        return .crosshair
    }

    override func resetCursorRects() {
        for (rect, cursor) in areaCursorRects() {
            addCursorRect(rect, cursor: cursor.cursor)
        }
    }

    private func updateAreaCursor(at point: CGPoint) {
        applyCursor(areaCursor(at: point))
    }

    /// The only place this view sets a cursor. Recording and setting in one
    /// step is what makes `currentCursorForTesting` evidence rather than a
    /// second opinion.
    private func applyCursor(_ cursor: AppCursor) {
        currentCursor = cursor
        cursor.cursor.set()
    }

    /// Mouse-up commit, by purpose: scroll/OCR hand the rect over exactly
    /// once and close; area-review fires the one initialCapture and either
    /// enters in-place review or (headless) finishes right away.
    private func commitInitialSelection(_ rawSelection: CGRect) {
        guard let owner else { return }
        let selection = rawSelection.intersection(bounds)
        guard selection.width >= 4, selection.height >= 4, let frozen else { return }

        switch owner.session.purpose {
        case .scrollRegion, .instantOCRRegion:
            owner.finish(.area(screen: screen, frozen: frozen, rect: selection))
        case .windowPick:
            break
        case .areaReview:
            guard owner.session.commitInitialCapture() else { return }
            // Same authority for the reported rect as for the pixels: the
            // clamped, quantized selection, not the one the pointer left
            // behind. Sync reads the stored rect, so the clamp lands there
            // first or the two readings would diverge at the screen edge.
            areaSelection = selection
            let canonical = syncSessionPixelRect() ?? selection
            guard let snapshot = snapshotFromSessionPixelRect() else {
                owner.finish(.cancelled)
                return
            }
            CaptureActionRouter.commit(
                snapshot, source: .areaReview, intent: .initialCapture,
                inputs: owner.session.inputs,
                finalGlobalRect: globalRect(for: canonical),
                dependencies: owner.routerDependenciesOverride)
            if owner.session.phase == .reviewing {
                let surface = AnnotationSurface(pixelScale: frozen.scale)
                surface.historyDidChange = { [weak self] in
                    self?.updateHistoryButtons()
                }
                // Repaint through the weak host delegate, and let a spotlight
                // dim the WHOLE source image rather than the selection.
                surface.redactionDelegate = self
                surface.redactionBaseBounds = CGRect(
                    x: 0, y: 0,
                    width: frozen.cgImage.width, height: frozen.cgImage.height)
                // Resampling a magnifier when the redaction set changes needs
                // the base image at that moment, not at the moment the host
                // happens to be running.
                surface.redactionBaseImage = frozen.cgImage
                // A magnifier callout stays inside the crop the export makes
                // (bottom-left image pixels; the session rect is top-left).
                surface.magnifierBounds = { [weak self] in
                    guard let self, let owner = self.owner else { return nil }
                    let px = owner.session.pixelRect
                    guard px.width >= 1, px.height >= 1 else { return nil }
                    return CGRect(
                        x: px.minX,
                        y: CGFloat(frozen.cgImage.height) - px.maxY,
                        width: px.width, height: px.height)
                }
                annotationSurface = surface
                owner.reviewDidBegin(in: self)
                layoutReviewToolbar()
                needsDisplay = true
            } else {
                owner.finish(.handled)
            }
        }
    }

    /// Screen-local selection → global AppKit coords (the Repeat-Area rect
    /// contract, AppDelegate legacy parity).
    private func globalRect(for selection: CGRect) -> CGRect {
        CGRect(
            x: selection.minX + screen.frame.minX,
            y: selection.minY + screen.frame.minY,
            width: selection.width, height: selection.height)
    }

    /// View points (bottom-left) → frozen image pixels (bottom-left): the
    /// frozen image maps 1:1 onto the view in points.
    fileprivate func pixelPoint(fromView p: CGPoint) -> CGPoint {
        let scale = frozen?.scale ?? 1
        return CGPoint(x: p.x * scale, y: p.y * scale)
    }

    /// Text-field-first responder precedence (QA invariant: while typing,
    /// Enter/⌘C/⌘Z/Esc belong to the text editing, never terminal capture).
    fileprivate var textEditingActive: Bool {
        guard let field = textField else { return false }
        if let editor = window?.firstResponder as? NSTextView,
           editor.delegate === field {
            return true
        }
        return window?.firstResponder === field
    }

    /// What a terminal action needs: the SAME freeze in both readings.
    ///
    /// `semantic` is the crop the user selected, undecorated — what OCR and
    /// Translate must read and what `lastAreaRect` describes. `visual` is that
    /// crop inside its frame — what Copy, Save, Pin, the editor and
    /// `lastCapture` receive. With no backdrop the two are the same image, so
    /// nothing is composed and nothing extra is allocated.
    struct ReviewPayload {
        let visual: CapturedImage
        let semantic: CapturedImage
    }

    /// Which reading an intent takes. Anything that produces a picture is
    /// decorated; the two text intents are not.
    static func usesDecoration(_ intent: CaptureIntent) -> Bool {
        switch intent {
        case .ocr, .translate: return false
        default: return true
        }
    }

    enum PayloadFailure {
        case render
        case backdrop
    }
    /// Why the last payload attempt failed, so the toast can name the frame
    /// rather than blame the drawings.
    private(set) var lastPayloadFailure: PayloadFailure = .render

    /// The text still being typed, rendered as if it had been committed. Must
    /// mirror `AnnotationSurface.addText` exactly, or the export would differ
    /// from the mark the commit afterwards actually adds.
    private func prospectiveTextAnnotation() -> TextAnnotation? {
        guard let field = textField, let surface = annotationSurface,
              owner?.session.phase == .reviewing else { return nil }
        let value = field.stringValue
        guard !value.isEmpty else { return nil }
        let annotation = TextAnnotation(uiScale: surface.pixelScale)
        annotation.text = value
        annotation.origin = textFieldPixelOrigin
        annotation.color = surface.color
        return annotation
    }

    /// THE single pixel-crop authority: every snapshot (initial, manual
    /// action, and slice-4 annotation flatten) crops the frozen image by the
    /// session's integral pixelRect — the view rect is quantized exactly
    /// once, in syncSessionPixelRect.
    fileprivate func reviewPayload(
        prospectiveText: TextAnnotation? = nil,
        omittingSpotlights: Bool = false
    ) -> ReviewPayload? {
        lastPayloadFailure = .render
        guard let owner, let frozen else { return nil }
        let px = owner.session.pixelRect
        guard px.width >= 1, px.height >= 1 else { return nil }
        let style = overlayDrawStyle
        // Reserve what the FRAME will need before rendering the crop, and
        // render the crop inside what is left: both buffers are alive during
        // the compose, so the peak is inner + outer, not whichever is larger.
        // Same arithmetic as the editor's flatten.
        let reserve = SliceBBackdrop.reservedBytes(
            forInnerWidth: Int(px.width), height: Int(px.height),
            style: style, pixelScale: frozen.scale)
        guard let innerBudget = SliceBExport.budget(
            SliceBExport.defaultBudgetBytes, minus: reserve),
            let innerBytes = SliceBExport.byteCount(
                width: Int(px.width), height: Int(px.height)),
            innerBytes <= innerBudget
        else {
            lastPayloadFailure = .backdrop
            return nil
        }

        // A framed export is composed in sRGB, so the inner render lands in
        // sRGB as well — including the semantic payload, so OCR reads exactly
        // the pixels the frame was built around. With no frame the document
        // keeps its own space, byte for byte.
        let destinationSpace: CGColorSpace? = style.kind == .none
            ? nil : CGColorSpace(name: CGColorSpace.sRGB)
        let extra: [Annotation] = prospectiveText.map { [$0] } ?? []
        let inner: CGImage
        // The LIVE surface, even with nothing drawn on it: a conversion into
        // the destination space allocates a real buffer and can fail, so it
        // has to run through the surface the gates hold — its forced-failure
        // flag is per instance, and a throwaway surface would make this route
        // both unfailable and invisible to the allocation trace.
        if let surface = annotationSurface,
           !surface.isEmpty || !extra.isEmpty || destinationSpace != nil {
            guard let flat = surface.flattened(
                base: frozen.cgImage, cropPixels: px, extra: extra,
                destinationSpace: destinationSpace,
                omittingSpotlights: omittingSpotlights)
            else { return nil }
            inner = flat
        } else {
            guard let cropped = frozen.cgImage.cropping(to: px)?.materialized()
            else { return nil }
            inner = cropped
        }
        let semantic = CapturedImage(cgImage: inner, scale: frozen.scale)
        guard style.kind != .none else {
            return ReviewPayload(visual: semantic, semantic: semantic)
        }
        guard let composed = SliceBBackdrop.compose(
            image: inner, style: style,
            budgetBytes: SliceBExport.defaultBudgetBytes,
            pixelScale: frozen.scale)
        else {
            lastPayloadFailure = .backdrop
            return nil
        }
        return ReviewPayload(
            visual: CapturedImage(cgImage: composed, scale: frozen.scale),
            semantic: semantic)
    }

    /// The undecorated crop, for the routes that predate the frame (the
    /// initial capture runs before review begins, so no preset can exist yet).
    fileprivate func snapshotFromSessionPixelRect() -> CapturedImage? {
        reviewPayload()?.semantic
    }

    /// Pixel contract: the session always holds the image-local INTEGRAL
    /// pixel rect for the current selection (same quantization rule as
    /// CapturedImage.cropping(toViewRect:)).
    ///
    /// The integral rect is the ONE authority, so the selection is mapped back
    /// OUT of it and stored: the border, the dim hole, the annotation clip,
    /// the caption mask, the toolbar and the frame then all describe the crop
    /// the export actually makes. While the fractional rect stayed live, a
    /// selection created or dragged by half a point at scale 2 drew a boundary
    /// the exported image did not have — with no backdrop just as much as with
    /// one. Every drag recomputes from its own anchor/original rect, so
    /// quantizing here cannot accumulate.
    @discardableResult
    private func syncSessionPixelRect() -> CGRect? {
        guard let owner, let frozen, let selection = areaSelection
        else { return nil }
        let scale = frozen.scale
        let imageHeightPoints = CGFloat(frozen.cgImage.height) / scale
        let px = CGRect(
            x: selection.minX * scale,
            y: (imageHeightPoints - selection.maxY) * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ).integral
        owner.session.pixelRect = px
        // Inverse of the map above: top-left image pixels back to view points.
        let canonical = CGRect(
            x: px.minX / scale,
            y: imageHeightPoints - px.maxY / scale,
            width: px.width / scale,
            height: px.height / scale)
        areaSelection = canonical
        // The caption is clipped to the crop, so the two move together. Doing
        // it here rather than at each call site is what keeps them coherent:
        // the live drag refreshed the mask on every move, but the mouse-up
        // that quantizes the rect one last time did not, and neither did the
        // review-resize path a gate drives.
        updateTextEntryClip()
        return canonical
    }
}

/// Ends overlay text editing when the field resigns or Return is pressed —
/// keeping Return inside the text field instead of the capture-terminal path.
@MainActor
final class OverlayTextFieldDelegate: NSObject, NSTextFieldDelegate {
    private let onEnd: @MainActor () -> Void
    init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        onEnd()
    }
}
