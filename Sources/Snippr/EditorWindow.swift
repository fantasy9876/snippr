import AppKit

// MARK: - Editor window controller

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [EditorWindowController] = []

    private let canvas: EditorCanvasView
    private var sizeLabel: NSTextField!
    private var zoomLabel: NSTextField!
    private var colorWell: NSColorWell!
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var scrollView: NSScrollView!

    /// Builds (but never shows) an editor so AppKit, the scroll view and the
    /// SF Symbol toolbar images are all warm before the first real capture.
    static func prewarm() {
        guard controllers.isEmpty else { return }
        let tiny = CapturedImage(
            cgImage: CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!,
            scale: 1
        )
        let wc = EditorWindowController(image: tiny)
        wc.window?.layoutIfNeeded()
        wc.window?.close()
    }

    @discardableResult
    static func open(with image: CapturedImage) -> EditorWindowController {
        let wc = EditorWindowController(image: image)
        controllers.append(wc)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return wc
    }

    init(image: CapturedImage) {
        canvas = EditorCanvasView(image: image)

        let toolbarHeight: CGFloat = 46
        let contentSize = image.pointSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxSize = CGSize(
            width: screen.visibleFrame.width * 0.9,
            height: screen.visibleFrame.height * 0.9 - toolbarHeight
        )
        let winW = min(max(contentSize.width, 560), maxSize.width)
        let winH = min(contentSize.height, maxSize.height) + toolbarHeight

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.center()
        window.isReleasedWhenClosed = false
        if Settings.shared.alwaysOnTop {
            window.level = .floating
        }

        super.init(window: window)
        window.delegate = self

        buildUI(toolbarHeight: toolbarHeight)
        canvas.onStateChange = { [weak self] in self?.refreshLabels() }
        refreshLabels()
        applyInitialZoom()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(toolbarHeight: CGFloat) {
        guard let window, let contentView = window.contentView else { return }

        // --- scroll view with canvas
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)
        // keeps the shot centered when it's smaller than the window
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        canvas.enclosingScroll = { [weak self] in self?.scrollView }

        // --- top bar
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
            let b = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
                target: self, action: action
            )
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.contentTintColor = .lightGray
            b.toolTip = tooltip
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 30),
                b.heightAnchor.constraint(equalToConstant: 28),
            ])
            return b
        }

        let copyBtn = makeButton(symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: #selector(copyImage))
        let saveBtn = makeButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", action: #selector(saveImage))
        let pinBtn = makeButton(symbol: "pin", tooltip: "Pin to screen (⌘P)", action: #selector(pinImage))
        let ocrBtn = makeButton(symbol: "text.viewfinder", tooltip: "Recognize text (OCR)", action: #selector(runOCR))
        let translateBtn = makeButton(symbol: "globe", tooltip: "OCR + Translate", action: #selector(runTranslate))

        var toolViews: [NSView] = []
        for tool in EditorTool.allCases {
            let b = makeButton(symbol: tool.symbol, tooltip: tool.tooltip, action: #selector(toolTapped(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            toolButtons[tool] = b
            toolViews.append(b)
        }

        colorWell = NSColorWell(style: .minimal)
        colorWell.color = Settings.shared.lastAnnotationColor
        canvas.currentColor = Settings.shared.lastAnnotationColor
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorWell.widthAnchor.constraint(equalToConstant: 28),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
        ])

        sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor

        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor

        func sep() -> NSView {
            let v = NSBox()
            v.boxType = .separator
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return v
        }

        let leftPad = NSView() // room for traffic lights
        leftPad.translatesAutoresizingMaskIntoConstraints = false
        leftPad.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let stack = NSStackView(
            views: [leftPad, copyBtn, saveBtn, pinBtn, ocrBtn, translateBtn, sep()] + toolViews +
                   [sep(), colorWell, NSView(), sizeLabel, sep(), zoomLabel]
        )
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let flexible = stack.arrangedSubviews.dropLast(3).last {
            stack.setHuggingPriority(.defaultLow, for: .horizontal)
            flexible.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        bar.addSubview(stack)

        contentView.addSubview(scrollView)
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        selectTool(.select)
        window.makeFirstResponder(canvas)
    }

    private func applyInitialZoom() {
        guard let scrollView else { return }
        if Settings.shared.preferZoom100 {
            scrollView.magnification = 1
        } else {
            let visible = scrollView.contentView.bounds.size
            let img = canvas.image.pointSize
            let fit = min(visible.width / img.width, visible.height / img.height, 1)
            scrollView.magnification = fit
        }
        refreshLabels()
    }

    func refreshLabels() {
        let size = canvas.image.pointSize
        sizeLabel.stringValue = "\(Int(size.width))×\(Int(size.height))pt"
        let pct = Int(round((scrollView?.magnification ?? 1) * 100))
        zoomLabel.stringValue = "\(pct)%"
    }

    func selectTool(_ tool: EditorTool) {
        canvas.currentTool = tool
        for (t, b) in toolButtons {
            b.contentTintColor = t == tool ? .controlAccentColor : .lightGray
        }
    }

    // MARK: actions

    @objc private func toolTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let tool = EditorTool(rawValue: id) else { return }
        selectTool(tool)
    }

    @objc private func colorChanged() {
        canvas.currentColor = colorWell.color
        Settings.shared.lastAnnotationColor = colorWell.color
    }

    @objc func copyImage() {
        SaveService.shared.copyToClipboard(canvas.flattened())
        ToastHUD.show("Copied to clipboard")
        window?.close()
    }

    /// ⌘S / Save button: choose where to save via the system panel.
    @objc func saveImage() {
        guard let window else { return }
        var flat = canvas.flattened()
        if Settings.shared.downscaleRetina {
            flat = flat.downscaledTo1x()
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Snippr \(df.string(from: Date())).png"
        panel.directoryURL = Settings.shared.screenshotsFolder
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        let image = flat
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            let format: ImageFileFormat = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
            if let data = SaveService.data(for: image.cgImage, format: format) {
                do {
                    try data.write(to: url)
                    ToastHUD.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
                } catch {
                    ToastHUD.show("Save failed", symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    @objc func saveImageAs() { saveImage() }

    @objc func pinImage() {
        PinWindow.pin(canvas.flattened())
        window?.close()
    }

    @objc func runOCR() { recognizeText(autoTranslate: false) }
    @objc func runTranslate() { recognizeText(autoTranslate: true) }

    private func recognizeText(autoTranslate: Bool) {
        let flat = canvas.flattened()
        Task {
            let result = await OCRService.shared.recognize(flat.cgImage)
            await MainActor.run {
                let text = result.clipboardText
                if text.isEmpty {
                    ToastHUD.show("No text found", symbol: "text.magnifyingglass")
                } else {
                    SaveService.copyText(text)
                    TextResultWindow.show(text: text, autoTranslate: autoTranslate)
                }
            }
        }
    }

    func escPressed() {
        if Settings.shared.escCopy { SaveService.shared.copyToClipboard(canvas.flattened()) }
        if Settings.shared.escSave { _ = SaveService.shared.save(canvas.flattened()) }
        if Settings.shared.escCopy || Settings.shared.escSave {
            ToastHUD.show(Settings.shared.escCopy ? "Copied to clipboard" : "Saved")
        }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.controllers.removeAll { $0 === self }
    }
}

/// Clip view that centers the document view along any axis where the
/// document is smaller than the visible area (instead of pinning it to a corner).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let docFrame = doc.frame
        if rect.width > docFrame.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if rect.height > docFrame.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

// MARK: - Canvas

final class EditorCanvasView: NSView {
    private(set) var image: CapturedImage
    private var pixellatedCache: CGImage?

    var annotations: [Annotation] = []
    var currentTool: EditorTool = .select {
        didSet { window?.invalidateCursorRects(for: self); needsDisplay = true }
    }
    var currentColor: NSColor = .systemRed {
        didSet {
            if let sel = selected {
                registerUndoSnapshot()
                sel.color = currentColor
                needsDisplay = true
            }
        }
    }
    var onStateChange: (() -> Void)?
    var enclosingScroll: (() -> NSScrollView?)?

    private var selected: Annotation?
    private var drafting: Annotation?
    private var dragStartPoint: CGPoint = .zero
    private var isMovingSelection = false
    private var cropRect: CGRect?
    private var textField: NSTextField?
    private var editingTextAnnotation: TextAnnotation?

    init(image: CapturedImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image.pointSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    private var pxScale: CGFloat { image.scale }

    /// Remembered stroke width for the current tool (persisted across sessions).
    private var toolWidth: CGFloat { Settings.shared.toolWidth(for: currentTool.rawValue) }

    private func toPixel(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x * pxScale, y: viewPoint.y * pxScale)
    }

    private var pixellated: CGImage? {
        if pixellatedCache == nil {
            pixellatedCache = AnnotationRenderer.pixellate(image.cgImage, scale: pxScale)
        }
        return pixellatedCache
    }

    func flattened() -> CapturedImage {
        commitTextEditing()
        let cg = AnnotationRenderer.render(
            base: image.cgImage, annotations: annotations,
            pixellated: annotations.contains(where: { $0 is BlurAnnotation }) ? pixellated : nil
        )
        return CapturedImage(cgImage: cg, scale: pxScale)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image.cgImage, in: bounds)

        // annotations live in pixel space — scale the context down to points
        ctx.saveGState()
        ctx.scaleBy(x: 1 / pxScale, y: 1 / pxScale)
        let needsPixellated = annotations.contains(where: { $0 is BlurAnnotation })
            || drafting is BlurAnnotation
        let pix = needsPixellated ? pixellated : nil
        for a in annotations { a.draw(in: ctx, pixellated: pix) }
        drafting?.draw(in: ctx, pixellated: pix)

        if let sel = selected {
            drawSelectionChrome(around: sel.bounds, in: ctx)
        }
        ctx.restoreGState()

        if let crop = cropRect {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.beginPath()
            ctx.addRect(bounds)
            ctx.addRect(crop)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(crop)
        }
    }

    private func drawSelectionChrome(around rect: CGRect, in ctx: CGContext) {
        let r = rect.insetBy(dx: -4 * pxScale, dy: -4 * pxScale)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 * pxScale)
        ctx.setLineDash(phase: 0, lengths: [4 * pxScale, 3 * pxScale])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        let hs = 4 * pxScale
        ctx.setFillColor(NSColor.white.cgColor)
        for corner in [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ] {
            ctx.fill(CGRect(x: corner.x - hs, y: corner.y - hs, width: hs * 2, height: hs * 2))
        }
    }

    // MARK: undo

    private func snapshot() -> ([Annotation], CapturedImage) {
        (annotations.map { $0.copyAnnotation() }, image)
    }

    func registerUndoSnapshot() {
        let snap = snapshot()
        undoManager?.registerUndo(withTarget: self) { canvas in
            let redoSnap = canvas.snapshot()
            canvas.undoManager?.registerUndo(withTarget: canvas) { c2 in
                c2.restore(redoSnap)
            }
            canvas.restore(snap)
        }
    }

    private func restore(_ snap: ([Annotation], CapturedImage)) {
        annotations = snap.0
        if snap.1.cgImage !== image.cgImage {
            setImage(snap.1)
        }
        selected = nil
        needsDisplay = true
        onStateChange?()
    }

    private func setImage(_ newImage: CapturedImage) {
        image = newImage
        pixellatedCache = nil
        setFrameSize(newImage.pointSize)
        needsDisplay = true
        onStateChange?()
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        let vp = convert(event.locationInWindow, from: nil)
        let pp = toPixel(vp)
        dragStartPoint = pp

        switch currentTool {
        case .select:
            selected = annotations.reversed().first(where: { $0.hitTest(pp) })
            isMovingSelection = selected != nil
            if isMovingSelection { registerUndoSnapshot() }
            needsDisplay = true
        case .arrow, .line, .rect, .oval, .highlight:
            let kind: ShapeAnnotation.Kind = {
                switch currentTool {
                case .arrow: return .arrow
                case .line: return .line
                case .rect: return .rect
                case .oval: return .oval
                default: return .highlight
                }
            }()
            let shape = ShapeAnnotation(kind: kind, start: pp, end: pp, uiScale: pxScale)
            shape.color = currentTool == .highlight && currentColor == .systemRed
                ? .systemYellow : currentColor
            shape.strokeWidthPt = toolWidth
            drafting = shape
        case .pen:
            let pen = PenAnnotation(uiScale: pxScale)
            pen.color = currentColor
            pen.strokeWidthPt = toolWidth
            pen.points = [pp]
            drafting = pen
        case .blur:
            let blur = BlurAnnotation(uiScale: pxScale)
            blur.rect = CGRect(origin: pp, size: .zero)
            drafting = blur
        case .crop:
            cropRect = CGRect(origin: vp, size: .zero)
        case .text:
            beginTextEditing(atViewPoint: vp, pixelPoint: pp)
        case .counter:
            registerUndoSnapshot()
            let counter = CounterAnnotation(uiScale: pxScale)
            counter.center = pp
            counter.color = currentColor
            counter.number = (annotations.compactMap { ($0 as? CounterAnnotation)?.number }.max() ?? 0) + 1
            annotations.append(counter)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        let pp = toPixel(vp)

        switch currentTool {
        case .select:
            if isMovingSelection, let sel = selected {
                sel.move(by: CGPoint(x: pp.x - dragStartPoint.x, y: pp.y - dragStartPoint.y))
                dragStartPoint = pp
                needsDisplay = true
            }
        case .arrow, .line, .rect, .oval, .highlight:
            (drafting as? ShapeAnnotation)?.end = pp
            needsDisplay = true
        case .pen:
            (drafting as? PenAnnotation)?.points.append(pp)
            needsDisplay = true
        case .blur:
            if let blur = drafting as? BlurAnnotation {
                blur.rect = CGRect(
                    x: min(dragStartPoint.x, pp.x), y: min(dragStartPoint.y, pp.y),
                    width: abs(pp.x - dragStartPoint.x), height: abs(pp.y - dragStartPoint.y)
                )
                needsDisplay = true
            }
        case .crop:
            let startVp = CGPoint(x: dragStartPoint.x / pxScale, y: dragStartPoint.y / pxScale)
            cropRect = CGRect(
                x: min(startVp.x, vp.x), y: min(startVp.y, vp.y),
                width: abs(vp.x - startVp.x), height: abs(vp.y - startVp.y)
            )
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let draft = drafting {
            let big = draft.bounds.width > 2 || draft.bounds.height > 2 || draft is PenAnnotation
            if big {
                registerUndoSnapshot()
                annotations.append(draft)
            }
            drafting = nil
            needsDisplay = true
        }
        if currentTool == .crop, let crop = cropRect {
            cropRect = nil
            if crop.width > 4, crop.height > 4 {
                performCrop(viewRect: crop)
            }
            needsDisplay = true
        }
        isMovingSelection = false
    }

    private func performCrop(viewRect: CGRect) {
        registerUndoSnapshot()
        let px = CGRect(
            x: viewRect.minX * pxScale,
            y: (bounds.height - viewRect.maxY) * pxScale,
            width: viewRect.width * pxScale,
            height: viewRect.height * pxScale
        ).integral
        guard let cropped = image.cgImage.cropping(to: px) else { return }
        // shift annotations: new origin in bottom-left pixel coords
        let dx = viewRect.minX * pxScale
        let dy = viewRect.minY * pxScale
        for a in annotations {
            a.move(by: CGPoint(x: -dx, y: -dy))
        }
        setImage(CapturedImage(cgImage: cropped, scale: pxScale))
    }

    // MARK: text tool

    private func beginTextEditing(atViewPoint vp: CGPoint, pixelPoint pp: CGPoint) {
        commitTextEditing()
        let field = NSTextField(frame: CGRect(x: vp.x, y: vp.y - 12, width: 220, height: 26))
        field.font = .boldSystemFont(ofSize: 18)
        field.textColor = currentColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        field.isBordered = true
        field.focusRingType = .default
        field.placeholderString = "Text…"
        field.delegate = textDelegate
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field

        let ann = TextAnnotation(uiScale: pxScale)
        ann.color = currentColor
        ann.origin = pp
        editingTextAnnotation = ann
    }

    fileprivate func commitTextEditing() {
        guard let field = textField, let ann = editingTextAnnotation else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textField = nil
        editingTextAnnotation = nil
        if !text.isEmpty {
            registerUndoSnapshot()
            ann.text = text
            // origin currently marks click point; align so text draws above-right of it
            annotations.append(ann)
        }
        needsDisplay = true
    }

    private lazy var textDelegate = TextFieldDelegate(onEnd: { [weak self] in
        self?.commitTextEditing()
    })

    // MARK: keyboard & zoom

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // Esc
            (window?.windowController as? EditorWindowController)?.escPressed()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // delete
            if let sel = selected {
                registerUndoSnapshot()
                annotations.removeAll { $0 === sel }
                selected = nil
                needsDisplay = true
            }
            return
        }
        if flags.isEmpty {
            let toolKeys: [String: EditorTool] = [
                "v": .select, "a": .arrow, "l": .line, "r": .rect, "o": .oval,
                "h": .highlight, "p": .pen, "t": .text, "n": .counter, "b": .blur, "c": .crop,
            ]
            if let tool = toolKeys[chars] {
                (window?.windowController as? EditorWindowController)?.selectTool(tool)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard let wc = window?.windowController as? EditorWindowController else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command {
            switch chars {
            case "c": wc.copyImage(); return true
            case "s": wc.saveImage(); return true
            case "p": wc.pinImage(); return true
            case "z": undoManager?.undo(); return true
            case "w": window?.close(); return true
            case "0":
                enclosingScroll?()?.magnification = 1
                wc.refreshLabels()
                return true
            case "=", "+":
                zoom(by: 1.25); return true
            case "-":
                zoom(by: 0.8); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch chars {
            case "z": undoManager?.redo(); return true
            case "s": wc.saveImageAs(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func zoom(by factor: CGFloat) {
        guard let sv = enclosingScroll?() else { return }
        sv.magnification = min(8, max(0.1, sv.magnification * factor))
        (window?.windowController as? EditorWindowController)?.refreshLabels()
    }

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags
        // ⌘/Ctrl + scroll = zoom
        if mods.contains(.command) || mods.contains(.control) {
            guard let sv = enclosingScroll?() else { return }
            var delta = event.scrollingDeltaY
            if Settings.shared.zoomReverseScroll { delta = -delta }
            let factor = 1 + delta / 120
            let mouse = sv.contentView.convert(event.locationInWindow, from: nil)
            sv.setMagnification(min(8, max(0.1, sv.magnification * factor)), centeredAt: mouse)
            (window?.windowController as? EditorWindowController)?.refreshLabels()
            return
        }
        // Shift + scroll pans (scrollbars & pinch-zoom also available)
        if mods.contains(.shift) {
            super.scrollWheel(with: event)
            return
        }
        // plain scroll adjusts stroke width — but ONLY for stroke-based shapes
        // (arrow/line/rect/oval/pen). Anything else falls back to panning.
        let adjustable = selected.map(Self.isStrokeAnnotation) ?? Self.isStrokeTool(currentTool)
        guard adjustable else {
            trackpadAccum = 0
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas {
            trackpadAccum += event.scrollingDeltaY
            guard abs(trackpadAccum) >= 18 else { return }
            let step: CGFloat = trackpadAccum > 0 ? 0.5 : -0.5
            trackpadAccum = 0
            adjustStrokeWidth(by: step)
        } else {
            adjustStrokeWidth(by: event.scrollingDeltaY > 0 ? 0.5 : -0.5)
        }
    }

    private var trackpadAccum: CGFloat = 0

    static func isStrokeTool(_ tool: EditorTool) -> Bool {
        switch tool {
        case .arrow, .line, .rect, .oval, .pen: return true
        default: return false
        }
    }

    static func isStrokeAnnotation(_ a: Annotation) -> Bool {
        if let s = a as? ShapeAnnotation { return s.kind != .highlight }
        return a is PenAnnotation
    }

    /// Settings key for the annotation's tool, so adjusting a selected shape
    /// updates the right per-tool default.
    private func toolKey(for a: Annotation) -> String {
        if let s = a as? ShapeAnnotation {
            switch s.kind {
            case .arrow: return EditorTool.arrow.rawValue
            case .line: return EditorTool.line.rawValue
            case .rect: return EditorTool.rect.rawValue
            case .oval: return EditorTool.oval.rawValue
            case .highlight: return EditorTool.highlight.rawValue
            }
        }
        return EditorTool.pen.rawValue
    }

    private func adjustStrokeWidth(by step: CGFloat) {
        let color: NSColor
        let width: CGFloat
        if let sel = selected {
            sel.strokeWidthPt = min(20, max(1, sel.strokeWidthPt + step))
            Settings.shared.setToolWidth(sel.strokeWidthPt, for: toolKey(for: sel))
            width = sel.strokeWidthPt
            color = sel.color
        } else {
            width = min(20, max(1, toolWidth + step))
            Settings.shared.setToolWidth(width, for: currentTool.rawValue)
            color = currentColor
        }
        showStrokeHUD(width: width, color: color)
        needsDisplay = true
    }

    private var strokeHUD: StrokePreviewView?
    private var strokeHUDHide: DispatchWorkItem?

    /// HUD with a real line sample drawn at the exact thickness & color.
    private func showStrokeHUD(width: CGFloat, color: NSColor) {
        let hud: StrokePreviewView
        if let existing = strokeHUD {
            hud = existing
        } else {
            hud = StrokePreviewView(frame: CGRect(x: 0, y: 0, width: 190, height: 44))
            addSubview(hud)
            strokeHUD = hud
        }
        hud.strokeWidth = width
        hud.color = color
        let vis = visibleRect
        hud.frame.origin = CGPoint(x: vis.midX - 95, y: vis.minY + 16)
        hud.isHidden = false
        hud.needsDisplay = true
        strokeHUDHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.strokeHUD?.isHidden = true }
        strokeHUDHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    override func resetCursorRects() {
        switch currentTool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }
}

/// Floating sample: a line stroked at the actual width & color, plus the number.
final class StrokePreviewView: NSView {
    var strokeWidth: CGFloat = 3
    var color: NSColor = .systemRed

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.82).setFill()
        bg.fill()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: 16, y: bounds.midY))
        line.line(to: NSPoint(x: bounds.width - 66, y: bounds.midY))
        line.lineWidth = strokeWidth
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = String(format: "%.1f pt", strokeWidth) as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: bounds.width - 12 - size.width, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }
}

private final class TextFieldDelegate: NSObject, NSTextFieldDelegate {
    let onEnd: () -> Void
    init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEnd()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onEnd()
    }
}
