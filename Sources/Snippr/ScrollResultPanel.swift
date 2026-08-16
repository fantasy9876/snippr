import AppKit

/// Routes a finished scrolling capture: the auto actions run exactly once
/// through the router (`.scrollFinished`, source `.scrollResult` — never a
/// Repeat-Area rect), then — only when the snapshotted `afterShow` says so —
/// the result is presented in the Editor (default, `AfterScrollShow.editor`)
/// or the borderless in-place panel. There is deliberately no `handleResult`
/// path here (QA invariants 13–15).
@MainActor
enum ScrollResultPresenter {
    static func present(
        _ finish: ScrollFinish,
        dependencies: CaptureActionRouter.Dependencies? = nil,
        afterScrollShow: AfterScrollShow = Settings.shared.afterScrollShow
    ) {
        guard let image = finish.image else { return }
        // No screen = no presentation possible. The router must then treat
        // the commit as HEADLESS (effective afterShow=false, same
        // copy/save snapshot): with afterShow=true it would suppress the
        // rescue-copy/announce believing a panel will show, and the shot
        // would be lost entirely. ONE commit either way — no double actions.
        let canPresent = finish.screen != nil
        var effectiveInputs = finish.inputs
        if !canPresent { effectiveInputs.afterShow = false }
        CaptureActionRouter.commit(
            image, source: .scrollResult, intent: .scrollFinished,
            inputs: effectiveInputs, finalGlobalRect: nil,
            dependencies: dependencies)
        if effectiveInputs.afterShow, let screen = finish.screen {
            switch afterScrollShow {
            case .editor:
                // The editor is the destination the in-place panel's own
                // "Open in editor" button reaches: the SAME router intent,
                // so exactly-once/lastCapture semantics are unchanged.
                CaptureActionRouter.commit(
                    image, source: .scrollResult, intent: .openEditor,
                    inputs: finish.inputs, finalGlobalRect: nil,
                    dependencies: dependencies)
            case .panel:
                ScrollResultPanel.show(
                    image: image, inputs: finish.inputs, screen: screen,
                    dependencies: dependencies)
            }
        }
    }
}

/// Borderless in-place panel for the stitched page: image fitted to at most
/// 90% of the origin screen's visible frame, with the same action toolbar as
/// the area review. "Open in editor" is the escape hatch to the legacy
/// EditorWindow (zoom/crop-heavy work); Esc or Close dismisses.
@MainActor
final class ScrollResultPanel: NSPanel {
    private(set) static var current: ScrollResultPanel?

    private let image: CapturedImage
    private let inputs: OverlaySessionInputs
    private let dependencies: CaptureActionRouter.Dependencies?
    private var saving = false
    /// A retained/delayed reference must not replay a terminal action after
    /// the panel has detached and started presenting its destination.
    private var terminalActionClaimed = false
    private var toolbarButtons: [NSButton] = []
    private var actionBar: NSView?
    /// Slice 4: shared annotation surface over the stitched image.
    let annotationSurface: AnnotationSurface
    private var annotationHost: AnnotationHostView?

    @discardableResult
    static func show(
        image: CapturedImage, inputs: OverlaySessionInputs, screen: NSScreen,
        dependencies: CaptureActionRouter.Dependencies? = nil
    ) -> ScrollResultPanel {
        current?.dismiss()
        let panel = ScrollResultPanel(
            image: image, inputs: inputs, screen: screen,
            dependencies: dependencies)
        current = panel
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    private init(
        image: CapturedImage, inputs: OverlaySessionInputs, screen: NSScreen,
        dependencies: CaptureActionRouter.Dependencies?
    ) {
        self.image = image
        self.inputs = inputs
        self.dependencies = dependencies

        // Fit ≤90% of the ORIGIN screen's visible frame (a 24k-pt stitch must
        // not become a 24k-pt window).
        let visible = screen.visibleFrame
        let maxSize = CGSize(
            width: visible.width * 0.9, height: visible.height * 0.9)
        let pointSize = image.pointSize
        let toolbarButtonCount = OverlayAnnotationTool.allCases.count + 3
            + OverlayActionCatalog.items.count + 1 // Color/Undo/Redo + Close
        // A narrow stitch gets only enough chrome width for the 190pt
        // stroke HUD plus margins; controls wrap instead of widening the
        // panel to a full toolbar row.
        let minimumContentWidth = min(maxSize.width, 206)
        // Width and toolbar height are coupled: a tall 5K×40K stitch may be
        // vertically fitted down to a ~150pt image even though its natural
        // point width exceeds the screen. Start at the screen cap, then
        // monotonically converge to the FITTED image width; each wrap step
        // can only increase toolbar height and reduce the next width.
        var contentWidth = maxSize.width
        var toolbarLayout = OverlayToolbarLayout.panel(
            buttonCount: toolbarButtonCount,
            availableWidth: contentWidth)
        for _ in 0..<toolbarButtonCount {
            let availableImageHeight = max(
                1, maxSize.height - toolbarLayout.size.height)
            let candidateFit = min(
                1,
                contentWidth / max(1, pointSize.width),
                availableImageHeight / max(1, pointSize.height))
            let fittedImageWidth = max(1, pointSize.width * candidateFit)
            let nextWidth = min(
                maxSize.width,
                max(minimumContentWidth, fittedImageWidth))
            if abs(nextWidth - contentWidth) < 0.5 { break }
            contentWidth = nextWidth
            toolbarLayout = OverlayToolbarLayout.panel(
                buttonCount: toolbarButtonCount,
                availableWidth: contentWidth)
        }
        // Re-evaluate once at the converged width so bar height, image fit
        // and the actual panel frame all share one exact geometry snapshot.
        toolbarLayout = OverlayToolbarLayout.panel(
            buttonCount: toolbarButtonCount,
            availableWidth: contentWidth)
        let toolbarHeight = toolbarLayout.size.height
        let fit = min(
            1,
            contentWidth / max(1, pointSize.width),
            max(1, maxSize.height - toolbarHeight)
                / max(1, pointSize.height))
        // EXACT aspect fit — no per-axis min clamps: a distorted or
        // letterboxed image view would break the single pixels-per-point
        // factor the annotation host relies on.
        let imageSize = CGSize(
            width: max(1, pointSize.width * fit),
            height: max(1, pointSize.height * fit))
        // Authoring scale = pixels per VIEW point of the fitted panel, not
        // image.scale: this panel is fixed-fit, so a Pen 3pt / Text 18pt must
        // measure 3pt/18pt on the panel the user draws on — and the export,
        // viewed at the same fit, shows exactly the same weight (WYSIWYG).
        // With image.scale on a very tall stitch (fit « 1) the strokes were
        // ~6px on a 24k image: correct bytes, invisible while drawing.
        // fit == 1 degenerates to pixelsPerPoint == image.scale — unchanged.
        // Pixel COORDINATES stay absolute; only pt→px size conversion moves.
        let pixelsPerPoint = CGFloat(image.cgImage.width) / imageSize.width
        self.annotationSurface = AnnotationSurface(pixelScale: pixelsPerPoint)
        let contentSize = CGSize(
            width: contentWidth,
            height: imageSize.height + toolbarHeight)
        let origin = CGPoint(
            x: visible.midX - contentSize.width / 2,
            y: visible.midY - contentSize.height / 2)

        super.init(
            contentRect: CGRect(origin: origin, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        // A scroll capture can finish while another app owns a NATIVE
        // fullscreen Space (Safari/Chrome). Without these behaviors the
        // panel lands on a different Space — invisible — while the router
        // already suppressed the rescue copy because afterShow promised a
        // visible panel. Same pairing as the overlay/HUD windows.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        content.wantsLayer = true
        content.layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        content.layer?.cornerRadius = 10

        let imageView = NSImageView(frame: CGRect(
            x: (contentSize.width - imageSize.width) / 2, y: toolbarHeight,
            width: imageSize.width, height: imageSize.height))
        imageView.image = image.nsImage
        imageView.imageScaling = .scaleProportionallyDown
        content.addSubview(imageView)

        // same pixels-per-view-point maps drawing input to image pixels
        let host = AnnotationHostView(
            frame: imageView.frame,
            surface: annotationSurface,
            baseImage: image.cgImage,
            pixelsPerPoint: pixelsPerPoint)
        // Every terminal phase, not just saving: once the panel has claimed a
        // terminal action the image is handed off, and a late mouseUp must not
        // add to a document that has already left.
        host.isLocked = { [weak self] in
            guard let self else { return true }
            return self.saving || self.terminalActionClaimed
        }
        // The surface repaints through the host, weakly, and a spotlight dims
        // the WHOLE source image rather than the visible slice.
        annotationSurface.redactionDelegate = host
        annotationSurface.redactionBaseBounds = CGRect(
            x: 0, y: 0,
            width: image.cgImage.width, height: image.cgImage.height)
        host.strokeHUDContainer = content
        content.addSubview(host)
        annotationHost = host

        let bar = buildToolbar(layout: toolbarLayout)
        content.addSubview(bar)
        actionBar = bar
        contentView = content
        annotationSurface.historyDidChange = { [weak self] in
            self?.updateHistoryButtons()
        }
        updateHistoryButtons()
    }

    var toolbarFrameForTesting: CGRect? { actionBar?.frame }

    override var canBecomeKey: Bool { true }

    private static let colorPresets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .black, .white,
    ]
    private var colorIndex = 0

    var toolbarButtonFramesForTesting: [CGRect] {
        toolbarButtons.map { $0.frame }
    }
    var toolbarButtonsForTesting: [(tag: Int, tooltip: String)] {
        toolbarButtons.map { ($0.tag, $0.toolTip ?? "") }
    }

    private func buildToolbar(
        layout: OverlayToolbarLayout.Panel
    ) -> NSView {
        let bar = NSView(frame: CGRect(origin: .zero, size: layout.size))
        var buttons: [NSButton] = []
        @MainActor func makeButton(
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
            button.action = #selector(toolbarPressed(_:))
            bar.addSubview(button)
            buttons.append(button)
            return button
        }
        for tool in OverlayAnnotationTool.allCases {
            _ = makeButton(
                symbol: tool.symbol, tooltip: tool.tooltip,
                tag: tool.toolbarTag,
                tint: tool == .select ? .controlAccentColor : .labelColor)
        }
        _ = makeButton(
            symbol: "circle.fill", tooltip: "Color",
            tag: OverlayAnnotationTool.colorToolbarTag,
            tint: Self.colorPresets[colorIndex])
        _ = makeButton(
            symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)",
            tag: OverlayAnnotationTool.undoToolbarTag, tint: .labelColor)
        _ = makeButton(
            symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)",
            tag: OverlayAnnotationTool.redoToolbarTag, tint: .labelColor)
        for (index, item) in OverlayActionCatalog.items.enumerated() {
            _ = makeButton(
                symbol: item.symbol, tooltip: item.tooltip,
                tag: index, tint: .labelColor)
        }
        _ = makeButton(
            symbol: "xmark", tooltip: "Close (Esc)",
            tag: -1, tint: .labelColor)
        for (button, frame) in zip(buttons, layout.buttonFrames) {
            button.frame = frame
        }
        toolbarButtons = buttons
        return bar
    }

    private func updateHistoryButtons() {
        for button in toolbarButtons {
            switch button.tag {
            case OverlayAnnotationTool.undoToolbarTag:
                button.isEnabled = !saving && annotationSurface.canUndo
            case OverlayAnnotationTool.redoToolbarTag:
                button.isEnabled = !saving && annotationSurface.canRedo
            default:
                break
            }
        }
    }

    private func selectAnnotationTool(_ tool: OverlayAnnotationTool) {
        annotationSurface.tool = tool
        for button in toolbarButtons
            where OverlayAnnotationTool.tool(forToolbarTag: button.tag) != nil {
            button.contentTintColor =
                button.tag == tool.toolbarTag ? .controlAccentColor : .labelColor
        }
        if tool != .text { annotationHost?.commitActiveTextEntry() }
    }

    private func performHistoryAction(redo: Bool) {
        guard !saving, !terminalActionClaimed else { return }
        let changed = redo
            ? annotationSurface.redo() : annotationSurface.undo()
        if changed { annotationHost?.needsDisplay = true }
    }

    @objc private func toolbarPressed(_ sender: NSButton) {
        if saving || terminalActionClaimed { return }
        // Clicks, accessibility actions and programmatic routes reach this
        // without passing a key handler, so the drag guard belongs here too.
        if annotationHost?.isAnnotationDragging == true { return }
        if sender.tag == -1 {
            dismiss()
            return
        }
        if let tool = OverlayAnnotationTool.tool(forToolbarTag: sender.tag) {
            selectAnnotationTool(tool)
            return
        }
        if sender.tag == OverlayAnnotationTool.colorToolbarTag {
            colorIndex = (colorIndex + 1) % Self.colorPresets.count
            annotationSurface.color = Self.colorPresets[colorIndex]
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
        perform(intent: OverlayActionCatalog.items[sender.tag].intent)
    }

    func performActionForTesting(_ intent: CaptureIntent) {
        perform(intent: intent)
    }

    /// Clicks the REAL toolbar button (production target/action), so gates
    /// exercise the same path a user's click takes.
    func clickToolbarButtonForTesting(tag: Int) {
        toolbarButtons.first { $0.tag == tag }?.performClick(nil)
    }

    override func keyDown(with event: NSEvent) {
        if annotationHost?.textEditingActive == true {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc
            if saving { return }
            // Drop the draft and clear the drag before tearing down, so a
            // late mouseUp cannot finalize onto a dismissed panel.
            if annotationHost?.isAnnotationDragging == true {
                annotationHost?.abandonActiveDrag()
            }
            dismiss()
            return
        }
        // Nothing routes while a drag is live — including the terminal
        // actions, which would otherwise export a half-drawn mark and then let
        // mouseUp mutate the document after the handoff.
        if annotationHost?.isAnnotationDragging == true { return }
        if event.keyCode == 36 || event.keyCode == 76 { // Return
            perform(intent: .copy)
            return
        }
        let flags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        // Shift-only + B selects text redaction; plain B stays Pixelate and
        // plain S stays Spotlight.
        if !saving, !terminalActionClaimed, flags == .shift,
           event.charactersIgnoringModifiers?.lowercased() == "b" {
            selectAnnotationTool(.pixelateText)
            return
        }
        // Plain 1-9 set spotlight darkness, BEFORE the tool map, and never
        // while saving or after the terminal action.
        if !saving, !terminalActionClaimed, flags.isEmpty,
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...9).contains(digit) {
            annotationSurface.setSpotlightDim(CGFloat(digit) / 10)
            return
        }
        if !saving, !terminalActionClaimed, flags.isEmpty,
           let key = event.charactersIgnoringModifiers,
           let tool = OverlayAnnotationTool.tool(forShortcutKey: key) {
            selectAnnotationTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if annotationHost?.textEditingActive == true {
            return super.performKeyEquivalent(with: event)
        }
        // CONSUMED, not forwarded: super would let the responder or menu
        // chain run the command this is blocking.
        if annotationHost?.isAnnotationDragging == true { return true }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            perform(intent: .copy)
            return true
        }
        let flags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        if event.charactersIgnoringModifiers?.lowercased() == "z",
           flags == [.command] || flags == [.command, .shift] {
            performHistoryAction(redo: flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    var annotationHostForTesting: AnnotationHostView? { annotationHost }

    /// Drives the REAL mouse handlers with constructed events — the gate
    /// draws through production input, not the surface API.
    /// Same seam as the area overlay's: pause between the drag and the
    /// release so a gate can run the real routes mid-drag.
    func drawWithRealEventsForTesting(
        fromView a: CGPoint, toView b: CGPoint, whileDown: (() -> Void)? = nil
    ) {
        guard let host = annotationHost, let content = contentView else { return }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            let inWindow = content.convert(p, from: host)
            return NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: 0, windowNumber: windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, a) { host.mouseDown(with: down) }
        if let drag = event(.leftMouseDragged, b) { host.mouseDragged(with: drag) }
        whileDown?()
        if let up = event(.leftMouseUp, b) { host.mouseUp(with: up) }
    }

    /// Cancel every OCR job this panel owns: per annotation first, so each
    /// pending mask normalizes to the full mask, then sweep any orphan.
    private func cancelRedactionJobs() {
        // cancelAllRedactionJobs already cancels per annotation; doing both
        // would bump each generation twice and repaint twice.
        annotationSurface.cancelAllRedactionJobs()
    }

    /// Production teardown, exposed so a gate tears the panel down the way the
    /// app does (clearing `current`) instead of just ordering the window out.
    func dismissForTesting() { dismiss() }

    private func dismiss() {
        // Cancel BEFORE the view and `current` go away, or a late result would
        // land on a surface nobody can repaint.
        cancelRedactionJobs()
        terminalActionClaimed = true
        if ScrollResultPanel.current === self { ScrollResultPanel.current = nil }
        orderOut(nil)
    }

    /// The exported snapshot: the stitched image with any annotations
    /// flattened over the FULL image rect (same shared surface/flatten path
    /// as the area review).
    /// nil = annotated export failed. NEVER falls back to the plain image:
    /// that would report success while silently dropping the drawings.
    private var exportSnapshot: CapturedImage? {
        guard !annotationSurface.isEmpty else { return image }
        guard let flat = annotationSurface.flattened(
            base: image.cgImage,
            cropPixels: CGRect(
                x: 0, y: 0,
                width: image.cgImage.width, height: image.cgImage.height))
        else { return nil }
        return CapturedImage(cgImage: flat, scale: image.scale)
    }

    var exportSnapshotForTesting: CapturedImage? { exportSnapshot }

    /// Same exactly-once + terminal-order rules as the area review: Copy
    /// commits then closes; Pin/OCR/Translate/editor tear down BEFORE
    /// presenting; Save
    /// locks the panel in-flight and stays open on cancel/failure. All
    /// commits use source `.scrollResult` with a nil rect, so the
    /// Repeat-Area memory is never touched.
    private func perform(intent: CaptureIntent) {
        guard !saving, !terminalActionClaimed else { return }
        guard annotationHost?.isAnnotationDragging != true else { return }
        // A terminal click must never race the in-flight text entry: commit
        // the active field BEFORE exportSnapshot reads the surface (same
        // contract as the area review — no Return required first).
        annotationHost?.commitActiveTextEntry()
        guard let image = exportSnapshot else {
            // fail-closed: keep the panel (and the drawings) alive
            if let toast = dependencies?.toast {
                toast("Không xuất được ảnh có nét vẽ — thử lại")
            } else {
                ToastHUD.show("Không xuất được ảnh có nét vẽ — thử lại")
            }
            return
        }
        switch intent {
        case .copy:
            terminalActionClaimed = true
            CaptureActionRouter.commit(
                image, source: .scrollResult, intent: .copy,
                inputs: inputs, finalGlobalRect: nil,
                dependencies: dependencies)
            dismiss()
        case .save:
            // The snapshot above already succeeded, so freezing the document
            // here is safe; a failed render returned earlier with the jobs
            // still alive.
            cancelRedactionJobs()
            saving = true
            for button in toolbarButtons { button.isEnabled = false }
            var deps = dependencies ?? .live
            if dependencies == nil {
                let host: NSWindow = self
                deps.saveAs = { image, done in
                    SaveService.shared.saveAs(image, for: host, completion: done)
                }
            }
            CaptureActionRouter.commit(
                image, source: .scrollResult, intent: .save,
                inputs: inputs, finalGlobalRect: nil,
                dependencies: deps,
                resolution: { [weak self] outcome in
                    guard let self else { return }
                    self.saving = false
                    for button in self.toolbarButtons { button.isEnabled = true }
                    self.updateHistoryButtons()
                    if outcome == .completed { self.dismiss() }
                })
        case .pin, .ocr, .translate, .openEditor:
            terminalActionClaimed = true
            dismiss()
            CaptureActionRouter.commit(
                image, source: .scrollResult, intent: intent,
                inputs: inputs, finalGlobalRect: nil,
                dependencies: dependencies)
        case .initialCapture, .scrollFinished:
            break
        }
    }
}

/// Transparent input+preview layer for annotations over a FITTED image: view
/// points map to image pixels through one scale factor; the surface itself
/// stays in absolute pixel space (shared with the area review).
@MainActor
final class AnnotationHostView: NSView, RedactionSurfaceDelegate {
    private let surface: AnnotationSurface
    private let baseImage: CGImage
    private let pixelsPerPoint: CGFloat
    private var dragging = false

    /// The panel is movable by its background, and an NSView is nonopaque by
    /// default — which makes `mouseDownCanMoveWindow` true. The drawing area
    /// would therefore double as a window-drag handle whenever a tool is
    /// active. Select still moves the panel, because `hitTest` returns nil for
    /// this view then and the background takes the gesture.
    override var mouseDownCanMoveWindow: Bool { false }

    /// True between mouseDown and mouseUp on an annotation tool. Every route
    /// that mutates history, tools or the document stands aside until then:
    /// the draft is already in the document and its finalizing transaction is
    /// only half-built.
    var isAnnotationDragging: Bool { dragging }

    /// Drops the draft and ends the drag in one step, for a teardown that has
    /// to happen while the mouse is still down.
    func abandonActiveDrag() {
        guard dragging else { return }
        surface.abandonDrag()
        dragging = false
        needsDisplay = true
    }
    private var strokeHUD: StrokePreviewView?
    private var strokeHUDHide: DispatchWorkItem?
    /// The panel is deliberately wider than a tall/narrow stitched image so
    /// toolbar chrome fits. Put the fixed 190pt HUD on that wide content
    /// surface too; keeping it under the image host would clip it.
    weak var strokeHUDContainer: NSView?
    /// While the owning surface has a save in flight, ALL annotation input
    /// is frozen — the exported state must be exactly what the user saw when
    /// they pressed Save.
    var isLocked: @MainActor () -> Bool = { false }

    init(
        frame: CGRect, surface: AnnotationSurface, baseImage: CGImage,
        pixelsPerPoint: CGFloat
    ) {
        self.surface = surface
        self.baseImage = baseImage
        self.pixelsPerPoint = max(0.01, pixelsPerPoint)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func pixelPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * pixelsPerPoint, y: p.y * pixelsPerPoint)
    }

    func addTextForTesting(_ text: String, atView p: CGPoint) {
        surface.addText(text, atPixel: pixelPoint(p))
        needsDisplay = true
    }

    /// Terminal actions and tool switches call this before reading the
    /// surface: the in-flight text entry commits atomically so typed text
    /// cannot be lost to a snapshot race.
    func commitActiveTextEntry() {
        hostEndTextEntry(commit: true)
    }

    var textFieldForTesting: NSTextField? { textField }

    override func mouseDown(with event: NSEvent) {
        if isLocked() { return }
        let p = convert(event.locationInWindow, from: nil)
        guard surface.tool != .select else {
            super.mouseDown(with: event)
            return
        }
        if surface.tool == .text {
            // panel V1 text: fixed-position entry via field over the image
            hostBeginTextEntry(atView: p)
            return
        }
        if surface.beginDrag(atPixel: pixelPoint(p)) {
            dragging = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, !isLocked() else { return }
        let p = convert(event.locationInWindow, from: nil)
        surface.continueDrag(toPixel: pixelPoint(p))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        // Locked between mouseDown and mouseUp: the image has already been
        // handed off, so finalizing would add a mark that is not in it and
        // start OCR for a session that is closing.
        if isLocked() {
            surface.abandonDrag()
        } else {
            surface.endDrag()
            surface.startPendingTextRedaction(base: baseImage)
        }
        dragging = false
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func showStrokeHUD(width: CGFloat, color: NSColor) {
        let container = strokeHUDContainer ?? self
        let hud: StrokePreviewView
        if let existing = strokeHUD {
            hud = existing
        } else {
            hud = StrokePreviewView(
                frame: CGRect(x: 0, y: 0, width: 190, height: 44))
            container.addSubview(hud, positioned: .above, relativeTo: nil)
            strokeHUD = hud
        }
        hud.strokeWidth = width
        hud.color = color
        let anchor = convert(bounds, to: container)
        let vis = container.bounds
        let margin: CGFloat = 8
        let maxX = max(vis.minX + margin,
                       vis.maxX - hud.frame.width - margin)
        let maxY = max(vis.minY + margin,
                       vis.maxY - hud.frame.height - margin)
        hud.frame.origin = CGPoint(
            x: min(max(anchor.midX - hud.frame.width / 2,
                       vis.minX + margin), maxX),
            y: min(max(anchor.minY + 16, vis.minY + margin), maxY))
        hud.isHidden = false
        hud.needsDisplay = true
        strokeHUDHide?.cancel()
        let work = DispatchWorkItem { [weak hud] in hud?.isHidden = true }
        strokeHUDHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isLocked() else {
            surface.resetStrokeScrollAccumulator()
            return
        }
        // Same rule as every other route: nothing changes while a drag is in
        // flight, including the persisted stroke width and its HUD.
        guard !dragging else {
            surface.resetStrokeScrollAccumulator()
            return
        }
        guard !textEditingActive, surface.adjustsStrokeWidth else {
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
        // Do not call super for an eligible tool: width scrolling must not
        // pan the stitched image underneath the annotation gesture.
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // transparent to clicks while the select tool is active so the panel
        // keeps its move-by-background behavior
        let view = super.hitTest(point)
        if view === self, surface.tool == .select, textField == nil {
            return nil
        }
        return view
    }

    /// Independent evidence that production drawing really ran during a gate's
    /// snapshot, rather than a cached layer being handed back.
    private(set) var drawCallsForTesting = 0

    /// The surface repaints this view when a redaction resolves.
    func surfaceNeedsRedactionRepaint() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        drawCallsForTesting += 1
        guard !surface.isEmpty else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / pixelsPerPoint, y: 1 / pixelsPerPoint)
        surface.drawForPreview(in: ctx, base: baseImage)
        ctx.restoreGState()
    }

    // MARK: text entry (same precedence rule as the overlay)

    private var textField: NSTextField?
    private var textPixelOrigin: CGPoint = .zero
    private lazy var fieldDelegate = OverlayTextFieldDelegate(
        onEnd: { [weak self] in self?.hostEndTextEntry(commit: true) })

    var textEditingActive: Bool {
        guard let field = textField else { return false }
        if let editor = window?.firstResponder as? NSTextView,
           editor.delegate === field {
            return true
        }
        return window?.firstResponder === field
    }

    private func hostBeginTextEntry(atView p: CGPoint) {
        hostEndTextEntry(commit: true)
        let field = NSTextField(frame: CGRect(
            x: p.x, y: p.y - 12, width: 200, height: 24))
        field.font = .boldSystemFont(ofSize: 14)
        field.textColor = surface.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.delegate = fieldDelegate
        addSubview(field)
        textField = field
        textPixelOrigin = pixelPoint(CGPoint(x: p.x, y: p.y - 12))
        window?.makeFirstResponder(field)
    }

    private func hostEndTextEntry(commit: Bool) {
        guard let field = textField else { return }
        // Reentrancy parity with the area view: removing the field fires
        // controlTextDidEndEditing → onEnd → hostEndTextEntry AGAIN. Read
        // the value, then nil the ivar BEFORE removeFromSuperview so the
        // nested call bails — one entry, one annotation.
        let value = field.stringValue
        let origin = textPixelOrigin
        textField = nil
        field.removeFromSuperview()
        if commit, !value.isEmpty {
            surface.addText(value, atPixel: origin)
            needsDisplay = true
        }
    }
}
