import AppKit

// MARK: - Editor window controller

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [EditorWindowController] = []

    private let canvas: EditorCanvasView
    private var sizeBadge: NSButton!
    private var zoomLabel: NSTextField!
    private var colorWell: NSColorWell!
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var cropApplyButton: NSButton!
    private var cropCancelButton: NSButton!
    private var cropActionBar: NSStackView!
    private var scrollView: NSScrollView!
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
        canvas.onImageChange = { [weak self] in
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

        let stack = NSStackView(
            views: [leftPad, copyBtn, saveBtn, pinBtn, ocrBtn, translateBtn, sep()] + toolViews +
                   [sep(), colorWell, NSView(), sizeBadge, sep(), zoomLabel]
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
        let imageSize = canvas.image.pointSize
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
        let imageSize = canvas.image.pointSize
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

    func refreshLabels() {
        let size = canvas.image.pointSize
        let px = canvas.image.pixelSize
        sizeBadge.title = "\(Int(size.width))×\(Int(size.height))pt"
        sizeBadge.toolTip =
            "\(Int(px.width))×\(Int(px.height)) px — click to scale. Does not change “Resize retina screenshots” on save."
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

    /// Slice B seam: the real toolbar buttons, in `EditorTool.allCases` order,
    /// so a gate can assert overflow/wrap and accessibility on the production
    /// toolbar rather than on a re-created copy.
    var toolButtonsForTesting: [(tool: EditorTool, button: NSButton)] {
        EditorTool.allCases.compactMap { tool in
            toolButtons[tool].map { (tool, $0) }
        }
    }

    func selectTool(_ tool: EditorTool) {
        canvas.currentTool = tool
        let cropping = tool == .crop
        cropActionBar?.isHidden = !cropping
        cropApplyButton?.isEnabled = cropping && canvas.hasValidCropSelection
        for (t, b) in toolButtons {
            b.contentTintColor = t == tool ? .controlAccentColor : .lightGray
        }
    }

    // MARK: actions

    @objc private func toolTapped(_ sender: NSButton) {
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
        guard let flat = canvas.flattened() else {
            ToastHUD.show(
                "Couldn't render the redaction — nothing was exported",
                symbol: "exclamationmark.triangle.fill")
            return nil
        }
        return flat
    }

    @objc func copyImage() {
        guard let flat = flattenedOrWarn() else { return }
        terminalDependencies.copyToClipboard(flat)
        ToastHUD.show("Copied to clipboard")
        window?.close()
    }

    /// ⌘S / Save button: choose where to save via the system panel. Shares
    /// SaveService.saveAs with the overlay action router so the panel/write
    /// behavior cannot drift between the two surfaces.
    @objc func saveImage() {
        guard let window else { return }
        guard let flat = flattenedOrWarn() else { return }
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
        guard let flat = flattenedOrWarn() else { return }
        terminalDependencies.pin(flat)
        window?.close()
    }

    @objc func runOCR() { recognizeText(autoTranslate: false) }
    @objc func runTranslate() { recognizeText(autoTranslate: true) }

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
        // Closing supersedes every OCR job in flight: a late result must not
        // touch annotations belonging to a window that is gone.
        for blur in canvas.annotations.compactMap({ $0 as? BlurAnnotation }) {
            blur.bumpRedactionGeneration()
        }
        NotificationCenter.default.removeObserver(self)
        PixelSamplerCache.release(canvas.image.cgImage)
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
        didSet {
            if oldValue == .crop, currentTool != .crop {
                cancelCropSelection()
            }
            window?.invalidateCursorRects(for: self)
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
    private var textField: NSTextField?
    private var editingTextAnnotation: TextAnnotation?

    init(image: CapturedImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image.pointSize))
        wantsLayer = true
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

    /// Slice B seam: drives the SHARED regional-pixelation failure so the
    /// editor takes production's fail-closed path (no clean base on screen, no
    /// export, no close) rather than a canvas-only shortcut.
    static var forcePixellateFailureForTesting: Bool {
        get { AnnotationRenderer.forceRegionalPixelateFailureForTesting }
        set { AnnotationRenderer.forceRegionalPixelateFailureForTesting = newValue }
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
    func flattened() -> CapturedImage? {
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
        if currentTool == .crop, let crop = cropRect, hasValidCropSelection {
            let viewRect = crop.intersection(bounds)
            let requested = EditableSelectionGeometry.pixelCropRect(
                for: viewRect, in: bounds, scale: pxScale)
            let imageBounds = CGRect(
                x: 0, y: 0, width: base.width, height: base.height)
            let px = requested.intersection(imageBounds)
            // FAIL CLOSED: if the crop cannot be materialized we must NOT fall
            // back to the full base — that would export the pixels the user
            // just cropped away.
            guard !viewRect.isNull, viewRect.width >= 4, viewRect.height >= 4,
                  !px.isNull, px.width >= 1, px.height >= 1,
                  let cropped = base.cropping(to: px),
                  let owned = cropped.materialized()
            else { return nil }
            let offset = EditableSelectionGeometry.annotationOffset(
                forPixelCrop: px, imageHeight: CGFloat(base.height))
            for mark in marks {
                mark.move(by: CGPoint(x: -offset.x, y: -offset.y))
            }
            base = owned
            croppedBase = owned
        }

        guard let cg = SliceBExport.checkedRender(
            base: base, annotations: marks, pixellated: nil,
            budgetBytes: SliceBExport.defaultBudgetBytes, pixelScale: pxScale)
        else { return nil }

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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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

    private func snapshot() -> ([Annotation], CapturedImage) {
        (annotations.map { $0.copyAnnotation() }, image)
    }

    func registerUndoSnapshot() {
        historyMutationCountForTesting += 1
        // Any structural edit (delete, crop, resize, undo, redo) supersedes
        // every OCR job in flight: a late result must not narrow a mask on an
        // annotation the user has already changed.
        for blur in annotations.compactMap({ $0 as? BlurAnnotation }) {
            blur.bumpRedactionGeneration()
        }
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
        lastMousePixel = toPixel(vp)
        pointerInsideView = true
    }

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
        case .crop:
            selected = nil
            if event.clickCount >= 2, let crop = cropRect, crop.contains(vp) {
                applyCropSelection()
            } else if let crop = cropRect,
                      let handle = EditableSelectionGeometry.handle(
                        at: vp, in: crop, tolerance: 9 * cropChromeScale
                      ) {
                cropDrag = .resizing(handle: handle, original: crop)
                handle.cursor.set()
            } else if let crop = cropRect, crop.contains(vp) {
                cropDrag = .moving(start: vp, original: crop)
                NSCursor.closedHand.set()
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
        case .blur:
            if let blur = drafting as? BlurAnnotation {
                let before = blur.rect
                blur.rect = CGRect(
                    x: min(dragStartPoint.x, pp.x), y: min(dragStartPoint.y, pp.y),
                    width: abs(pp.x - dragStartPoint.x), height: abs(pp.y - dragStartPoint.y)
                )
                invalidate(pixelRect: before.union(blur.rect))
            }
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
                annotations.append(draft)
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
        isMovingSelection = false
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
            a.move(by: CGPoint(x: -offset.x, y: -offset.y))
        }
        setImage(CapturedImage(cgImage: owned, scale: pxScale))
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
        guard abs(factor - 1) >= 0.0001,
              let scaled = ImageResizer.scale(image, by: factor) else { return }
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
    }

    /// Slice B seams: a gate needs to put the canvas into a realistic state
    /// (live crop selection, live text edit, a selected mark) and then prove a
    /// failed export changed NOTHING.
    func selectForTesting(_ annotation: Annotation?) {
        selected = annotation
        needsDisplay = true
    }

    func setCropSelectionForTesting(_ rect: CGRect) {
        cropRect = rect
        notifyCropSelectionChange()
        needsDisplay = true
    }

    /// Puts a real value in the live text field so a fingerprint can prove a
    /// failed export did not swallow or commit it.
    func setPendingTextForTesting(_ value: String) {
        textField?.stringValue = value
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
                "font=\(field.font?.fontName ?? "-")/\(field.font?.pointSize ?? -1)",
                "traits=\(field.font.map { NSFontManager.shared.traits(of: $0).rawValue } ?? 0)",
                "textColor=\(rgbaString(field.textColor))",
                "backing=[\(backing)]",
            ].joined(separator: " ")
        } ?? "none"
        return [
            "px=\(SelfTest.imageHashForTesting(image.cgImage))",
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
                needsDisplay = true
            }
            return
        }
        if handleSliceAKey(event, flags: flags, chars: chars) { return }
        if flags.isEmpty, let tool = SliceAHotkeys.editorToolKeys[chars] {
            (window?.windowController as? EditorWindowController)?.selectTool(tool)
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

    func magnificationDidChange() {
        guard cropRect != nil else { return }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        case .select: addCursorRect(bounds, cursor: .arrow)
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
