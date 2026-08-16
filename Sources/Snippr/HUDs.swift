import AppKit

// MARK: - Toast notification (Shottr's "Custom Notification" style)

final class ToastHUD {
    private static var panel: NSPanel?
    private static var hideWorkItem: DispatchWorkItem?

    /// `on`/`above` route a toast that must outrank a specific surface:
    /// an area-overlay failure toast at the default .statusBar level would
    /// sit BEHIND the .screenSaver overlay on the capture screen. Callers
    /// with such a surface pass its screen and level; everything else keeps
    /// the defaults (no global level raise).
    static func show(
        _ message: String, symbol: String = "checkmark.circle.fill",
        duration: TimeInterval = 2.2,
        on screen: NSScreen? = nil, above minLevel: NSWindow.Level? = nil
    ) {
        guard Settings.shared.confirmationStyle != .none else { return }
        // Recorded synchronously, before the hop to main, so a headless gate
        // can assert WHICH failure the user was told about.
        lastMessageForTesting = message
        DispatchQueue.main.async {
            showNow(message, symbol: symbol, duration: duration,
                    screen: screen, minLevel: minLevel)
        }
    }

    static var panelForTesting: NSPanel? { panel }

    nonisolated(unsafe) static var lastMessageForTesting: String?

    private static func showNow(
        _ message: String, symbol: String, duration: TimeInterval,
        screen preferredScreen: NSScreen?, minLevel: NSWindow.Level?
    ) {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 320

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let size = stack.fittingSize
        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let origin = CGPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 60
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        if let minLevel {
            p.level = NSWindow.Level(rawValue: max(
                minLevel.rawValue + 1, NSWindow.Level.statusBar.rawValue))
        } else {
            p.level = .statusBar
        }
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = container
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                if panel === p { panel = nil }
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

// MARK: - Pinned screenshot (floating always-on-top image)

final class PinWindow: NSPanel {
    private static var pins: [PinWindow] = []
    private var scaleFactor: CGFloat = 1
    private let captured: CapturedImage

    static func pin(_ image: CapturedImage, near point: CGPoint? = nil) {
        let win = PinWindow(image: image, near: point)
        pins.append(win)
        win.orderFrontRegardless()
    }

    private init(image: CapturedImage, near point: CGPoint?) {
        self.captured = image
        let size = image.pointSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = point ?? CGPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let iv = NSImageView(image: image.nsImage)
        iv.imageScaling = .scaleAxesIndependently
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        contentView = iv
    }

    override var canBecomeKey: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // scroll to zoom the pinned image
        let delta = event.scrollingDeltaY * (Settings.shared.zoomReverseScroll ? -1 : 1)
        scaleFactor = min(4, max(0.2, scaleFactor * (1 + delta / 200)))
        let base = captured.pointSize
        let newSize = CGSize(width: base.width * scaleFactor, height: base.height * scaleFactor)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(CGRect(
            x: center.x - newSize.width / 2, y: center.y - newSize.height / 2,
            width: newSize.width, height: newSize.height
        ), display: true)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            close()
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } // Esc
        else if event.keyCode == 8, event.modifierFlags.contains(.command) { // ⌘C
            SaveService.shared.copyToClipboard(captured)
            ToastHUD.show("Copied to clipboard")
        } else {
            super.keyDown(with: event)
        }
    }

    override func close() {
        PinWindow.pins.removeAll { $0 === self }
        super.close()
    }
}

// MARK: - Corner thumbnail preview

final class ThumbnailHUD {
    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    static func show(_ image: CapturedImage, onOpen: @escaping @MainActor (CapturedImage) -> Void) {
        DispatchQueue.main.async { showNow(image, onOpen: onOpen) }
    }

    private static func showNow(_ image: CapturedImage, onOpen: @escaping @MainActor (CapturedImage) -> Void) {
        dismiss()

        let maxW: CGFloat = 260
        let ratio = min(1, maxW / image.pointSize.width)
        let size = CGSize(
            width: max(60, image.pointSize.width * ratio),
            height: max(40, image.pointSize.height * ratio)
        )

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.width - 20,
            y: screen.visibleFrame.minY + 20
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ThumbnailView(image: image, onOpen: { img in
            dismiss()
            onOpen(img)
        }, onClose: { dismiss() })
        view.frame = CGRect(origin: .zero, size: size)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p

        if let secs = Settings.shared.hidePreviewMode.seconds {
            hideTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in
                dismiss()
            }
        }
    }

    static func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ThumbnailView: NSView {
    private let image: CapturedImage
    private let onOpen: @MainActor (CapturedImage) -> Void
    private let onClose: () -> Void
    private var closeButton: NSButton!

    init(image: CapturedImage, onOpen: @escaping @MainActor (CapturedImage) -> Void, onClose: @escaping () -> Void) {
        self.image = image
        self.onOpen = onOpen
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true

        let iv = NSImageView(image: image.nsImage)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)
        iv.frame = bounds

        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
            target: self, action: #selector(closeTapped)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.frame = CGRect(x: 4, y: 0, width: 22, height: 22)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
        closeButton.frame = CGRect(x: 4, y: bounds.height - 26, width: 22, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    override func mouseUp(with event: NSEvent) { onOpen(image) }

    @objc private func closeTapped() { onClose() }
}
