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
        CaptureActionRouter.commit(
            image, source: .scrollResult, intent: .scrollFinished,
            inputs: finish.inputs, finalGlobalRect: nil,
            dependencies: dependencies)
        // A screenless environment has nowhere to present — the auto actions
        // above already secured the shot.
        if finish.inputs.afterShow, let screen = finish.screen {
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
        self.annotationSurface = AnnotationSurface(pixelScale: image.scale)

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

        // pixels-per-view-point for the fitted image (used by drawing input)
        let pixelsPerPoint = CGFloat(image.cgImage.width) / imageSize.width
        let host = AnnotationHostView(
            frame: imageView.frame,
            surface: annotationSurface,
            pixelsPerPoint: pixelsPerPoint)
        host.isLocked = { [weak self] in self?.saving ?? false }
        content.addSubview(host)
        annotationHost = host

        let bar = buildToolbar(width: contentSize.width, height: toolbarHeight)
        content.addSubview(bar)
        actionBar = bar
        contentView = content
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

    /// Annotation tools mirror the area review: tags 100+ tools, 200 color,
    /// 201 undo.
    private static let toolItems: [OverlayAnnotationTool] = [
        .select, .pen, .arrow, .rect, .text,
    ]
    private static let colorPresets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .black, .white,
    ]
    private var colorIndex = 0

    /// Width every button (plus Close and paddings) needs without overlap.
    static var requiredToolbarWidth: CGFloat {
        let buttonWidth: CGFloat = 34, spacing: CGFloat = 2
        let count = CGFloat(items.count + toolItems.count + 2) // + color, undo
        // leading 8 + buttons + gap 12 + close + trailing 8
        return 8 + count * buttonWidth + (count - 1) * spacing + 12
            + buttonWidth + 8
    }

    var toolbarButtonFramesForTesting: [CGRect] {
        toolbarButtons.map { $0.frame }
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
        for (index, tool) in Self.toolItems.enumerated() {
            _ = makeButton(
                symbol: tool.symbol, tooltip: tool.tooltip,
                tag: 100 + index,
                tint: tool == .select ? .controlAccentColor : .labelColor)
        }
        _ = makeButton(
            symbol: "circle.fill", tooltip: "Color", tag: 200,
            tint: Self.colorPresets[colorIndex])
        _ = makeButton(
            symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)",
            tag: 201, tint: .labelColor)
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

    @objc private func toolbarPressed(_ sender: NSButton) {
        if saving { return }
        if sender.tag == -1 {
            dismiss()
            return
        }
        if sender.tag >= 100, sender.tag < 100 + Self.toolItems.count {
            let tool = Self.toolItems[sender.tag - 100]
            annotationSurface.tool = tool
            for button in toolbarButtons where button.tag >= 100
                && button.tag < 100 + Self.toolItems.count {
                button.contentTintColor =
                    button.tag == sender.tag ? .controlAccentColor : .labelColor
            }
            return
        }
        if sender.tag == 200 {
            colorIndex = (colorIndex + 1) % Self.colorPresets.count
            annotationSurface.color = Self.colorPresets[colorIndex]
            sender.contentTintColor = Self.colorPresets[colorIndex]
            return
        }
        if sender.tag == 201 {
            if annotationSurface.undo() { annotationHost?.needsDisplay = true }
            return
        }
        guard sender.tag >= 0, sender.tag < Self.items.count else { return }
        perform(intent: Self.items[sender.tag].intent)
    }

    func performActionForTesting(_ intent: CaptureIntent) {
        perform(intent: intent)
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
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if !saving, annotationSurface.undo() {
                annotationHost?.needsDisplay = true
            }
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
    private let pixelsPerPoint: CGFloat
    private var dragging = false
    /// While the owning surface has a save in flight, ALL annotation input
    /// is frozen — the exported state must be exactly what the user saw when
    /// they pressed Save.
    var isLocked: @MainActor () -> Bool = { false }

    init(frame: CGRect, surface: AnnotationSurface, pixelsPerPoint: CGFloat) {
        self.surface = surface
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
        surface.drawForPreview(in: ctx)
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
        let value = field.stringValue
        field.removeFromSuperview()
        textField = nil
        if commit, !value.isEmpty {
            surface.addText(value, atPixel: textPixelOrigin)
            needsDisplay = true
        }
    }
}
