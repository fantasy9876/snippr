import AppKit

/// Hover hints for toolbar buttons.
///
/// AppKit's own `toolTip` is managed by `NSToolTipManager`, which only shows
/// for the active application — and the capture overlay deliberately never
/// activates (it is ordered in with `orderFrontRegardless` precisely so it can
/// appear while another app keeps focus). The review toolbars therefore had
/// tooltips set on every button that a user could never see.
///
/// This draws the hint itself, inside the host's own window, so it does not
/// depend on activation, does not create a window, and cannot take first
/// responder away from the surface that owns the keyboard.
/// An `NSResponder` because that is what a tracking area may own; it is never
/// inserted into the responder chain, so it cannot take focus from anything.
@MainActor
final class HoverHint: NSResponder {
    /// Matches AppKit's default tooltip delay closely enough that the hint
    /// does not feel like a different mechanism.
    static let delay: TimeInterval = 0.45

    private final class HintView: NSView {
        let label = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Decoration only: a hint must never intercept a click meant for the
        /// button underneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let hint = HintView()
    private var pending: DispatchWorkItem?
    private weak var shownFor: NSButton?
    /// The hint text, held here rather than read back from `toolTip`, because
    /// the native tooltip is switched OFF on every attached button: in the
    /// editor — an ordinary, activating window — AppKit would otherwise show
    /// its own tooltip beside this one and the user would see two.
    private var texts: [ObjectIdentifier: String] = [:]

    /// Watches these buttons. The tracking areas are `.activeAlways`, because
    /// `.activeInKeyWindow` would never fire on an overlay that is not key.
    func attach(to buttons: [NSButton]) {
        for button in buttons {
            let text = button.toolTip ?? button.accessibilityLabel() ?? ""
            if !text.isEmpty {
                texts[ObjectIdentifier(button)] = text
                // Accessibility keeps its own channels — the label is already
                // set by the toolbars, and the help string carries the same
                // sentence for anything that reads it.
                button.setAccessibilityHelp(text)
            }
            button.toolTip = nil
            for area in button.trackingAreas
            where area.userInfo?["snipprHoverHint"] != nil {
                button.removeTrackingArea(area)
            }
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                    .enabledDuringMouseDrag,
                ],
                owner: self,
                userInfo: ["snipprHoverHint": true, "button": button]))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let button = event.trackingArea?.userInfo?["button"] as? NSButton
        else { return }
        schedule(for: button)
    }

    override func mouseExited(with event: NSEvent) {
        hide()
    }

    func schedule(for button: NSButton) {
        cancelPending()
        // The text is the button's own label, so the hint cannot drift from
        // what the accessibility layer reports.
        guard let text = texts[ObjectIdentifier(button)], !text.isEmpty
        else { return }
        let work = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            self.show(text, for: button)
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.delay, execute: work)
    }

    /// Anything that changes what the pointer means dismisses the hint: a
    /// click, a drag, a tool switch, a terminal action, the pointer leaving.
    func hide() {
        cancelPending()
        hint.removeFromSuperview()
        shownFor = nil
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func show(_ text: String, for button: NSButton) {
        guard let content = button.window?.contentView,
              button.window != nil else { return }
        hint.label.stringValue = text
        hint.frame.size = CGSize(
            width: ceil(hint.label.intrinsicContentSize.width) + 16,
            height: 22)
        content.addSubview(hint, positioned: .above, relativeTo: nil)
        let anchor = button.convert(button.bounds, to: content)
        var origin = CGPoint(
            x: anchor.midX - hint.frame.width / 2,
            y: anchor.minY - hint.frame.height - 6)
        // Below the button by default, above it when there is no room, and
        // never outside the window it lives in.
        if origin.y < content.bounds.minY + 2 {
            origin.y = anchor.maxY + 6
        }
        origin.x = min(
            max(content.bounds.minX + 2, origin.x),
            content.bounds.maxX - hint.frame.width - 2)
        origin.y = min(
            max(content.bounds.minY + 2, origin.y),
            content.bounds.maxY - hint.frame.height - 2)
        hint.setFrameOrigin(origin)
        shownFor = button
    }

    // MARK: gate visibility

    /// What the hint WOULD say — so a gate can prove the catalog survived the
    /// native tooltip being switched off.
    func textForTesting(_ button: NSButton) -> String? {
        texts[ObjectIdentifier(button)]
    }
    var visibleTextForTesting: String? {
        hint.superview == nil ? nil : hint.label.stringValue
    }
    var shownForTesting: NSButton? { shownFor }
    var hintFrameForTesting: CGRect? {
        hint.superview == nil ? nil : hint.frame
    }
    func showImmediatelyForTesting(_ button: NSButton) {
        cancelPending()
        guard let text = texts[ObjectIdentifier(button)], !text.isEmpty
        else { return }
        show(text, for: button)
    }
}
