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
        if finish.inputs.afterShow {
            ScrollResultPanel.show(
                image: image, inputs: finish.inputs, screen: finish.screen,
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
        let imageSize = CGSize(
            width: max(120, pointSize.width * fit),
            height: max(80, pointSize.height * fit))
        let contentSize = CGSize(
            width: imageSize.width,
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
            x: 0, y: toolbarHeight,
            width: imageSize.width, height: imageSize.height))
        imageView.image = image.nsImage
        imageView.imageScaling = .scaleProportionallyDown
        content.addSubview(imageView)

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

    private func buildToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        var buttons: [NSButton] = []
        let size = CGSize(width: 34, height: 30)
        let spacing: CGFloat = 2
        for (index, item) in Self.items.enumerated() {
            let button = NSButton(frame: CGRect(
                x: 8 + CGFloat(index) * (size.width + spacing),
                y: (height - size.height) / 2,
                width: size.width, height: size.height))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(
                systemSymbolName: item.symbol,
                accessibilityDescription: item.tooltip)
            button.toolTip = item.tooltip
            button.tag = index
            button.target = self
            button.action = #selector(toolbarPressed(_:))
            bar.addSubview(button)
            buttons.append(button)
        }
        let close = NSButton(frame: CGRect(
            x: width - size.width - 8, y: (height - size.height) / 2,
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
        guard sender.tag >= 0, sender.tag < Self.items.count else { return }
        perform(intent: Self.items[sender.tag].intent)
    }

    func performActionForTesting(_ intent: CaptureIntent) {
        perform(intent: intent)
    }

    override func keyDown(with event: NSEvent) {
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
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            perform(intent: .copy)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func dismiss() {
        if ScrollResultPanel.current === self { ScrollResultPanel.current = nil }
        orderOut(nil)
    }

    /// Same exactly-once + terminal-order rules as the area review: Copy
    /// commits then closes; Pin/OCR/editor tear down BEFORE presenting; Save
    /// locks the panel in-flight and stays open on cancel/failure. All
    /// commits use source `.scrollResult` with a nil rect, so the
    /// Repeat-Area memory is never touched.
    private func perform(intent: CaptureIntent) {
        guard !saving else { return }
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
