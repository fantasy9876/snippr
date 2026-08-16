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

    fileprivate func handleEscape() {
        if isSaving { return }
        owner?.finish(.cancelled)
    }
    func handleEscapeForTesting() { handleEscape() }
    func handleOutsideClickForTesting() {
        if isSaving { return }
        owner?.finish(.cancelled)
    }

    var hasAreaSelectionForTesting: Bool { areaSelection != nil }
    var isReviewingForTesting: Bool { isReviewing }
    var reviewToolbarFrameForTesting: CGRect? {
        let frames = [reviewToolRail, reviewActionBar].compactMap { view in
            view?.isHidden == false ? view?.frame : nil
        }
        guard var result = frames.first else { return nil }
        for frame in frames.dropFirst() { result = result.union(frame) }
        return result
    }
    var reviewToolbarButtonsForTesting: [(tag: Int, tooltip: String)] {
        toolbarButtons.map { ($0.tag, $0.toolTip ?? "") }
    }
    var reviewToolbarButtonFramesForTesting: [CGRect] {
        toolbarButtons.map { $0.convert($0.bounds, to: self) }
    }
    /// Drives a real drag through the production mouse handlers of this view,
    /// so a gate can create an annotation the way a user does.
    func annotationDragForTesting(from a: CGPoint, to b: CGPoint) {
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: convert(p, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, a) { mouseDown(with: down) }
        if let drag = event(.leftMouseDragged, b) { mouseDragged(with: drag) }
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
        button.tag = tag
        button.target = self
        button.action = #selector(reviewToolbarButtonPressed(_:))
        return button
    }

    private func buildReviewToolbars() -> (tool: NSView, action: NSView) {
        let toolContainer = makeReviewToolbarContainer()
        let actionContainer = makeReviewToolbarContainer()
        var toolButtons: [NSButton] = []
        for tool in OverlayAnnotationTool.allCases {
            let button = makeReviewToolbarButton(
                symbol: tool.symbol, tooltip: tool.tooltip,
                tag: tool.toolbarTag,
                tint: tool == .select ? .controlAccentColor : .white)
            toolContainer.addSubview(button)
            toolButtons.append(button)
        }
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
        annotationSurface?.tool = tool
        for button in toolbarButtons
            where OverlayAnnotationTool.tool(forToolbarTag: button.tag) != nil {
            button.contentTintColor =
                button.tag == tool.toolbarTag ? .controlAccentColor : .white
        }
        if tool != .text { endTextEntry(commit: true) }
    }

    private func performHistoryAction(redo: Bool) {
        guard owner?.session.phase == .reviewing,
              let surface = annotationSurface else { return }
        let changed = redo ? surface.redo() : surface.undo()
        if changed { needsDisplay = true }
    }

    @objc private func reviewToolbarButtonPressed(_ sender: NSButton) {
        if isSaving { return }
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
        guard sender.tag >= 0,
              sender.tag < OverlayActionCatalog.items.count else { return }
        performReviewAction(OverlayActionCatalog.items[sender.tag].intent)
    }

    /// One review intention = one router commit with the CURRENT crop.
    /// Terminal lifecycle per QA: Copy commits then closes; Pin/OCR/editor
    /// tear the overlay down BEFORE presenting; Save keeps the overlay in
    /// `.saving` and returns to review on cancel/failure.
    fileprivate func performReviewAction(_ intent: CaptureIntent) {
        guard let owner, owner.session.acceptsCommits,
              let selection = areaSelection?.intersection(bounds),
              selection.width >= 4, selection.height >= 4,
              frozen != nil
        else { return }
        // A terminal click must never race the in-flight text entry: commit
        // the active field BEFORE the snapshot/phase change, or the typed
        // text silently misses the export (no Return required first).
        endTextEntry(commit: true)
        syncSessionPixelRect()
        guard let snapshot = snapshotFromSessionPixelRect() else {
            // fail-closed like the panel: keep review + drawings, tell the
            // user, run NO action
            if let toast = owner.routerDependenciesOverride?.toast {
                toast("Không xuất được ảnh có nét vẽ — thử lại")
            } else {
                // the overlay is live at .screenSaver on THIS screen — a
                // default .statusBar toast would be invisible behind it
                ToastHUD.show(
                    "Không xuất được ảnh có nét vẽ — thử lại",
                    on: window?.screen ?? screen, above: window?.level)
            }
            return
        }
        let global = globalRect(for: selection)
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
                dependencies: baseDependencies)
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

        if let surface = annotationSurface, !surface.isEmpty,
           let sel = areaSelection, let frozen {
            let scale = frozen.scale
            ctx.saveGState()
            ctx.clip(to: sel)
            ctx.scaleBy(x: 1 / scale, y: 1 / scale)
            surface.drawForPreview(in: ctx, base: frozen.cgImage)
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
        guard mode == .area, let surface = annotationSurface else {
            super.scrollWheel(with: event)
            return
        }
        guard owner?.session.phase != .saving else {
            surface.resetStrokeScrollAccumulator()
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
        updatePointer(from: event)
        let p = convert(event.locationInWindow, from: nil)
        guard mode == .area else { return }
        if isSaving { return }
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
                annotationSurface?.endDrag()
                if let frozen {
                    annotationSurface?.startPendingTextRedaction(
                        base: frozen.cgImage)
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
            } else if wasAdjusting, isReviewing {
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
            handleEscape()
            return
        }
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
        if owner?.session.phase == .reviewing,
           flags.isEmpty,
           let key = event.charactersIgnoringModifiers,
           let tool = OverlayAnnotationTool.tool(forShortcutKey: key) {
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
        if commit, !value.isEmpty {
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
    var textFieldForTesting: NSTextField? { textField }

    private lazy var textFieldDelegate = OverlayTextFieldDelegate(
        onEnd: { [weak self] in self?.endTextEntry(commit: true) })

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
    }

    private func updateAreaCursor(at point: CGPoint) {
        if let selection = areaSelection,
                  let handle = EditableSelectionGeometry.handle(at: point, in: selection) {
            handle.cursor.set()
        } else if let selection = areaSelection, selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
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
            syncSessionPixelRect()
            guard let snapshot = snapshotFromSessionPixelRect() else {
                owner.finish(.cancelled)
                return
            }
            CaptureActionRouter.commit(
                snapshot, source: .areaReview, intent: .initialCapture,
                inputs: owner.session.inputs,
                finalGlobalRect: globalRect(for: selection),
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

    /// THE single pixel-crop authority: every snapshot (initial, manual
    /// action, and slice-4 annotation flatten) crops the frozen image by the
    /// session's integral pixelRect — the view rect is quantized exactly
    /// once, in syncSessionPixelRect.
    fileprivate func snapshotFromSessionPixelRect() -> CapturedImage? {
        guard let owner, let frozen else { return nil }
        let px = owner.session.pixelRect
        guard px.width >= 1, px.height >= 1 else { return nil }
        if let surface = annotationSurface, !surface.isEmpty {
            guard let flat = surface.flattened(
                base: frozen.cgImage, cropPixels: px) else { return nil }
            return CapturedImage(cgImage: flat, scale: frozen.scale)
        }
        guard let cropped = frozen.cgImage.cropping(to: px)?.materialized()
        else { return nil }
        return CapturedImage(cgImage: cropped, scale: frozen.scale)
    }

    /// Pixel contract: the session always holds the image-local INTEGRAL
    /// pixel rect for the current selection (same quantization rule as
    /// CapturedImage.cropping(toViewRect:)).
    private func syncSessionPixelRect() {
        guard let owner, let frozen, let selection = areaSelection else { return }
        let scale = frozen.scale
        let px = CGRect(
            x: selection.minX * scale,
            y: (CGFloat(frozen.cgImage.height) / scale - selection.maxY) * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ).integral
        owner.session.pixelRect = px
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
