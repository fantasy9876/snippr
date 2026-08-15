import AppKit

/// Routes a finished scrolling capture: the auto actions run exactly once
/// through the router (`.scrollFinished`, source `.scrollResult` — never a
/// Repeat-Area rect), then the borderless result panel presents only when the
/// snapshotted `afterShow` says so. There is deliberately no `handleResult`
/// path here (QA invariants 13–15).
@MainActor
enum ScrollResultPresenter {
    static func present(
        _ finish: ScrollFinish,
        dependencies: CaptureActionRouter.Dependencies? = nil
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
            ScrollResultPanel.show(
                image: image, inputs: finish.inputs, screen: screen,
                dependencies: dependencies)
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
        current?.orderOut(nil)
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
        let toolbarHeight: CGFloat = 44
        let fit = min(
            1,
            maxSize.width / max(1, pointSize.width),
            (maxSize.height - toolbarHeight) / max(1, pointSize.height))
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
        // The toolbar needs room for every button INCLUDING Close — a tall,
        // narrow stitch must widen the panel, not overflow the buttons.
        let toolbarMinWidth = ScrollResultPanel.requiredToolbarWidth
        let contentSize = CGSize(
            width: max(imageSize.width, toolbarMinWidth),
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
        host.isLocked = { [weak self] in self?.saving ?? false }
        host.strokeHUDContainer = content
        content.addSubview(host)
        annotationHost = host

        let bar = buildToolbar(width: contentSize.width, height: toolbarHeight)
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

    private static let items: [(symbol: String, tooltip: String, intent: CaptureIntent)] = [
        ("doc.on.doc", "Copy (Enter, ⌘C)", .copy),
        ("square.and.arrow.down", "Save…", .save),
        ("pin", "Pin to screen", .pin),
        ("text.viewfinder", "Copy text (OCR)", .ocr),
        ("macwindow", "Open in editor window", .openEditor),
    ]

    private static let colorPresets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .black, .white,
    ]
    private var colorIndex = 0

    /// Width every button (plus Close and paddings) needs without overlap.
    static var requiredToolbarWidth: CGFloat {
        let buttonWidth: CGFloat = 34, spacing: CGFloat = 2
        let count = CGFloat(
            items.count + OverlayAnnotationTool.allCases.count + 3)
        // leading 8 + buttons + gap 12 + close + trailing 8
        return 8 + count * buttonWidth + (count - 1) * spacing + 12
            + buttonWidth + 8
    }

    var toolbarButtonFramesForTesting: [CGRect] {
        toolbarButtons.map { $0.frame }
    }
    var toolbarButtonsForTesting: [(tag: Int, tooltip: String)] {
        toolbarButtons.map { ($0.tag, $0.toolTip ?? "") }
    }

    private func buildToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        var buttons: [NSButton] = []
        let size = CGSize(width: 34, height: 30)
        let spacing: CGFloat = 2
        var x: CGFloat = 8
        @MainActor func makeButton(
            symbol: String, tooltip: String, tag: Int, tint: NSColor
        ) -> NSButton {
            let button = NSButton(frame: CGRect(
                x: x, y: (height - size.height) / 2,
                width: size.width, height: size.height))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.contentTintColor = tint
            button.toolTip = tooltip
            button.tag = tag
            button.target = self
            button.action = #selector(toolbarPressed(_:))
            bar.addSubview(button)
            buttons.append(button)
            x += size.width + spacing
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
        for (index, item) in Self.items.enumerated() {
            _ = makeButton(
                symbol: item.symbol, tooltip: item.tooltip,
                tag: index, tint: .labelColor)
        }
        let close = NSButton(frame: CGRect(
            x: max(x + 12, width - size.width - 8),
            y: (height - size.height) / 2,
            width: size.width, height: size.height))
        close.bezelStyle = .regularSquare
        close.isBordered = false
        close.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close (Esc)")
        close.toolTip = "Close (Esc)"
        close.tag = -1
        close.target = self
        close.action = #selector(toolbarPressed(_:))
        bar.addSubview(close)
        buttons.append(close)
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
        guard !saving else { return }
        let changed = redo
            ? annotationSurface.redo() : annotationSurface.undo()
        if changed { annotationHost?.needsDisplay = true }
    }

    @objc private func toolbarPressed(_ sender: NSButton) {
        if saving { return }
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
        guard sender.tag >= 0, sender.tag < Self.items.count else { return }
        perform(intent: Self.items[sender.tag].intent)
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
            dismiss()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return
            perform(intent: .copy)
            return
        }
        let flags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        if !saving, flags.isEmpty,
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
    func drawWithRealEventsForTesting(fromView a: CGPoint, toView b: CGPoint) {
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
        if let up = event(.leftMouseUp, b) { host.mouseUp(with: up) }
    }

    private func dismiss() {
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
    /// commits then closes; Pin/OCR/editor tear down BEFORE presenting; Save
    /// locks the panel in-flight and stays open on cancel/failure. All
    /// commits use source `.scrollResult` with a nil rect, so the
    /// Repeat-Area memory is never touched.
    private func perform(intent: CaptureIntent) {
        guard !saving else { return }
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
            CaptureActionRouter.commit(
                image, source: .scrollResult, intent: .copy,
                inputs: inputs, finalGlobalRect: nil,
                dependencies: dependencies)
            dismiss()
        case .save:
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
        case .pin, .ocr, .openEditor:
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
final class AnnotationHostView: NSView {
    private let surface: AnnotationSurface
    private let baseImage: CGImage
    private let pixelsPerPoint: CGFloat
    private var dragging = false
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
        surface.endDrag()
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

    override func draw(_ dirtyRect: NSRect) {
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
