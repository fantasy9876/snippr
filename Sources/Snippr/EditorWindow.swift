import AppKit

// MARK: - Editor window controller

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [EditorWindowController] = []

    private let canvas: EditorCanvasView
    private var sizeBadge: NSButton!
    private var zoomLabel: NSTextField!
    private var colorWell: NSColorWell!
    private var toolButtons: [EditorTool: NSButton] = [:]
    /// Anchor for the preset menu. A production reference, not the testing
    /// accessor — a gate seam must never be the app's own router.
    private var backdropButton: NSButton?
    private var actionButtons: [(name: String, button: NSButton)] = []
    let hoverHint = HoverHint()

    /// The five terminal buttons and the right-hand chrome, by identity.
    var actionButtonsForTesting: [(name: String, button: NSButton)] {
        actionButtons
    }
    var colorWellForTesting: NSColorWell { colorWell }
    var sizeBadgeForTesting: NSButton { sizeBadge }
    var zoomLabelForTesting: NSTextField { zoomLabel }
    private var cropApplyButton: NSButton!
    private var cropCancelButton: NSButton!
    private var cropActionBar: NSStackView!
    private var scrollView: NSScrollView!
    private var documentWrapper: BackdropDocumentView!
    private var keepsImageFitted = true
    private let forceFitForTesting: Bool

    /// Warms the toolbar's SF Symbols and the text/graphics stacks. Deliberately
    /// does NOT build a window: a throwaway window left the first real editor
    /// opening behind the frontmost app.
    static func prewarm() {
        let symbols = ["doc.on.doc", "square.and.arrow.down", "pin", "text.viewfinder", "globe"]
            + EditorTool.allCases.map(\.symbol)
        for name in symbols {
            _ = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
    }

    @discardableResult
    static func open(
        with image: CapturedImage, forceFitForTesting: Bool = false
    ) -> EditorWindowController {
        let wc = EditorWindowController(image: image, forceFitForTesting: forceFitForTesting)
        controllers.append(wc)
        // macOS 14+ can refuse activation for a menu-bar app, which used to
        // leave the first capture's editor stranded behind the frontmost app.
        // Open floating so it is always visible, then drop to a normal window
        // once the app truly holds focus (see windowDidBecomeKey).
        wc.window?.level = .floating
        wc.showWindow(nil)
        wc.window?.orderFrontRegardless()
        AppActivation.activateNow()
        wc.window?.makeKeyAndOrderFront(nil)
        return wc
    }

    init(image: CapturedImage, forceFitForTesting: Bool = false) {
        canvas = EditorCanvasView(image: image)
        self.forceFitForTesting = forceFitForTesting

        // Two rows of controls; see buildUI.
        let toolbarHeight: CGFloat = 70
        let minimumViewportHeight: CGFloat = 120
        let contentSize = image.pointSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxSize = CGSize(
            width: screen.visibleFrame.width * 0.9,
            height: screen.visibleFrame.height * 0.9 - toolbarHeight
        )
        let winW = min(max(contentSize.width, 560), maxSize.width)
        // `contentMinSize` constrains user resizing, but AppKit may leave an
        // already-created programmatic window below that floor. Construct the
        // initial content rect with the same minimum so a tiny/Retina image
        // still has a usable viewport on every architecture.
        let winH = min(
            max(contentSize.height, minimumViewportHeight), maxSize.height)
            + toolbarHeight

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // The tool row needs 560pt; without a floor the user could drag the
        // window narrower and push buttons out of reach.
        window.contentMinSize = CGSize(
            width: 560, height: toolbarHeight + minimumViewportHeight)
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
        canvas.onStateChange = { [weak self] in
            self?.refreshBackdropLayout()
            self?.refreshLabels()
        }
        canvas.onImageChange = { [weak self] in
            self?.refreshBackdropLayout()
            guard let self, self.keepsImageFitted else { return }
            // NSScrollView updates its document geometry on the next layout
            // pass after a crop/undo. Fit after that pass, not against stale bounds.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.keepsImageFitted else { return }
                self.fitImageToWindow()
            }
        }
        canvas.onCropSelectionChange = { [weak self] isValid in
            self?.cropApplyButton?.isEnabled = isValid
            // The pending crop changes what an export would produce, so the
            // size the badge reports moves with it.
            self?.refreshLabels()
        }
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
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        // A 20,000-pt scrolling screenshot can need well below 10% to fit a
        // laptop viewport. Keeping the old 10% floor forced scrollbars even in
        // Fit mode—the exact long-image layout Fit is meant to avoid.
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)
        // keeps the shot centered when it's smaller than the window
        scrollView.contentView = CenteringClipView()
        documentWrapper = BackdropDocumentView(
            canvas: canvas, layout: canvas.backdropLayout)
        scrollView.documentView = documentWrapper
        canvas.enclosingScroll = { [weak self] in self?.scrollView }

        // --- top bar
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
            let b = NSButton(
                image: SliceBSymbols.image(
                    named: symbol, fallback: "questionmark.square.dashed")
                    ?? NSImage(size: NSSize(width: 16, height: 16)),
                target: self, action: action
            )
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.contentTintColor = .lightGray
            b.toolTip = tooltip
            // A tooltip is not an accessibility label; VoiceOver reads this.
            b.setAccessibilityLabel(tooltip)
            b.image?.accessibilityDescription = tooltip
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 30),
                b.heightAnchor.constraint(equalToConstant: 28),
            ])
            return b
        }

        let copyBtn = makeButton(symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: #selector(copyImage))
        // Captured as the row is built, so a gate reads the REAL controls
        // instead of discovering them by the very tooltip or action it then
        // asserts on.
        let saveBtn = makeButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", action: #selector(saveImage))
        let pinBtn = makeButton(symbol: "pin", tooltip: "Pin to screen (⌘P)", action: #selector(pinImage))
        let ocrBtn = makeButton(symbol: "text.viewfinder", tooltip: "Recognize text (OCR)", action: #selector(runOCR))
        let translateBtn = makeButton(symbol: "globe", tooltip: "OCR + Translate", action: #selector(runTranslate))
        actionButtons = [
            ("copy", copyBtn), ("save", saveBtn), ("pin", pinBtn),
            ("ocr", ocrBtn), ("translate", translateBtn),
        ]

        var toolViews: [NSView] = []
        for tool in EditorTool.allCases {
            // Backdrop is a document style, so its button opens the preset
            // menu rather than entering a drawing mode.
            let action = tool == .backdrop
                ? #selector(showBackdropMenu(_:))
                : #selector(toolTapped(_:))
            let b = makeButton(symbol: tool.symbol, tooltip: tool.tooltip, action: action)
            b.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            toolButtons[tool] = b
            if tool == .backdrop { backdropButton = b }
            toolViews.append(b)
        }

        // Crop actions float over the scroll viewport at a fixed screen size.
        // A very tall/narrow scrolling capture can be only a few screen pixels
        // wide when fitted, so image-relative or crowded toolbar controls are
        // not reliably visible/clickable.
        let cropApply = NSButton(title: "Crop", target: self, action: #selector(applyCropFromToolbar))
        cropApply.bezelStyle = .rounded
        cropApply.keyEquivalent = "\r"
        cropApply.toolTip = "Apply crop (Return)"
        cropApply.translatesAutoresizingMaskIntoConstraints = false
        cropApply.widthAnchor.constraint(equalToConstant: 78).isActive = true
        cropApply.isEnabled = false
        let cropCancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCropFromToolbar))
        cropCancel.bezelStyle = .rounded
        cropCancel.toolTip = "Cancel crop (Esc)"
        cropCancel.translatesAutoresizingMaskIntoConstraints = false
        cropCancel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        cropApplyButton = cropApply
        cropCancelButton = cropCancel

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

        sizeBadge = NSButton(title: "", target: self, action: #selector(sizeBadgeClicked))
        sizeBadge.isBordered = false
        sizeBadge.bezelStyle = .inline
        sizeBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeBadge.contentTintColor = .secondaryLabelColor
        sizeBadge.toolTip = "Scale image — independent of “Resize retina screenshots” on save"

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

        // TWO explicit rows. Fifteen tools plus the terminal actions and the
        // right-hand chrome cannot fit one 30pt row in a 560pt window, and
        // hiding or compressing buttons would make them unreachable, so the
        // tools get a row of their own.
        let actionRow = NSStackView(
            views: [leftPad, copyBtn, saveBtn, pinBtn, ocrBtn, translateBtn,
                    sep(), colorWell, NSView(), sizeBadge, sep(), zoomLabel])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fill
        actionRow.spacing = 2
        actionRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 14)
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        if let flexible = actionRow.arrangedSubviews.dropLast(3).last {
            actionRow.setHuggingPriority(.defaultLow, for: .horizontal)
            flexible.setContentHuggingPriority(.init(1), for: .horizontal)
        }

        let toolRow = NSStackView(views: toolViews + [NSView()])
        toolRow.orientation = .horizontal
        toolRow.distribution = .fill
        toolRow.spacing = 2
        toolRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 14)
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        toolRow.setHuggingPriority(.defaultLow, for: .horizontal)
        toolRow.arrangedSubviews.last?
            .setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [actionRow, toolRow])
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        // A vertical stack offers only leading/centre/trailing alignment, so
        // neither of those makes a row fill the bar — and both rows need to:
        // the tool row ends in a flexible spacer, and the action row puts its
        // chrome against the right edge. Explicit constraints, which take
        // precedence over the stack's own alignment.
        NSLayoutConstraint.activate([
            actionRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            toolRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        let cropActions = NSStackView(views: [cropApply, cropCancel])
        cropActions.orientation = .horizontal
        cropActions.spacing = 6
        cropActions.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        cropActions.translatesAutoresizingMaskIntoConstraints = false
        cropActions.wantsLayer = true
        cropActions.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        cropActions.layer?.cornerRadius = 9
        cropActions.isHidden = true
        cropActionBar = cropActions

        // The editor is an ordinary window, but it uses the same hint so all
        // three hosts read the same way — and so a shortcut is visible on
        // hover rather than only in an accessibility inspector.
        hoverHint.attach(
            to: toolButtons.values.map { $0 }
                + actionButtons.map { $0.button } + [sizeBadge])
        contentView.addSubview(scrollView)
        contentView.addSubview(bar)
        contentView.addSubview(cropActions)
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
            cropActions.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            cropActions.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -12),
            cropActions.heightAnchor.constraint(equalToConstant: 38),
        ])

        selectTool(.select)
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(canvas)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyWillStart(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollGeometryDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    private func applyInitialZoom() {
        guard let scrollView else { return }
        if Settings.shared.preferZoom100 && !forceFitForTesting {
            keepsImageFitted = false
            scrollView.magnification = 1
        } else {
            fitImageToWindow()
        }
        refreshLabels()
    }

    /// Fits the entire image in the actual clip viewport. A tiny inset avoids
    /// a fractional-point overflow that otherwise makes both macOS scrollers
    /// flash for images whose aspect ratio nearly matches the editor window.
    func fitImageToWindow() {
        guard let scrollView else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        // `clipView.bounds` is expressed in document coordinates and therefore
        // changes with magnification. `contentSize` is the physical viewport,
        // so repeated fits after resize/crop stay stable instead of oscillating.
        let visible = scrollView.contentSize
        // The frame is part of what has to fit: fitting the image alone would
        // push the padding out of view, which is exactly what the user opened
        // the backdrop to look at.
        let imageSize = canvas.backdropLayout.outerPointSize
        guard visible.width > 2, visible.height > 2,
              imageSize.width > 0, imageSize.height > 0 else { return }
        let fit = min(
            (visible.width - 2) / imageSize.width,
            (visible.height - 2) / imageSize.height,
            1
        )
        keepsImageFitted = true
        scrollView.magnification = max(scrollView.minMagnification, fit)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshLabels()
    }

    func userDidChangeZoom() {
        keepsImageFitted = false
        refreshLabels()
        canvas.magnificationDidChange()
    }

    @objc private func liveMagnifyWillStart(_ notification: Notification) {
        // Native trackpad pinch is performed by NSScrollView, bypassing the
        // canvas' command/scroll zoom handlers. Mark it as a user zoom before
        // the first geometry change so a later resize does not snap back to Fit.
        keepsImageFitted = false
        refreshLabels()
    }

    @objc private func scrollGeometryDidChange(_ notification: Notification) {
        refreshLabels()
        canvas.magnificationDidChange()
        canvas.invalidatePointerAfterScroll()
    }

    /// UI-test hook: checks geometry rather than `NSScroller.isHidden`, whose
    /// overlay fade animation is timing-dependent. If the image fits in the
    /// clip view's document-coordinate bounds, neither scrollbar is needed.
    func imageFitsViewportForTesting(tolerance: CGFloat = 1) -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let visibleDocumentRect = scrollView.contentView.bounds
        // The frame counts: measuring the image alone would call a document
        // fitted while its backdrop is cut off at the edges.
        let imageSize = canvas.backdropLayout.outerPointSize
        return imageSize.width <= visibleDocumentRect.width + tolerance
            && imageSize.height <= visibleDocumentRect.height + tolerance
    }

    /// UI-test hook: ⌘+scroll on the canvas must change the scroll view's
    /// magnification (zoom in for a positive wheel delta unless the reverse
    /// preference is on) — the zoom path a scrolling capture relies on now
    /// that it opens in the Editor. Drives the REAL `scrollWheel(with:)` with
    /// a synthesized command-modified wheel event.
    func commandScrollZoomForTesting(deltaY: Double = 40) -> (before: CGFloat, after: CGFloat)? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: Int32(deltaY), wheel2: 0, wheel3: 0)
        else { return nil }
        cg.flags = .maskCommand
        if let window {
            let center = window.convertPoint(toScreen: NSPoint(
                x: window.frame.width / 2, y: window.frame.height / 2))
            // CGEvent locations are top-left based.
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: center.x, y: screenHeight - center.y)
        }
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        let before = scrollView.magnification
        canvas.scrollWheel(with: event)
        return (before, scrollView.magnification)
    }

    /// UI-test hook for the fixed crop actions used when the fitted image is
    /// too narrow to contain image-relative controls.
    func cropActionControlsReadyForTesting() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let content = window?.contentView, let cropActionBar else { return false }
        let barFrame = cropActionBar.convert(cropActionBar.bounds, to: content)
        return cropActionBar.isHidden == false
            && content.bounds.contains(barFrame)
            && cropApplyButton.isEnabled == false
    }

    /// The wrapper follows the document; both read the same layout, so the
    /// preview cannot describe a different frame than the export produces.
    func refreshBackdropLayout() {
        let layout = canvas.backdropLayout
        guard let documentWrapper, documentWrapper.layout != layout else { return }
        documentWrapper.applyLayout(layout)
        if let scrollView {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        // Adding a frame makes the document bigger, so a view that was fitted
        // is no longer fitted: keeping the old magnification pushes the very
        // padding the user just asked for out of the viewport. Removing one
        // leaves the document under-zoomed for the same reason. Refit after the
        // layout pass, exactly as an image change does.
        guard keepsImageFitted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keepsImageFitted else { return }
            self.fitImageToWindow()
        }
    }

    func refreshLabels() {
        // The EXPORT layout, not the live one: while a crop is pending, what
        // Save writes is the cropped document, and the badge claims to report
        // the exported size.
        let layout = canvas.exportLayout
        // The badge reports what would be EXPORTED. Showing the inner size
        // while a frame is on would understate the file the user is about to
        // produce; the inner size stays visible in the tooltip.
        let size = layout.outerPointSize
        let px = layout.outerPixelSize
        // Not truncated: an odd pixel size on a Retina document lands on a
        // half point, and rounding it down misreports the export.
        func pt(_ value: CGFloat) -> String {
            value == value.rounded()
                ? "\(Int(value))"
                : String(format: "%.1f", Double(value))
        }
        sizeBadge.title = "\(pt(size.width))×\(pt(size.height))pt"
        let innerPx = layout.innerPixelSize
        let frameNote = layout.isCollapsed
            ? ""
            : " (image \(Int(innerPx.width))×\(Int(innerPx.height)) px"
                + " + \(Int(layout.padPixels)) px backdrop)"
        // Through the hint, never `toolTip`: writing the native tooltip back
        // would give this button two descriptions, and the hint would keep
        // quoting the size the image had before this layout.
        hoverHint.setText(
            "\(Int(px.width))×\(Int(px.height)) px\(frameNote) — click to scale. "
                + "Does not change “Resize retina screenshots” on save.",
            for: sizeBadge)
        let pct = Int(round((scrollView?.magnification ?? 1) * 100))
        zoomLabel.stringValue = "\(pct)%"
    }

    var sizeBadgeTitleForTesting: String { sizeBadge.title }

    @objc private func sizeBadgeClicked() {
        let menu = NSMenu()
        menu.addItem(withTitle: sizeBadge.title, action: nil, keyEquivalent: "")
        menu.items.last?.isEnabled = false
        menu.addItem(.separator())
        for (title, factor) in [
            ("Scale to 50%", 0.5),
            ("Scale to 100%", 1.0),
            ("Scale to 200%", 2.0),
        ] as [(String, CGFloat)] {
            let item = NSMenuItem(
                title: title, action: #selector(resizeMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = factor
            menu.addItem(item)
        }
        let custom = NSMenuItem(
            title: "Custom…", action: #selector(resizeCustom), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        let loc = NSPoint(x: 0, y: sizeBadge.bounds.height)
        menu.popUp(positioning: nil, at: loc, in: sizeBadge)
    }

    @objc private func resizeMenuItem(_ sender: NSMenuItem) {
        guard let factor = sender.representedObject as? CGFloat else { return }
        applyResizeFactor(factor)
    }

    @objc private func resizeCustom() {
        let alert = NSAlert()
        alert.messageText = "Scale image"
        alert.informativeText = "Percent of current size (e.g. 75). Does not change the retina-on-save preference."
        alert.addButton(withTitle: "Scale")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "100")
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let percent = field.doubleValue
        guard percent.isFinite, percent > 0 else { return }
        applyResizeFactor(CGFloat(percent / 100))
    }

    func applyResizeFactor(_ factor: CGFloat) {
        canvas.applyPixelScale(factor)
        refreshLabels()
    }

    var canvasForTesting: EditorCanvasView { canvas }

    /// The REAL scroll document, so a gate reads what the user scrolls rather
    /// than a wrapper built for the occasion.
    var documentWrapperForTesting: BackdropDocumentView? {
        scrollView?.documentView as? BackdropDocumentView
    }

    var scrollMagnificationForTesting: CGFloat { scrollView?.magnification ?? 0 }
    var scrollViewportForTesting: CGSize { scrollView?.contentSize ?? .zero }

    /// Slice B seam: the real toolbar buttons, in `EditorTool.allCases` order,
    /// so a gate can assert overflow/wrap and accessibility on the production
    /// toolbar rather than on a re-created copy.
    var toolButtonsForTesting: [(tool: EditorTool, button: NSButton)] {
        EditorTool.allCases.compactMap { tool in
            toolButtons[tool].map { (tool, $0) }
        }
    }

    func selectTool(_ tool: EditorTool) {
        // Authoritative for the toolbar, the keyboard and the menu alike: a
        // hint left standing after a switch describes the previous tool.
        hoverHint.hide()
        canvas.currentTool = tool
        let cropping = tool == .crop
        cropActionBar?.isHidden = !cropping
        cropApplyButton?.isEnabled = cropping && canvas.hasValidCropSelection
        for (t, b) in toolButtons {
            b.contentTintColor = t == tool ? .controlAccentColor : .lightGray
        }
    }

    // MARK: actions

    /// Applies a backdrop preset. Kept separate from tool selection so picking
    /// the tool is never itself an edit.
    func applyBackdropPresetForTesting(_ preset: BackdropPreset) {
        canvas.applyBackdrop(preset)
    }

    /// The real preset menu. Opening it changes nothing; only choosing an item
    /// applies a preset, and choosing the current one is a no-op.
    /// One policy for both entry points: never touches the active tool.
    func openBackdropChooser() {
        guard let button = backdropButton else { return }
        showBackdropMenu(button)
    }

    /// Built separately from being shown: `popUp` runs a nested event loop, so
    /// a headless gate can exercise the real items, targets and actions only if
    /// construction stands on its own.
    func backdropMenu() -> NSMenu {
        let menu = NSMenu(title: "Backdrop")
        for (index, preset) in BackdropPreset.allCases.enumerated() {
            let item = NSMenuItem(
                title: preset == .none ? "None" : preset.rawValue.capitalized,
                action: #selector(backdropPresetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            // The menu has two sections now. Naming them is what lets a gate
            // say "one preset ticked and one corner ticked" instead of
            // counting rows and hoping.
            item.identifier = SliceBBackdrop.presetItemIdentifier
            item.state = preset == canvas.backdropPreset ? .on : .off
            menu.addItem(item)
        }
        // The corner choice lives in the SAME menu as the preset: it is a
        // property of the frame, and a user looking for it will look here
        // before they look in Settings.
        menu.addItem(.separator())
        for style in BackdropCornerStyle.allCases {
            let item = NSMenuItem(
                title: style.title,
                action: #selector(backdropCornerChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = BackdropCornerStyle.allCases.firstIndex(of: style) ?? 0
            item.identifier = SliceBBackdrop.cornerItemIdentifier
            item.state = style == SliceBBackdrop.cornerStyle ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Sender is an NSMenuItem, so the style travels as an Int tag.
    @objc func backdropCornerChosen(_ sender: NSMenuItem) {
        let styles = BackdropCornerStyle.allCases
        guard styles.indices.contains(sender.tag) else { return }
        Settings.shared.backdropCornerStyle = styles[sender.tag]
        // NOT `refreshBackdropLayout()`: that returns early when the layout is
        // unchanged, and the corner style is not part of the layout — it is
        // read live from Settings. Going through it left the document's clip
        // and the caption's mask on the OLD radius while the frame, the
        // hairline and the corner hit test had already moved to the new one:
        // preview against export, and a corner that looked cut while still
        // swallowing clicks.
        documentWrapper?.applyLayout(canvas.backdropLayout)
        documentWrapper?.needsDisplay = true
        canvas.needsDisplay = true
    }

    @objc func showBackdropMenu(_ sender: NSButton) {
        // popUp runs a nested event loop: a hint still on screen would sit
        // under the menu until the loop exits.
        hoverHint.hide()
        let menu = backdropMenu()
        backdropMenuForTesting = menu
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// Sender is an NSMenuItem, so the preset travels as an Int tag rather than
    /// a Swift enum, which is not representable in Objective-C.
    @objc func backdropPresetChosen(_ sender: NSMenuItem) {
        let presets = BackdropPreset.allCases
        guard presets.indices.contains(sender.tag) else { return }
        canvas.applyBackdrop(presets[sender.tag])
    }

    private(set) var backdropMenuForTesting: NSMenu?

    @objc private func toolTapped(_ sender: NSButton) {
        hoverHint.hide()
        guard let id = sender.identifier?.rawValue, let tool = EditorTool(rawValue: id) else { return }
        selectTool(tool)
    }

    @objc private func applyCropFromToolbar() {
        canvas.applyCropSelection()
    }

    @objc private func cancelCropFromToolbar() {
        canvas.cancelCropSelection()
        selectTool(.select)
    }

    @objc private func colorChanged() {
        canvas.currentColor = colorWell.color
        Settings.shared.lastAnnotationColor = colorWell.color
    }

    /// Every terminal action is transactional: if the flatten fails we keep
    /// the session exactly as it was — nothing exported, nothing closed — and
    /// tell the user. Silently writing the un-redacted base would be the worst
    /// possible outcome here.
    /// Terminal-action dependencies, injectable exactly like the overlay
    /// action router. A gate counts real calls instead of inferring "nothing
    /// happened" from the clipboard alone.
    struct TerminalDependencies {
        var copyToClipboard: @MainActor (CapturedImage) -> Void = {
            SaveService.shared.copyToClipboard($0)
        }
        var saveAs: @MainActor (
            CapturedImage, NSWindow, @escaping @MainActor (SaveAsOutcome) -> Void
        ) -> Void = { image, window, done in
            SaveService.shared.saveAs(image, for: window, completion: done)
        }
        var autoSave: @MainActor (
            CapturedImage, @escaping @MainActor (URL?) -> Void
        ) -> Void = { image, done in
            SaveService.shared.save(image, completion: done)
        }
        var pin: @MainActor (CapturedImage) -> Void = { PinWindow.pin($0) }
        /// Performs the ENTIRE recognize operation. Overriding it must replace
        /// the work, not observe it — an observer plus a hardcoded call would
        /// make a spy that counts zero prove nothing.
        var recognize: @MainActor (CapturedImage, Bool) -> Void = {
            image, autoTranslate in
            Task {
                let result = await OCRService.shared.recognize(image.cgImage)
                await MainActor.run {
                    let text = result.clipboardText
                    if text.isEmpty {
                        ToastHUD.show(
                            "No text found", symbol: "text.magnifyingglass")
                    } else {
                        SaveService.copyText(text)
                        TextResultWindow.show(
                            text: text, autoTranslate: autoTranslate)
                    }
                }
            }
        }

        /// Explicit init: a nested struct of main-actor closures does not get a
        /// usable memberwise initializer, and gates need to override one field
        /// at a time.
        init(
            copyToClipboard: (@MainActor (CapturedImage) -> Void)? = nil,
            saveAs: (@MainActor (
                CapturedImage, NSWindow,
                @escaping @MainActor (SaveAsOutcome) -> Void) -> Void)? = nil,
            autoSave: (@MainActor (
                CapturedImage,
                @escaping @MainActor (URL?) -> Void) -> Void)? = nil,
            pin: (@MainActor (CapturedImage) -> Void)? = nil,
            recognize: (@MainActor (CapturedImage, Bool) -> Void)? = nil
        ) {
            if let copyToClipboard { self.copyToClipboard = copyToClipboard }
            if let saveAs { self.saveAs = saveAs }
            if let autoSave { self.autoSave = autoSave }
            if let pin { self.pin = pin }
            if let recognize { self.recognize = recognize }
        }
    }

    var terminalDependencies = TerminalDependencies()

    private func flattenedOrWarn() -> CapturedImage? {
        // The message must name what actually failed: a backdrop frame that
        // could not be composed is not a redaction problem, and telling the
        // user to check their redactions sends them looking in the wrong place.
        var reason = EditorCanvasView.FlattenFailure.render
        guard let flat = canvas.flattened(failure: &reason) else {
            switch reason {
            case .render:
                ToastHUD.show(
                    "Couldn't render the redaction — nothing was exported",
                    symbol: "exclamationmark.triangle.fill")
            case .backdrop:
                ToastHUD.show(
                    "Couldn't render the backdrop — nothing was exported",
                    symbol: "exclamationmark.triangle.fill")
            }
            return nil
        }
        return flat
    }

    @objc func copyImage() {
        hoverHint.hide()
        guard let flat = flattenedOrWarn() else { return }
        terminalDependencies.copyToClipboard(flat)
        ToastHUD.show("Copied to clipboard")
        window?.close()
    }

    /// ⌘S / Save button: choose where to save via the system panel. Shares
    /// SaveService.saveAs with the overlay action router so the panel/write
    /// behavior cannot drift between the two surfaces.
    @objc func saveImage() {
        hoverHint.hide()
        guard let window else { return }
        // A failed render must change nothing, so the cancel happens only once
        // the flatten has actually succeeded — and before the panel opens, so
        // what is saved is exactly what the user saw.
        guard let flat = flattenedOrWarn() else { return }
        canvas.cancelRedactionJobsForSaveLock()
        terminalDependencies.saveAs(flat, window) { outcome in
            switch outcome {
            case let .saved(url):
                ToastHUD.show(
                    "Saved \(url.lastPathComponent)",
                    symbol: "square.and.arrow.down.fill")
            case .failed:
                ToastHUD.show(
                    "Save failed", symbol: "exclamationmark.triangle.fill")
            case .cancelled:
                break
            }
        }
    }

    @objc func saveImageAs() { saveImage() }

    @objc func pinImage() {
        hoverHint.hide()
        guard let flat = flattenedOrWarn() else { return }
        terminalDependencies.pin(flat)
        window?.close()
    }

    @objc func runOCR() {
        hoverHint.hide()
        recognizeText(autoTranslate: false)
    }
    @objc func runTranslate() {
        hoverHint.hide()
        recognizeText(autoTranslate: true)
    }

    private func recognizeText(autoTranslate: Bool) {
        guard let flat = flattenedOrWarn() else { return }
        terminalDependencies.recognize(flat, autoTranslate)
    }

    func escPressed() {
        let s = Settings.shared
        if s.escCopy || s.escSave {
            // flatten ONCE and share it — escCopy+escSave used to render the
            // whole image twice back to back
            guard let flat = flattenedOrWarn() else { return }
            if s.escCopy {
                terminalDependencies.copyToClipboard(flat)
                ToastHUD.show("Copied to clipboard")
            }
            if s.escSave {
                let announce = !s.escCopy
                terminalDependencies.autoSave(flat) { url in
                    // toast only when the save actually landed (or failed)
                    if let url {
                        if announce { ToastHUD.show("Saved \(url.lastPathComponent)") }
                    } else {
                        ToastHUD.show("Save failed", symbol: "exclamationmark.triangle.fill")
                    }
                }
            }
        }
        window?.close()
    }

    /// Once the app truly holds focus the editor behaves like a normal
    /// window, so switching apps layers it as users expect. The NSApp.isActive
    /// check matters: dropping the level while another app still has focus
    /// would sink the window behind it — the "jumping" bug.
    func windowDidBecomeKey(_ notification: Notification) {
        if NSApp.isActive, !Settings.shared.alwaysOnTop, window?.level == .floating {
            window?.level = .normal
        }
    }

    func windowDidResize(_ notification: Notification) {
        if keepsImageFitted { fitImageToWindow() }
    }

    func windowWillClose(_ notification: Notification) {
        // The hint holds tracking areas on buttons that are about to go away,
        // and may have one scheduled to fire into this closing window.
        hoverHint.detachAll()
        // Closing supersedes every OCR job in flight: a late result must not
        // touch annotations belonging to a window that is gone.
        for blur in canvas.annotations.compactMap({ $0 as? BlurAnnotation }) {
            canvas.redactionRegistry.cancel(for: blur)
        }
        canvas.redactionRegistry.cancelAll()
        NotificationCenter.default.removeObserver(self)
        PixelSamplerCache.release(canvas.image.cgImage)
        EditorWindowController.controllers.removeAll { $0 === self }
    }
}

/// Scroll document that wraps the canvas in its backdrop.
///
/// The canvas keeps its own size and its own coordinates and simply sits at an
/// offset inside this view; nothing about the document is translated or baked.
/// Because the padding belongs to THIS view and not to the canvas, a pointer
/// out in the frame is outside the canvas entirely and can never resolve to a
/// source pixel.
final class BackdropDocumentView: NSView {
    private let canvas: EditorCanvasView
    private(set) var layout: BackdropLayout

    init(canvas: EditorCanvasView, layout: BackdropLayout) {
        self.canvas = canvas
        self.layout = layout
        super.init(frame: CGRect(origin: .zero, size: layout.outerPointSize))
        // Since macOS 14 a view does NOT clip to its bounds by default, and a
        // frame drawn past this one's edge lands on the scroll view. The fill
        // clips itself now; this is the second line of defence, and it also
        // bounds the shadow.
        clipsToBounds = true
        addSubview(canvas)
        applyLayout(layout)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func applyLayout(_ layout: BackdropLayout) {
        self.layout = layout
        // A framed document is composed in sRGB, so the window it is reviewed
        // in has to be sRGB as well: on a P3 display the preview would
        // otherwise show source colours the export has already clipped, and
        // the two could never be compared. `.none` hands the window back to
        // the system, keeping a P3 document's colours on screen.
        window?.colorSpace = layout.isCollapsed ? nil : .sRGB
        setFrameSize(layout.outerPointSize)
        canvas.setFrameOrigin(layout.innerPointRect.origin)
        canvas.setFrameSize(layout.innerPointSize)
        // The export clips the document to the same rounded rect the plate
        // draws. Without this the preview shows square corners over a rounded
        // plate and the user reviews something the export will not produce.
        //
        // The draw-path clip shapes the canvas's own body and survives every
        // render that calls draw directly.
        //
        // What is deliberately NOT here any more: `layer.cornerRadius` with
        // `masksToBounds`. This canvas lives inside an NSScrollView with
        // magnification, and a masked layer is rasterized once at the backing
        // scale and then SCALED — which is precisely the stepped, pixelated
        // frame edge the report was about, and it made the preview disagree
        // with an export that antialiases correctly. The live text field, the
        // one subview that needed the layer mask, carries its own clip now.
        let radius = layout.isCollapsed
            ? 0
            : SliceBBackdrop.cornerRadius(
                documentPoints: layout.innerPointSize,
                style: SliceBBackdrop.cornerStyle)
        canvas.documentCornerRadius = radius
        canvas.layer?.cornerRadius = 0
        canvas.layer?.masksToBounds = false
        canvas.updateTextEntryClip()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !layout.isCollapsed,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Drawn in POINTS here; the same routine works in pixels for the
        // export because every metric it uses is scaled by the caller.
        SliceBBackdrop.drawFrame(
            in: ctx, size: layout.outerPointSize,
            target: layout.innerPointRect, preset: layout.preset,
            // Radius and shadow are POINT metrics and this context is in
            // points, so their scale is 1. The grain is not: its period is
            // fixed in DOCUMENT pixels, so at @2x a 128px tile has to be drawn
            // 64pt wide or the preview shows a grain twice the exported one.
            pixelScale: 1,
            documentPixelsPerUserUnit: layout.pixelScale)
    }

    /// The frame is decoration: clicks in it belong to no tool, and must not
    /// fall through to the canvas either.
    ///
    /// The rounded corners count as frame. The canvas is still a rectangle, so
    /// its corner cut-outs sit inside its frame while being invisible and
    /// absent from the export — picking, drawing or cropping there would act on
    /// pixels the user cannot see and will not get.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit !== self else { return nil }
        if !layout.isCollapsed, hit === canvas || hit?.isDescendant(of: canvas) == true {
            let inner = layout.innerPointRect
            // The hit shape follows the DRAWN shape: a corner that looks cut
            // but still swallows clicks is a worse lie than a square one.
            let radius = SliceBBackdrop.cornerRadius(
                documentPoints: layout.innerPointSize,
                style: SliceBBackdrop.cornerStyle)
            let rounded = CGPath(
                roundedRect: inner, cornerWidth: radius, cornerHeight: radius,
                transform: nil)
            if !rounded.contains(point) { return nil }
        }
        return hit
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

final class EditorCanvasView: NSView, RedactionHost, RedactionSurfaceDelegate {
    private(set) var image: CapturedImage
    private var pixellatedCache: CGImage?

    var annotations: [Annotation] = []
    var currentTool: EditorTool = .select {
        didSet {
            if oldValue == .crop, currentTool != .crop {
                cancelCropSelection()
            }
            window?.invalidateCursorRects(for: self)
            if pointerInsideView, let vp = lastMouseView {
                applyCursor(canvasCursor(atView: vp))
            }
            needsDisplay = true
        }
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
    var onImageChange: (() -> Void)?
    var onCropSelectionChange: ((Bool) -> Void)?
    var enclosingScroll: (() -> NSScrollView?)?

    private var selected: Annotation?
    private var drafting: Annotation?
    private var dragStartPoint: CGPoint = .zero
    private var isMovingSelection = false
    private var cropRect: CGRect?
    private var lastMousePixel: CGPoint?
    /// True only after enter/move/down. Cleared on exit so Tab cannot reuse
    /// a pixel from a previous visit. Scroll clears the cached pixel but
    /// keeps this flag so the next pick recomputes under the live cursor.
    private var pointerInsideView = false
    private enum TransientOverlay {
        case ruler(EdgeRuler.Span)
        case guide(axis: MeasureAxis, position: CGFloat)
    }
    private var transient: TransientOverlay?
    var hasValidCropSelection: Bool {
        guard let cropRect else { return false }
        return cropRect.width >= 4 && cropRect.height >= 4
    }

    private func notifyCropSelectionChange() {
        onCropSelectionChange?(hasValidCropSelection)
    }
    private enum CropDrag {
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
    }
    private var cropDrag: CropDrag?
    /// Magnifier patches dropped during the current drag, rebuilt when it ends.
    private var magnifiersClearedDuringDrag: Set<ObjectIdentifier> = []
    private var textField: NSTextField?
    private var editingTextAnnotation: TextAnnotation?

    init(image: CapturedImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image.pointSize))
        wantsLayer = true
        redactionDelegate = self
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved, .mouseEnteredAndExited,
                .activeInKeyWindow, .inVisibleRect,
            ],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        PixelSamplerCache.release(image.cgImage)
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// Draw on the first click instead of spending it on focusing the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pxScale: CGFloat { image.scale }

    /// Remembered stroke width for the current tool (persisted across sessions).
    private var toolWidth: CGFloat { Settings.shared.toolWidth(for: currentTool.rawValue) }

    private func toPixel(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x * pxScale, y: viewPoint.y * pxScale)
    }

    /// Field bezel/inset -> pixel origin. Pure and shared by the prospective
    /// export and the real commit so the two cannot drift.
    static func textOrigin(
        forFieldFrame frame: CGRect, scale: CGFloat
    ) -> CGPoint {
        CGPoint(x: (frame.minX + 2) * scale, y: (frame.minY + 4) * scale)
    }

    /// Outer frame applied at EXPORT time. It is never baked into `image`, so
    /// crop, resize and the annotation coordinate space are untouched and the
    /// padding is recomputed from whatever the document is at the time.
    private(set) var backdropPreset: BackdropPreset = .none

    var backdropPresetForTesting: BackdropPreset { backdropPreset }

    /// The single geometry description for this document. Preview, fit, the
    /// size badge and the export all read it, so none of them can invent its
    /// own idea of where the image sits inside the frame.
    var backdropLayout: BackdropLayout {
        BackdropLayout(
            innerPixels: CGSize(
                width: CGFloat(image.cgImage.width),
                height: CGFloat(image.cgImage.height)),
            pixelScale: pxScale, preset: backdropPreset)
    }

    /// The layout an export would produce right now, which honours a pending
    /// crop. Distinct from `backdropLayout` on purpose: the wrapper and fit
    /// describe the LIVE document the user is still cropping, while anything
    /// reporting the resulting file has to describe what Save would write.
    var exportLayout: BackdropLayout {
        let inner = prospectiveInnerPixelSize()
        return BackdropLayout(
            innerPixels: CGSize(
                width: CGFloat(inner.width), height: CGFloat(inner.height)),
            pixelScale: pxScale, preset: backdropPreset)
    }

    /// The integral pixel rect a flatten would render right now, or nil when
    /// no valid crop is pending. `flattened()` derives its base from this, so
    /// anything REPORTING the prospective export size — the fingerprint — can
    /// never disagree with the export about what that size is. Acceptance is a
    /// different question and asks about the full image instead, because a
    /// pending crop can be taken away again.
    func prospectiveCropPixelRect() -> CGRect? {
        guard currentTool == .crop, let crop = cropRect, hasValidCropSelection
        else { return nil }
        let viewRect = crop.intersection(bounds)
        guard !viewRect.isNull, viewRect.width >= 4, viewRect.height >= 4
        else { return nil }
        let requested = EditableSelectionGeometry.pixelCropRect(
            for: viewRect, in: bounds, scale: pxScale)
        let imageBounds = CGRect(
            x: 0, y: 0, width: image.cgImage.width, height: image.cgImage.height)
        let px = requested.intersection(imageBounds)
        guard !px.isNull, px.width >= 1, px.height >= 1 else { return nil }
        return px
    }

    func prospectiveInnerPixelSize() -> (width: Int, height: Int) {
        guard let px = prospectiveCropPixelRect() else {
            return (image.cgImage.width, image.cgImage.height)
        }
        return (Int(px.width), Int(px.height))
    }

    /// Whether an image of this size can be exported with this preset — both
    /// buffers alive at once, which is what the peak actually is.
    ///
    /// Validity is judged against the FULL image, never a pending crop: a crop
    /// is cancelled by Esc, by switching tools and by undo, so a preset that was
    /// only affordable while that crop existed would silently become invalid
    /// under the user. Committing a smaller crop can only lower the peak, so
    /// full-image validity keeps holding afterwards.
    ///
    /// `.none` still has to fit: there is no frame, but the export buffer is
    /// real and its budget is smaller than the resizer's own dimension cap.
    func backdropPeakFits(
        _ preset: BackdropPreset, width: Int, height: Int
    ) -> Bool {
        let reserve = SliceBBackdrop.reservedBytes(
            forInnerWidth: width, height: height, preset: preset,
            pixelScale: pxScale)
        guard let innerBudget = SliceBExport.budget(
            SliceBExport.defaultBudgetBytes, minus: reserve),
            let innerBytes = SliceBExport.byteCount(width: width, height: height)
        else { return false }
        return innerBytes <= innerBudget
    }

    /// Applying the SAME preset is not an edit and must not touch history.
    @discardableResult
    func applyBackdrop(_ preset: BackdropPreset) -> Bool {
        guard preset != backdropPreset else { return false }
        // Validate the PEAK here, not at export: a preset the document cannot
        // afford must be refused while the user is choosing it, with a message
        // about the backdrop rather than a redaction error much later. The
        // peak is inner AND outer together, judged on the FULL image so a
        // pending crop cannot make a preset look affordable and then take that
        // affordability away when it is cancelled.
        //
        // Removing a frame is always allowed: it only lowers the peak, and a
        // document must never be stuck wearing one it cannot export.
        guard preset == .none || backdropPeakFits(
            preset, width: image.cgImage.width,
            height: image.cgImage.height) else {
            ToastHUD.show(
                "This image is too large for a backdrop",
                symbol: "exclamationmark.triangle.fill")
            return false
        }
        registerBackdropUndo(from: backdropPreset)
        backdropPreset = preset
        needsDisplay = true
        onStateChange?()
        return true
    }

    /// Text-redaction jobs owned by this canvas. GREEN2 wires the tool to it;
    /// the lifecycle gate asserts on it and stays red until then.
    let redactionRegistry = RedactionJobRegistry()

    /// Repaint target for a resolved redaction, weak by construction. The
    /// canvas is its own delegate in production; a gate can wrap it.
    weak var redactionDelegate: RedactionSurfaceDelegate?

    func redactionDidChange() {
        redactionDelegate?.surfaceNeedsRedactionRepaint()
    }

    func surfaceNeedsRedactionRepaint() {
        // FORCE, not needsRebuild: a resolution can also make a mask STOP
        // overlapping a magnifier's source (pending covered it, the resolved
        // word boxes do not). Testing only the new mask returns false there and
        // the callout would keep showing the old, fully-masked patch while the
        // document beneath it has narrowed.
        refreshMagnifierSnapshotsAfterDocumentChange()
        needsDisplay = true
    }

    /// Slice B seam: drives the SHARED regional-pixelation failure so the
    /// editor takes production's fail-closed path (no clean base on screen, no
    /// export, no close) rather than a canvas-only shortcut.
    static var forcePixellateFailureForTesting: Bool {
        AnnotationRenderer.forceRegionalPixelateFailureForTesting
    }

    private var pixellated: CGImage? {
        if Self.forcePixellateFailureForTesting { return nil }
        if pixellatedCache == nil {
            pixellatedCache = AnnotationRenderer.pixellate(image.cgImage, scale: pxScale)
        }
        return pixellatedCache
    }

    /// Fail-CLOSED export. Returns nil when any redaction could not be
    /// rendered: handing back a clean base would silently publish the very
    /// pixels the user asked to cover. Every terminal action checks this.
    /// Fail-CLOSED, transactional export.
    ///
    /// The flatten runs on a PROSPECTIVE document — clones of the annotations,
    /// plus the in-progress text and the pending crop materialized into those
    /// clones. The live document (annotations, image, undo stack, text field,
    /// crop chrome, tool, pointer cache) is only committed after the render has
    /// actually succeeded, so a failed export cannot leave the editor changed —
    /// and can never hand back a clean base with the redactions dropped.
    /// Which stage refused, so the caller can name it to the user.
    enum FlattenFailure { case render, backdrop }

    func flattened() -> CapturedImage? {
        var ignored = FlattenFailure.render
        return flattened(failure: &ignored)
    }

    func flattened(failure: inout FlattenFailure) -> CapturedImage? {
        failure = .render
        var marks = annotations.map { $0.copyAnnotation() }
        if let pending = editingTextAnnotation, let field = textField {
            let typed = field.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                let text = TextAnnotation(uiScale: pxScale)
                text.text = typed
                // Same pure conversion the commit uses, so the exported image
                // and the committed document cannot disagree by a few points.
                text.origin = Self.textOrigin(
                    forFieldFrame: field.frame, scale: pxScale)
                text.color = pending.color
                text.fontSizePt = pending.fontSizePt
                marks.append(text)
            }
        }

        var base = image.cgImage
        var croppedBase: CGImage?
        if currentTool == .crop, cropRect != nil, hasValidCropSelection {
            // FAIL CLOSED: if the crop cannot be materialized we must NOT fall
            // back to the full base — that would export the pixels the user
            // just cropped away.
            guard let px = prospectiveCropPixelRect(),
                  let cropped = base.cropping(to: px),
                  let owned = cropped.materialized()
            else { return nil }
            let offset = EditableSelectionGeometry.annotationOffset(
                forPixelCrop: px, imageHeight: CGFloat(base.height))
            for mark in marks {
                mark.translateForDocumentChange(
                    by: CGPoint(x: -offset.x, y: -offset.y))
            }
            base = owned
            // The clones' sanitized patches were built against the UNCROPPED
            // image; rebuild them against what is actually being rendered.
            let clonedRedactions = marks.compactMap { $0 as? BlurAnnotation }
            for mag in marks.compactMap({ $0 as? MagnifierAnnotation }) {
                mag.snapshot = SliceBCompositor.magnifierSnapshot(
                    base: owned, sourceRect: mag.sourceRect,
                    redactions: clonedRedactions)
            }
            croppedBase = owned
        }

        // Inner render first, then the outer frame, and only then is anything
        // committed. The budget the inner render may use is reduced by what the
        // outer frame will need, because both buffers exist at the same time.
        let outerReserve = SliceBBackdrop.reservedBytes(
            forInner: base, preset: backdropPreset, pixelScale: pxScale)
        guard let innerBudget = SliceBExport.budget(
            SliceBExport.defaultBudgetBytes, minus: outerReserve)
        else { return nil }
        guard let inner = SliceBExport.checkedRender(
            base: base, annotations: marks, pixellated: nil,
            budgetBytes: innerBudget, pixelScale: pxScale,
            // Framed output is composed in sRGB, so the inner render has to
            // blend there too — see checkedRender. `.none` keeps the
            // document's own space.
            destinationSpace: backdropPreset == .none
                ? nil : CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        guard let cg = SliceBBackdrop.compose(
            image: inner, preset: backdropPreset,
            budgetBytes: SliceBExport.defaultBudgetBytes,
            pixelScale: pxScale)
        else {
            failure = .backdrop
            return nil
        }

        // Render succeeded — now, and only now, make it real. Commit the very
        // base/marks that were rendered: cropping a second time could fail at
        // a higher peak and leave the export cropped while the document is not.
        commitTextEditing()
        if croppedBase != nil {
            registerUndoSnapshot()
            annotations = marks
            cropRect = nil
            notifyCropSelectionChange()
            setImage(CapturedImage(cgImage: base, scale: pxScale))
            (window?.windowController as? EditorWindowController)?
                .selectTool(.select)
        }
        return CapturedImage(cgImage: cg, scale: pxScale)
    }

    // MARK: drawing

    /// Corner radius the document is clipped to, in points. Non-zero only
    /// while a backdrop frames it, and applied here rather than on the layer so
    /// it survives every drawing path.
    var documentCornerRadius: CGFloat = 0 {
        didSet {
            guard documentCornerRadius != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if documentCornerRadius > 0 {
            ctx.saveGState()
            ctx.addPath(CGPath(
                roundedRect: bounds, cornerWidth: documentCornerRadius,
                cornerHeight: documentCornerRadius, transform: nil))
            ctx.clip()
        }
        defer { if documentCornerRadius > 0 { ctx.restoreGState() } }
        ctx.interpolationQuality = .high
        ctx.draw(image.cgImage, in: bounds)

        // annotations live in pixel space — scale the context down to points
        ctx.saveGState()
        ctx.scaleBy(x: 1 / pxScale, y: 1 / pxScale)
        let needsPixellated = annotations.contains(where: { $0 is BlurAnnotation })
            || drafting is BlurAnnotation
        if pixellatedCache != nil {
            pixellatedCache = nil // regional pixelation replaced the full copy
        }
        // Preview goes through the SAME compositor as export: phases, regional
        // pixelation, and an opaque cover when a redaction cannot render.
        var previewAnnotations = annotations
        if let drafting { previewAnnotations.append(drafting) }
        _ = needsPixellated
        SliceBCompositor.draw(
            previewAnnotations, in: ctx, base: image.cgImage,
            visiblePixels: CGRect(
                x: 0, y: 0,
                width: image.cgImage.width, height: image.cgImage.height),
            pixelScale: pxScale)
        ctx.restoreGState()

        // Straight after the document and its marks, and BEFORE any chrome:
        // the same position compose gives it. Selection handles, crop shading
        // and transients are editor furniture that the export never sees, so
        // the line has to go under them, not over them.
        if documentCornerRadius > 0 {
            SliceBBackdrop.drawPlateHairline(
                in: ctx, rect: bounds, pixelScale: 1)
        }

        ctx.saveGState()
        ctx.scaleBy(x: 1 / pxScale, y: 1 / pxScale)
        if let sel = selected {
            drawSelectionChrome(around: sel.bounds, in: ctx)
        }
        ctx.restoreGState()

        if let crop = cropRect { drawCropChrome(for: crop, in: ctx) }

        ctx.saveGState()
        ctx.scaleBy(x: 1 / pxScale, y: 1 / pxScale)
        switch transient {
        case .ruler(let span):
            drawRuler(span, in: ctx, uiScale: pxScale, color: .systemYellow, preview: true)
        case .guide(let axis, let position):
            let length = axis == .vertical
                ? CGFloat(image.cgImage.height) : CGFloat(image.cgImage.width)
            let guide = GuideAnnotation(
                axis: axis, position: position, length: length, uiScale: pxScale)
            guide.color = NSColor.systemTeal.withAlphaComponent(0.85)
            guide.draw(in: ctx, pixellated: nil)
        case .none:
            break
        }
        ctx.restoreGState()
    }

    private var cropChromeScale: CGFloat {
        let scroll = enclosingScroll?()
        return 1 / max(scroll?.minMagnification ?? 0.01, scroll?.magnification ?? 1)
    }

    private func drawCropChrome(for crop: CGRect, in ctx: CGContext) {
        let unit = cropChromeScale
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        ctx.beginPath()
        ctx.addRect(bounds)
        ctx.addRect(crop)
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(unit)
        ctx.stroke(crop)

        // Rule-of-thirds guides make precise post-capture composition easier.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.38).cgColor)
        ctx.setLineWidth(0.75 * unit)
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            let x = crop.minX + crop.width * fraction
            let y = crop.minY + crop.height * fraction
            ctx.move(to: CGPoint(x: x, y: crop.minY))
            ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
            ctx.move(to: CGPoint(x: crop.minX, y: y))
            ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(unit)
        for (_, handleRect) in EditableSelectionGeometry.handleRects(for: crop, size: 7 * unit) {
            ctx.fill(handleRect)
            ctx.stroke(handleRect)
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

    /// Backdrop is DOCUMENT state, so it travels with undo like the marks and
    /// the bitmap do.
    private struct DocumentSnapshot {
        let annotations: [Annotation]
        let image: CapturedImage
        let backdrop: BackdropPreset
    }

    private func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(
            annotations: annotations.map { $0.copyAnnotation() },
            image: image, backdrop: backdropPreset)
    }

    /// A preset change touches ONE field, so its undo restores one field.
    ///
    /// It must not cancel OCR jobs (that would widen pending masks to full as
    /// an invisible, un-undoable side effect of picking a colour) and it must
    /// not snapshot the document either: `snapshot()` clones every annotation,
    /// so undoing a preset would swap the live blur a job is resolving for a
    /// detached copy. A result landing after that undo mutates the orphan and
    /// the visible mask never narrows; a result landing before it is thrown
    /// away when the stale pending clone is restored. Keeping annotation
    /// identity untouched makes both delivery orders correct.
    func registerBackdropUndo(from previous: BackdropPreset) {
        historyMutationCountForTesting += 1
        undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.registerBackdropUndo(from: canvas.backdropPreset)
            canvas.backdropPreset = previous
            canvas.needsDisplay = true
            canvas.onStateChange?()
        }
    }

    func registerUndoSnapshot() {
        historyMutationCountForTesting += 1
        // Any structural edit (delete, crop, resize, undo, redo) supersedes
        // every OCR job in flight: a late result must not narrow a mask on an
        // annotation the user has already changed.
        // Per annotation FIRST: cancel(for:) is what turns a pending mask into
        // the full mask and bumps its generation. Bumping first would make the
        // cancel a no-op and lose the repaint. cancelAll only sweeps orphans.
        for blur in annotations.compactMap({ $0 as? BlurAnnotation }) {
            redactionRegistry.cancel(for: blur)
        }
        redactionRegistry.cancelAll()
        let snap = snapshot()
        undoManager?.registerUndo(withTarget: self) { canvas in
            // Symmetric: registrations made during undo land on the redo stack
            // and vice versa, so an edit stays undoable after redo. (The old
            // one-shot redo closure registered no inverse — redoing an edit
            // made it permanently un-undoable.)
            canvas.registerUndoSnapshot()
            canvas.restore(snap)
        }
    }

    private func restore(_ snap: DocumentSnapshot) {
        annotations = snap.annotations
        backdropPreset = snap.backdrop
        if snap.image.cgImage !== image.cgImage {
            setImage(snap.image)
        }
        refreshMagnifierSnapshotsAfterDocumentChange()
        selected = nil
        needsDisplay = true
        onStateChange?()
    }

    private func setImage(_ newImage: CapturedImage) {
        if image.cgImage !== newImage.cgImage {
            PixelSamplerCache.release(image.cgImage)
        }
        image = newImage
        pixellatedCache = nil
        // Crop / resize / undo-redo all change geometry. A cached pixel from
        // the previous bitmap is stale; the next pick recomputes from the
        // live pointer (or a later mouse event) in the new space.
        lastMousePixel = nil
        setFrameSize(newImage.pointSize)
        needsDisplay = true
        onStateChange?()
        onImageChange?()
    }

    // MARK: mouse

    private func updatePointer(from event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        lastMouseView = vp
        lastMousePixel = toPixel(vp)
        pointerInsideView = true
    }

    /// Kept alongside `lastMousePixel` so a tool switch can re-derive the
    /// pointer where it already is, instead of leaving the previous tool's
    /// cursor up until the mouse next moves.
    private var lastMouseView: CGPoint?

    func invalidatePointerAfterScroll() {
        lastMousePixel = nil
        if pointerInsideView {
            refreshTransient()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        lastMousePixel = nil
        pointerInsideView = false
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        updatePointer(from: event)
        let vp = convert(event.locationInWindow, from: nil)
        let pp = toPixel(vp)
        if imprintTransient(at: pp) { return }
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
        case .pixelateText:
            // Text mode starts as a FULL mask and only narrows once a live OCR
            // result lands, so the drag never shows unmasked pixels.
            let blur = BlurAnnotation(uiScale: pxScale)
            blur.rect = CGRect(origin: pp, size: .zero)
            blur.redactionState = .pendingFull
            drafting = blur
        case .spotlight:
            let spot = SpotlightAnnotation(uiScale: pxScale)
            spot.rect = CGRect(origin: pp, size: .zero)
            spot.baseBounds = CGRect(
                x: 0, y: 0,
                width: image.cgImage.width, height: image.cgImage.height)
            drafting = spot
        case .magnifier:
            let mag = MagnifierAnnotation(uiScale: pxScale)
            mag.sourceRect = CGRect(origin: pp, size: .zero)
            mag.calloutRect = CGRect(origin: pp, size: .zero)
            mag.isDrafting = true
            drafting = mag
        case .backdrop:
            // A canvas-level style, not a drag, and CHOOSING the tool changes
            // nothing: the preset popover is what applies one.
            selected = nil
        case .crop:
            selected = nil
            if event.clickCount >= 2, let crop = cropRect, crop.contains(vp) {
                applyCropSelection()
            } else if let crop = cropRect,
                      let handle = EditableSelectionGeometry.handle(
                        at: vp, in: crop, tolerance: 9 * cropChromeScale
                      ) {
                cropDrag = .resizing(handle: handle, original: crop)
                applyCursor(.resize(handle))
            } else if let crop = cropRect, crop.contains(vp) {
                cropDrag = .moving(start: vp, original: crop)
                applyCursor(.closedHand)
            } else {
                let anchor = EditableSelectionGeometry.clampedPoint(vp, to: bounds)
                cropRect = CGRect(origin: anchor, size: .zero)
                cropDrag = .creating(anchor: anchor)
            }
            notifyCropSelectionChange()
            needsDisplay = true
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

    /// Repaint only the region an interactive change touched. Invalidating the
    /// whole view per mouse event forced a full multi-megapixel redraw and
    /// dropped pen/shape dragging to ~25-40 fps on retina fullscreen shots.
    /// Padding covers stroke width, selection handles and arrowheads.
    private func invalidate(pixelRect: CGRect) {
        let pad: CGFloat = 60
        let view = CGRect(
            x: pixelRect.minX / pxScale, y: pixelRect.minY / pxScale,
            width: pixelRect.width / pxScale, height: pixelRect.height / pxScale
        ).insetBy(dx: -pad, dy: -pad)
        setNeedsDisplay(view)
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(from: event)
        applyCursor(canvasCursor(atView: convert(event.locationInWindow, from: nil)))
        refreshTransient()
    }

    override func mouseDragged(with event: NSEvent) {
        updatePointer(from: event)
        let vp = convert(event.locationInWindow, from: nil)
        let pp = toPixel(vp)

        switch currentTool {
        case .select:
            if isMovingSelection, let sel = selected {
                let before = sel.bounds
                sel.move(by: CGPoint(x: pp.x - dragStartPoint.x, y: pp.y - dragStartPoint.y))
                dragStartPoint = pp
                if sel is BlurAnnotation {
                    clearMagnifierSnapshotsOverlapping(before.union(sel.bounds))
                }
                invalidate(pixelRect: before.union(sel.bounds))
            }
        case .arrow, .line, .rect, .oval, .highlight:
            if let shape = drafting as? ShapeAnnotation {
                let before = shape.bounds
                shape.end = pp
                invalidate(pixelRect: before.union(shape.bounds))
            }
        case .pen:
            if let pen = drafting as? PenAnnotation {
                pen.points.append(pp)
                // the quad-curve smoothing reshapes the PREVIOUS segment when a
                // point lands, so the dirty area must span the last few points
                var rect = CGRect(origin: pp, size: .zero)
                for p in pen.points.suffix(4) {
                    rect = rect.union(CGRect(origin: p, size: .zero))
                }
                invalidate(pixelRect: rect)
            }
        case .blur, .pixelateText:
            if let blur = drafting as? BlurAnnotation {
                let before = blur.rect
                blur.rect = CGRect(
                    x: min(dragStartPoint.x, pp.x), y: min(dragStartPoint.y, pp.y),
                    width: abs(pp.x - dragStartPoint.x), height: abs(pp.y - dragStartPoint.y)
                )
                clearMagnifierSnapshotsOverlapping(before.union(blur.rect))
                invalidate(pixelRect: before.union(blur.rect))
            }
        case .spotlight:
            if let spot = drafting as? SpotlightAnnotation {
                let before = spot.rect
                spot.rect = CGRect(
                    x: min(dragStartPoint.x, pp.x), y: min(dragStartPoint.y, pp.y),
                    width: abs(pp.x - dragStartPoint.x),
                    height: abs(pp.y - dragStartPoint.y))
                invalidate(pixelRect: spot.baseBounds.union(before))
            }
        case .magnifier:
            if let mag = drafting as? MagnifierAnnotation {
                let before = mag.calloutRect
                let source = CGRect(
                    x: min(dragStartPoint.x, pp.x), y: min(dragStartPoint.y, pp.y),
                    width: abs(pp.x - dragStartPoint.x),
                    height: abs(pp.y - dragStartPoint.y))
                let sourceBefore = mag.sourceRect
                mag.sourceRect = source
                // Callout sits beside the source at 2x while dragging, kept
                // inside the image so it cannot end up off the document.
                mag.calloutRect = MagnifierAnnotation.calloutRect(
                    for: source, gap: 8 * pxScale,
                    within: CGRect(
                        x: 0, y: 0,
                        width: image.cgImage.width, height: image.cgImage.height))
                invalidate(pixelRect: before.union(mag.calloutRect)
                    .union(source).union(sourceBefore)
                    .insetBy(dx: -2 * pxScale, dy: -2 * pxScale))
            }
        case .backdrop:
            break
        case .crop:
            switch cropDrag {
            case .creating(let anchor):
                cropRect = EditableSelectionGeometry.rect(from: anchor, to: vp, within: bounds)
            case .moving(let start, let original):
                cropRect = EditableSelectionGeometry.moved(
                    original,
                    by: CGPoint(x: vp.x - start.x, y: vp.y - start.y),
                    within: bounds
                )
            case .resizing(let handle, let original):
                cropRect = EditableSelectionGeometry.resized(
                    original, using: handle, to: vp, within: bounds
                )
            case .none:
                break
            }
            notifyCropSelectionChange()
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        updatePointer(from: event)
        if let draft = drafting {
            let big = draft.bounds.width > 2 || draft.bounds.height > 2 || draft is PenAnnotation
            if big {
                registerUndoSnapshot()
                if let spot = draft as? SpotlightAnnotation {
                    // v1 is a singleton: darkness never stacks. Select the new
                    // one, or the digit keys would target a detached object.
                    annotations = SliceBCompositor.applySpotlight(
                        existing: annotations, new: spot)
                    selected = spot
                } else {
                    annotations.append(draft)
                }
                if let mag = draft as? MagnifierAnnotation {
                    mag.isDrafting = false
                    // Sample the SANITIZED layer so the callout can never
                    // resurrect pixels a redaction covers.
                    mag.snapshot = SliceBCompositor.magnifierSnapshot(
                        base: image.cgImage, sourceRect: mag.sourceRect,
                        redactions: annotations.compactMap {
                            $0 as? BlurAnnotation
                        })
                }
                if let blur = draft as? BlurAnnotation {
                    // A new redaction can cover a magnifier's source, so every
                    // patch that overlaps it must be rebuilt.
                    refreshMagnifierSnapshotsAfterDocumentChange(force: false)
                    if blur.redactionState == .pendingFull {
                        startTextRedaction(for: blur)
                    }
                }
            }
            drafting = nil
            needsDisplay = true
        }
        if currentTool == .crop {
            cropDrag = nil
            if let crop = cropRect, crop.width < 4 || crop.height < 4 { cropRect = nil }
            notifyCropSelectionChange()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        if isMovingSelection {
            // One rebuild at the end of the interaction, once the geometry has
            // settled.
            refreshMagnifierSnapshotsAfterDocumentChange()
        }
        // Unconditional: a discarded draft, or one that ended away from the
        // source, must still get its patch back.
        rebuildMagnifierSnapshotsClearedDuringDrag()
        isMovingSelection = false
    }

    /// A magnifier holds a SANITIZED patch. Anything that changes the document
    /// or the redactions can make that patch stale, and a stale patch shows
    /// pixels a redaction now covers — so every such change funnels through
    /// here. A failed rebuild clears the patch rather than keeping old pixels.
    /// Mid-drag fail-closed: the moment a redaction being moved or drawn
    /// touches a magnifier's source, drop that patch. Rebuilding on every
    /// mouse-moved event would be far too expensive, and showing the old
    /// sanitized pixels while the user is covering something is exactly the
    /// leak this feature exists to prevent.
    func clearMagnifierSnapshotsOverlapping(_ rect: CGRect) {
        var cleared = false
        for mag in annotations.compactMap({ $0 as? MagnifierAnnotation })
        where mag.snapshot != nil && mag.sourceRect.intersects(rect) {
            mag.snapshot = nil
            // Remember exactly which patches were dropped, so recovery does
            // not depend on where the drag happened to end.
            magnifiersClearedDuringDrag.insert(ObjectIdentifier(mag))
            cleared = true
        }
        if cleared { needsDisplay = true }
    }

    /// Recovery for the patches cleared mid-drag. Runs after EVERY drag,
    /// committed or discarded: gating it on the final rect (or on the draft
    /// being large enough) left the callout permanently blank when the drag
    /// merely passed over the source or ended as a click.
    func rebuildMagnifierSnapshotsClearedDuringDrag() {
        guard !magnifiersClearedDuringDrag.isEmpty else { return }
        let ids = magnifiersClearedDuringDrag
        magnifiersClearedDuringDrag.removeAll()
        let redactions = liveRedactions
        for mag in annotations.compactMap({ $0 as? MagnifierAnnotation })
        where ids.contains(ObjectIdentifier(mag)) {
            mag.snapshot = SliceBCompositor.magnifierSnapshot(
                base: image.cgImage, sourceRect: mag.sourceRect,
                redactions: redactions)
        }
        needsDisplay = true
    }

    /// Every redaction that is currently covering pixels — including the one
    /// being drawn right now. A rebuild that saw only committed annotations
    /// would restore raw pixels underneath an active draft.
    private var liveRedactions: [BlurAnnotation] {
        var result = annotations.compactMap { $0 as? BlurAnnotation }
        if let draft = drafting as? BlurAnnotation,
           !result.contains(where: { $0 === draft }) {
            result.append(draft)
        }
        return result
    }

    func refreshMagnifierSnapshotsAfterDocumentChange(force: Bool = true) {
        let redactions = liveRedactions
        let magnifiers = annotations.compactMap { $0 as? MagnifierAnnotation }
        guard !magnifiers.isEmpty else { return }
        for mag in magnifiers {
            guard force || SliceBCompositor.needsRebuild(
                source: mag.sourceRect, redactions: redactions) else { continue }
            mag.snapshot = SliceBCompositor.magnifierSnapshot(
                base: image.cgImage, sourceRect: mag.sourceRect,
                redactions: redactions)
        }
        needsDisplay = true
    }

    /// Save-lock: freeze the document by cancelling work in flight. Called
    /// only after a successful flatten.
    func cancelRedactionJobsForSaveLock() {
        for blur in annotations.compactMap({ $0 as? BlurAnnotation }) {
            redactionRegistry.cancel(for: blur)
        }
        redactionRegistry.cancelAll()
    }

    /// Bounded OCR for one text redaction: the mask is already FULL, the job
    /// is registered with this canvas, and the repaint goes through the weak
    /// host protocol.
    private func startTextRedaction(for blur: BlurAnnotation) {
        guard let job = SliceBRedactionJob.start(
            blur: blur, base: image.cgImage, host: self)
        else {
            needsDisplay = true
            return
        }
        redactionRegistry.register(job, for: blur)
    }

    func applyCropSelection() {
        guard let crop = cropRect, crop.width >= 4, crop.height >= 4 else { return }
        cropRect = nil
        cropDrag = nil
        notifyCropSelectionChange()
        performCrop(viewRect: crop)
        (window?.windowController as? EditorWindowController)?.selectTool(.select)
    }

    func cancelCropSelection() {
        guard cropRect != nil || cropDrag != nil else { return }
        cropRect = nil
        cropDrag = nil
        notifyCropSelectionChange()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func performCrop(viewRect: CGRect) {
        let viewRect = viewRect.intersection(bounds)
        guard !viewRect.isNull, viewRect.width >= 4, viewRect.height >= 4 else { return }
        let requestedPixels = EditableSelectionGeometry.pixelCropRect(
            for: viewRect, in: bounds, scale: pxScale
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.cgImage.width, height: image.cgImage.height)
        let px = requestedPixels.intersection(imageBounds)
        guard !px.isNull, px.width >= 1, px.height >= 1,
              let cropped = image.cgImage.cropping(to: px),
              let owned = cropped.materialized() else { return }
        registerUndoSnapshot()
        // Shift annotations by the exact integral bitmap crop, not the
        // fractional view rectangle. This keeps them pixel-aligned across
        // repeated crops and converts CG's top-left Y to AppKit bottom-left Y.
        let offset = EditableSelectionGeometry.annotationOffset(
            forPixelCrop: px, imageHeight: CGFloat(image.cgImage.height)
        )
        for a in annotations {
            a.translateForDocumentChange(by: CGPoint(x: -offset.x, y: -offset.y))
        }
        // AFTER the new bitmap is installed: rebuilding first would sample the
        // old image with the new geometry.
        setImage(CapturedImage(cgImage: owned, scale: pxScale))
        refreshMagnifierSnapshotsAfterDocumentChange()
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
        updateTextEntryClip()

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
            // Align the committed annotation with the text the user just saw
            // in the field (bezel + inset offsets) — using the raw click point
            // made the text visibly jump ~10 pt up-left on every commit.
            ann.origin = Self.textOrigin(
                forFieldFrame: field.frame, scale: pxScale)
            annotations.append(ann)
        }
        needsDisplay = true
    }

    private lazy var textDelegate = TextFieldDelegate(onEnd: { [weak self] in
        self?.commitTextEditing()
    })

    // MARK: keyboard & zoom

    /// True while the text-annotation field owns the keyboard — editing
    /// keystrokes (⌘C to copy typed text, ⌘Z to undo typing, tool letters)
    /// must stay in the field instead of triggering canvas shortcuts.
    private var isEditingText: Bool {
        textField != nil && window?.firstResponder is NSTextView
    }

    // MARK: slice A — picker / ruler / guides / resize

    @discardableResult
    private func handleSliceAKey(
        _ event: NSEvent, flags: NSEvent.ModifierFlags, chars: String
    ) -> Bool {
        if handleColorPickKey(event, flags: flags) { return true }
        if flags.isEmpty {
            switch event.keyCode {
            case 123, 124: // left / right
                beginRuler(.horizontal)
                return true
            case 125, 126: // down / up
                beginRuler(.vertical)
                return true
            default: break
            }
        }
        if flags == .option {
            // ⌥S = vertical guide, ⌥D = horizontal. Bare S/D stay free for slice B.
            switch event.keyCode {
            case 1: // kVK_ANSI_S
                beginGuide(.vertical)
                return true
            case 2: // kVK_ANSI_D
                beginGuide(.horizontal)
                return true
            default: break
            }
        }
        _ = chars
        return false
    }

    @discardableResult
    private func handleColorPickKey(
        _ event: NSEvent, flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard event.keyCode == 48 else { return false } // Tab
        let onlyShift = flags == .shift
        let plain = flags.isEmpty
        guard onlyShift || plain else { return false }
        pickColor(darkest: onlyShift)
        return true
    }

    private func pixelIfInImage(_ pixel: CGPoint) -> CGPoint? {
        let x = pixel.x.rounded()
        let y = pixel.y.rounded()
        guard x >= 0, y >= 0,
              x < CGFloat(image.cgImage.width),
              y < CGFloat(image.cgImage.height)
        else { return nil }
        return pixel
    }

    private func livePointerPixel() -> CGPoint? {
        guard let window else { return nil }
        let screenPt = NSEvent.mouseLocation
        let winPt = window.convertPoint(fromScreen: screenPt)
        return toPixel(convert(winPt, from: nil))
    }

    private func pixelUnderMouse() -> CGPoint? {
        // Exit must not fall back to the live cursor: tests synthesize
        // mouseExited without moving the real pointer.
        guard pointerInsideView else { return nil }
        if let last = lastMousePixel {
            return pixelIfInImage(last)
        }
        // Scroll cleared the cache while the pointer is still inside —
        // recompute from the live cursor so picker/ruler/guide follow.
        if let live = livePointerPixel(), let ok = pixelIfInImage(live) {
            lastMousePixel = live
            return ok
        }
        return nil
    }

    func pickColor(darkest: Bool) {
        guard let pixel = pixelUnderMouse() else { return }
        let color = darkest
            ? PixelColorSampler.darkest(image: image.cgImage, around: pixel)
            : PixelColorSampler.sample(image: image.cgImage, at: pixel)
        guard let color else {
            ToastHUD.show("No pixel", symbol: "eyedropper")
            return
        }
        let hex = PixelColorSampler.hexString(from: color)
        SaveService.copyText(hex)
        ToastHUD.show(hex, symbol: "eyedropper")
    }

    func beginRuler(_ axis: MeasureAxis) {
        guard let pixel = pixelUnderMouse(),
              let span = EdgeRuler.measure(image: image.cgImage, from: pixel, axis: axis)
        else { return }
        transient = .ruler(span)
        needsDisplay = true
    }

    func beginGuide(_ axis: MeasureAxis) {
        guard let pixel = pixelUnderMouse() else { return }
        let position = axis == .vertical ? pixel.x : pixel.y
        transient = .guide(axis: axis, position: position)
        needsDisplay = true
    }

    private func refreshTransient() {
        guard transient != nil, let pixel = pixelUnderMouse() else { return }
        switch transient {
        case .ruler(let span):
            if let next = EdgeRuler.measure(
                image: image.cgImage, from: pixel, axis: span.axis)
            {
                transient = .ruler(next)
                needsDisplay = true
            }
        case .guide(let axis, _):
            transient = .guide(
                axis: axis, position: axis == .vertical ? pixel.x : pixel.y)
            needsDisplay = true
        case .none:
            break
        }
    }

    @discardableResult
    private func imprintTransient(at pixel: CGPoint) -> Bool {
        switch transient {
        case .ruler(let span):
            registerUndoSnapshot()
            annotations.append(RulerAnnotation(span: span, uiScale: pxScale))
            transient = nil
            selected = annotations.last
            needsDisplay = true
            onStateChange?()
            return true
        case .guide(let axis, _):
            registerUndoSnapshot()
            let position = axis == .vertical ? pixel.x : pixel.y
            let length = axis == .vertical
                ? CGFloat(image.cgImage.height) : CGFloat(image.cgImage.width)
            annotations.append(
                GuideAnnotation(
                    axis: axis, position: position, length: length,
                    uiScale: pxScale))
            transient = nil
            selected = annotations.last
            needsDisplay = true
            onStateChange?()
            return true
        case .none:
            return false
        }
    }

    func applyPixelScale(_ factor: CGFloat) {
        guard abs(factor - 1) >= 0.0001 else { return }
        // Ask about the target size BEFORE it is allocated: materializing a
        // bitmap only to reject it spends the very memory the check exists to
        // protect. ImageResizer's own cap is larger than the export budget, so
        // this refusal is also what stops a document from growing past the
        // point it can be exported at all — with or without a frame.
        guard let target = ImageResizer.targetDimensions(for: image, by: factor)
        else { return }
        guard backdropPeakFits(
            backdropPreset, width: target.width, height: target.height) else {
            ToastHUD.show(
                backdropPreset == .none
                    ? "This size is too large to export"
                    : "This size is too large for the backdrop",
                symbol: "exclamationmark.triangle.fill")
            return
        }
        guard let scaled = ImageResizer.scale(image, by: factor) else { return }
        cancelCropSelection()
        registerUndoSnapshot()
        for annotation in annotations {
            annotation.scaleCoordinates(by: factor)
        }
        if case .ruler(let span) = transient {
            var next = span
            next.start *= factor
            next.end *= factor
            next.cross *= factor
            transient = .ruler(next)
        } else if case .guide(let axis, let position) = transient {
            transient = .guide(axis: axis, position: position * factor)
        }
        setImage(scaled)
        // Geometry moved and the bitmap changed, so every sanitized patch is
        // stale until it is rebuilt against the new image.
        refreshMagnifierSnapshotsAfterDocumentChange()
    }

    /// Slice B seams: a gate needs to put the canvas into a realistic state
    /// (live crop selection, live text edit, a selected mark) and then prove a
    /// failed export changed NOTHING.
    func selectForTesting(_ annotation: Annotation?) {
        selected = annotation
        needsDisplay = true
    }

    /// Seeds a transient overlay without a pointer, the way
    /// `setCropSelectionForTesting` seeds a crop. State only — `beginGuide`
    /// remains the production entry point.
    func setTransientGuideForTesting(axis: MeasureAxis, position: CGFloat) {
        transient = .guide(axis: axis, position: position)
        needsDisplay = true
    }

    func setCropSelectionForTesting(_ rect: CGRect) {
        cropRect = rect
        notifyCropSelectionChange()
        needsDisplay = true
    }

    /// Puts a real, NON-DEFAULT pending edit in place: value, font and colour
    /// on both the live field and its backing annotation. Setting only the
    /// string left the style at production defaults, so a reset to defaults
    /// would have been invisible to the fingerprint.
    func setPendingTextForTesting(
        _ value: String, font: NSFont, color: NSColor
    ) {
        textField?.stringValue = value
        textField?.font = font
        textField?.textColor = color
        editingTextAnnotation?.fontSizePt = font.pointSize
        editingTextAnnotation?.color = color
        needsDisplay = true
    }

    func beginTextEditingForTesting(at pixel: CGPoint) {
        beginTextEditing(
            atViewPoint: CGPoint(x: pixel.x / pxScale, y: pixel.y / pxScale),
            pixelPoint: pixel)
    }

    func cropForTesting(pixels: CGRect) {
        performCrop(viewRect: CGRect(
            x: pixels.minX / pxScale, y: pixels.minY / pxScale,
            width: pixels.width / pxScale, height: pixels.height / pxScale))
    }

    /// Strong references, compared with `===`. Neither a hash nor an
    /// ObjectIdentifier is safe on its own: once an object is freed its address
    /// can be reused by the next allocation, and the comparison would lie.
    var annotationRefsForTesting: [Annotation] { annotations }
    var selectedRefForTesting: Annotation? { selected }
    var editingTextRefForTesting: TextAnnotation? { editingTextAnnotation }

    /// The live field, so a gate can ask where a caption being typed actually
    /// sits — it is a SUBVIEW, and subviews are clipped by a different
    /// mechanism than the canvas's own drawing.
    var textFieldForTesting: NSTextField? { textField }

    /// Drives a real drag through the production mouse handlers, in image
    /// pixels, so a gate can create an annotation the way a user does.
    func dragForTesting(from start: CGPoint, to end: CGPoint) {
        let scale = pxScale
        let a = CGPoint(x: start.x / scale, y: start.y / scale)
        let b = CGPoint(x: end.x / scale, y: end.y / scale)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: convert(point, to: nil),
                modifierFlags: [], timestamp: 0,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, a) { mouseDown(with: down) }
        if let drag = event(.leftMouseDragged, b) { mouseDragged(with: drag) }
        if let up = event(.leftMouseUp, b) { mouseUp(with: up) }
    }

    /// The exact predicate `keyDown` routes on, so a preflight cannot assert a
    /// near-miss (a backing annotation without first responder, say).
    var isEditingTextForTesting: Bool { isEditingText }

    /// Style actually installed on the live field. A value, not a string:
    /// matching on a font NAME is meaningless (the production default is a
    /// system font too), so the gate compares size, weight traits and colour.
    struct PendingTextStyle: Equatable {
        var pointSize: CGFloat = -1
        var isBold = false
        var red: CGFloat = -1
        var green: CGFloat = -1
        var blue: CGFloat = -1
        var alpha: CGFloat = -1
    }

    var pendingTextStyleForTesting: PendingTextStyle? {
        guard let field = textField else { return nil }
        var style = PendingTextStyle()
        if let font = field.font {
            style.pointSize = font.pointSize
            style.isBold = NSFontManager.shared.traits(of: font)
                .contains(.boldFontMask)
        }
        if let color = field.textColor?.usingColorSpace(.sRGB) {
            style.red = color.redComponent
            style.green = color.greenComponent
            style.blue = color.blueComponent
            style.alpha = color.alphaComponent
        }
        return style
    }

    /// Live pointer state — part of what a ruler transient depends on.
    var pointerStateForTesting: String {
        "inside=\(pointerInsideView) px=\(lastMousePixel.map { "\($0)" } ?? "nil")"
    }

    /// Everything a terminal action must leave untouched when export fails.
    /// Deliberately deep: payload and ORDER of every mark, the identity of the
    /// selected one, the exact crop, the pending text's value/frame/style, the
    /// image's pixel hash and scale, and the full history/transient state.
    var documentFingerprintForTesting: String {
        func describe(_ a: Annotation) -> String {
            let rgba = a.color.usingColorSpace(.sRGB).map {
                "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)"
            } ?? "?"
            var parts = [
                "\(type(of: a))",
                "b=\(a.bounds)",
                "rgba=\(rgba)",
                "w=\(a.strokeWidthPt)",
            ]
            switch a {
            case let shape as ShapeAnnotation:
                parts.append("kind=\(shape.kind) s=\(shape.start) e=\(shape.end)")
            case let text as TextAnnotation:
                parts.append("t=\(text.text) o=\(text.origin) f=\(text.fontSizePt)")
            case let counter as CounterAnnotation:
                parts.append("n=\(counter.number) c=\(counter.center) r=\(counter.radiusPt)")
            case let pen as PenAnnotation:
                parts.append("pts=\(pen.points.map { "\($0.x),\($0.y)" }.joined(separator: ";"))")
            case let blur as BlurAnnotation:
                parts.append("r=\(blur.rect) st=\(blur.redactionState) g=\(blur.redactionGeneration)")
            case let spot as SpotlightAnnotation:
                parts.append("r=\(spot.rect) d=\(spot.dimFraction) bb=\(spot.baseBounds)")
            case let mag as MagnifierAnnotation:
                let snap = mag.snapshot.map {
                    "\($0.width)x\($0.height)#\(SelfTest.imageHashForTesting($0))"
                } ?? "nil"
                parts.append("src=\(mag.sourceRect) out=\(mag.calloutRect) snap=\(snap)")
            case let guide as GuideAnnotation:
                parts.append("axis=\(guide.axis) pos=\(guide.position) len=\(guide.length)")
            case let ruler as RulerAnnotation:
                parts.append(
                    "axis=\(ruler.span.axis) cross=\(ruler.span.cross) span=\(ruler.span.start)->\(ruler.span.end) len=\(ruler.span.length)")
            default:
                break
            }
            return parts.joined(separator: " ")
        }
        let marks = annotations.map(describe).joined(separator: " || ")
        let selectedIndex = selected.flatMap { sel in
            annotations.firstIndex { $0 === sel }
        }
        // Identity is compared as references elsewhere; the string only needs
        // to say WHICH mark, so a positional index is enough here and cannot
        // collide the way a hash can.
        func rgbaString(_ color: NSColor?) -> String {
            guard let c = color?.usingColorSpace(.sRGB) else { return "-" }
            return "\(c.redComponent),\(c.greenComponent),\(c.blueComponent),\(c.alphaComponent)"
        }
        let pendingText = textField.map { field -> String in
            let backing = editingTextAnnotation.map {
                "text=\($0.text) o=\($0.origin) f=\($0.fontSizePt) rgba=\(rgbaString($0.color))"
            } ?? "nil"
            return [
                "value=\(field.stringValue)",
                "frame=\(field.frame)",
                "style=\(String(describing: pendingTextStyleForTesting))",
                "textColor=\(rgbaString(field.textColor))",
                "backing=[\(backing)]",
            ].joined(separator: " ")
        } ?? "none"
        // The size a flatten right now would produce, which is the cropped
        // size when a crop is pending — reporting the full image there would
        // make the fingerprint disagree with the export it is meant to police.
        let outerSize: String = {
            guard backdropPreset != .none else { return "none" }
            let inner = prospectiveInnerPixelSize()
            guard let outer = SliceBBackdrop.outerDimensions(
                innerWidth: inner.width, innerHeight: inner.height,
                preset: backdropPreset, pixelScale: pxScale)
            else { return "invalid" }
            return "\(outer.width)x\(outer.height)"
        }()
        return [
            "px=\(SelfTest.imageHashForTesting(image.cgImage))",
            "backdrop=\(backdropPreset.rawValue)",
            "outer=\(outerSize)",
            "size=\(image.cgImage.width)x\(image.cgImage.height)@\(image.scale)",
            "tool=\(currentTool.rawValue)",
            "crop=\(cropRect.map { "\($0)" } ?? "nil")",
            "cropValid=\(hasValidCropSelection)",
            "text=[\(pendingText)]",
            "selIdx=\(selectedIndex.map(String.init) ?? "nil")",
            "undo=\(undoManager?.canUndo == true)",
            "redo=\(undoManager?.canRedo == true)",
            "history=\(historyMutationCountForTesting)",
            "transient=\(transientDescriptionForTesting)",
            "pointer=\(pointerStateForTesting)",
            "marks=[\(marks)]",
        ].joined(separator: " ")
    }

    func pickColorHexForTesting(at pixel: CGPoint, darkest: Bool) -> String? {
        lastMousePixel = pixel
        pointerInsideView = true
        let color = darkest
            ? PixelColorSampler.darkest(image: image.cgImage, around: pixel)
            : PixelColorSampler.sample(image: image.cgImage, at: pixel)
        return color.map(PixelColorSampler.hexString(from:))
    }

    var pointerPixelForTesting: CGPoint? { lastMousePixel }
    var pointerInsideForTesting: Bool { pointerInsideView }
    func pixelUnderMouseForTesting() -> CGPoint? { pixelUnderMouse() }

    func invalidatePointerAfterScrollForTesting() {
        invalidatePointerAfterScroll()
    }

    func mouseExitedForTesting() {
        lastMousePixel = nil
        pointerInsideView = false
    }

    func notePointerForTesting(_ pixel: CGPoint) {
        lastMousePixel = pixel
        pointerInsideView = true
    }

    var transientKindForTesting: String? {
        switch transient {
        case .ruler: return "ruler"
        case .guide: return "guide"
        case .none: return nil
        }
    }

    /// Full transient payload, not just its kind: a gate must see the measured
    /// span or the guide position, not only that "something" is there.
    var transientDescriptionForTesting: String {
        switch transient {
        case let .ruler(span):
            return "ruler(axis=\(span.axis) cross=\(span.cross) \(span.start)->\(span.end) len=\(span.length))"
        case let .guide(axis, position):
            return "guide(\(axis) @\(position))"
        case .none:
            return "none"
        }
    }

    /// Monotonic count of real history mutations. NSUndoManager will not report
    /// its depth, and `canUndo` alone cannot tell "one edit" from "five edits
    /// and four undos".
    private(set) var historyMutationCountForTesting = 0

    override func keyDown(with event: NSEvent) {
        if isEditingText {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // Esc
            if transient != nil {
                transient = nil
                needsDisplay = true
                return
            }
            if currentTool == .crop {
                cancelCropSelection()
                (window?.windowController as? EditorWindowController)?.selectTool(.select)
                return
            }
            (window?.windowController as? EditorWindowController)?.escPressed()
            return
        }
        if currentTool == .crop, (event.keyCode == 36 || event.keyCode == 76) { // Return / keypad Enter
            applyCropSelection()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // delete
            if let sel = selected {
                registerUndoSnapshot()
                annotations.removeAll { $0 === sel }
                selected = nil
                refreshMagnifierSnapshotsAfterDocumentChange()
                needsDisplay = true
            }
            return
        }
        if handleSliceAKey(event, flags: flags, chars: chars) { return }
        // Shift-only B selects text redaction, checked BEFORE the plain-key
        // map so B on its own still means Pixelate.
        if flags == .shift, chars == "b" {
            (window?.windowController as? EditorWindowController)?
                .selectTool(.pixelateText)
            return
        }
        // 1-9 set the selected spotlight's darkness, through undo.
        if flags.isEmpty, let digit = Int(chars), (1...9).contains(digit),
           let selectedSpot = selected as? SpotlightAnnotation,
           // Only a spotlight still in the document may be adjusted; a
           // replaced one is detached and mutating it would do nothing visible.
           let spot = annotations.compactMap({ $0 as? SpotlightAnnotation })
               .first(where: { $0 === selectedSpot }) {
            registerUndoSnapshot()
            spot.dimFraction = CGFloat(digit) / 10
            needsDisplay = true
            return
        }
        if flags.isEmpty, let tool = SliceAHotkeys.editorToolKeys[chars] {
            let controller = window?.windowController as? EditorWindowController
            if tool == .backdrop {
                // Same non-destructive path as the button: opening the chooser
                // must not change the active tool, because leaving .crop would
                // cancel a live crop selection and leave the canvas in an inert
                // Backdrop mode even if the menu is dismissed.
                controller?.openBackdropChooser()
                return
            }
            controller?.selectTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // typing in the text-annotation field: ⌘C/⌘Z/etc. belong to the field
        // editor — hijacking them here used to close the editor mid-typing
        if isEditingText {
            return super.performKeyEquivalent(with: event)
        }
        let pickFlags = event.modifierFlags.intersection(
            [.command, .shift, .control, .option])
        if handleColorPickKey(event, flags: pickFlags) { return true }
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
                wc.userDidChangeZoom()
                return true
            case "9":
                wc.fitImageToWindow()
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
        sv.magnification = min(sv.maxMagnification,
                               max(sv.minMagnification, sv.magnification * factor))
        (window?.windowController as? EditorWindowController)?.userDidChangeZoom()
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
            sv.setMagnification(
                min(sv.maxMagnification,
                    max(sv.minMagnification, sv.magnification * factor)),
                centeredAt: mouse
            )
            (window?.windowController as? EditorWindowController)?.userDidChangeZoom()
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A 1x <-> 2x display change moves the backing scale without touching
        // the magnification, so nothing else would refresh the field's mask.
        updateTextEntryClip()
        needsDisplay = true
    }

    func magnificationDidChange() {
        // The frame around the document is drawn by the superview, so a zoom
        // has to repaint BOTH: repainting only the canvas left the plate edge
        // rendered for the previous magnification.
        superview?.needsDisplay = true
        needsDisplay = true
        updateTextEntryClip()
        guard cropRect != nil else { return }
        window?.invalidateCursorRects(for: self)
    }

    /// Clips the live text field to the document's rounded corners.
    ///
    /// The canvas itself is clipped in `draw`, which does not affect subviews;
    /// the field is the only subview, and a caption typed into a corner would
    /// otherwise show in the preview and be cut from the export. The mask goes
    /// on the FIELD, not the canvas, so nothing that is magnified gets
    /// rasterized — and its `contentsScale` follows the magnification so the
    /// mask itself stays sharp.
    func updateTextEntryClip() {
        guard let field = textField else { return }
        guard documentCornerRadius > 0 else {
            field.layer?.mask = nil
            return
        }
        field.wantsLayer = true
        let magnification = enclosingScrollView?.magnification ?? 1
        let scale = (window?.backingScaleFactor ?? 2) * max(0.01, magnification)
        let rounded = CGPath(
            roundedRect: convert(bounds, to: field),
            cornerWidth: documentCornerRadius,
            cornerHeight: documentCornerRadius, transform: nil)
        let mask = (field.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = field.bounds
        mask.path = rounded
        mask.contentsScale = scale
        field.layer?.mask = mask
    }

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
        // only a selected annotation changes on screen; a bare tool-width
        // tweak needs no canvas repaint at all
        if let sel = selected {
            invalidate(pixelRect: sel.bounds)
        }
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
        // Select gets the plain arrow as the FLOOR; `mouseMoved` raises it to
        // the open hand over an annotation, which is the only place a click
        // grabs anything. Backdrop is a canvas style whose click drafts
        // nothing, so promising a draw with a crosshair would be a lie.
        case .select, .backdrop: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .crop:
            addCursorRect(bounds, cursor: .crosshair)
            if let crop = cropRect {
                addCursorRect(crop, cursor: .openHand)
                let targetSize = 18 * cropChromeScale
                for (handle, rect) in EditableSelectionGeometry.handleRects(for: crop, size: targetSize) {
                    addCursorRect(rect, cursor: handle.cursor)
                }
            }
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    /// The editor's pointer, derived from (tool, hit) in the same order
    /// `mouseDown` branches — the crop tool re-uses the overlay's handle
    /// geometry and tolerance, so what the pointer promises is what the
    /// click performs.
    func canvasCursor(atView vp: CGPoint) -> AppCursor {
        switch currentTool {
        case .select:
            if isMovingSelection { return .closedHand }
            let pp = toPixel(vp)
            return annotations.contains(where: { $0.hitTest(pp) })
                ? .openHand : .arrow
        case .text: return .iBeam
        case .backdrop: return .arrow
        case .crop:
            guard let crop = cropRect else { return .crosshair }
            if case .moving = cropDrag { return .closedHand }
            if let handle = EditableSelectionGeometry.handle(
                at: vp, in: crop, tolerance: 9 * cropChromeScale
            ) {
                return .resize(handle)
            }
            return crop.contains(vp) ? .openHand : .crosshair
        default: return .crosshair
        }
    }

    /// The only place this view sets a cursor, so what the gate reads back is
    /// what the pointer became.
    private func applyCursor(_ cursor: AppCursor) {
        currentCursor = cursor
        cursor.cursor.set()
    }

    private var currentCursor: AppCursor?
    var currentCursorForTesting: AppCursor? { currentCursor }
}

/// Floating sample: a line stroked at the actual width & color, plus the number.
final class StrokePreviewView: NSView {
    var strokeWidth: CGFloat = 3
    var color: NSColor = .systemRed

    /// HUD chrome must never steal the next drawing click during its
    /// one-second lifetime (editor and both in-place surfaces reuse it).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
