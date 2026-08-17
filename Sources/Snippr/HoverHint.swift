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
            // Long hints WRAP instead of growing: the pixelate-text sentence
            // is far wider than the scroll panel's window.
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: HoverHint.horizontalPadding),
                label.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -HoverHint.horizontalPadding),
                label.topAnchor.constraint(
                    equalTo: topAnchor, constant: HoverHint.verticalPadding),
                label.bottomAnchor.constraint(
                    equalTo: bottomAnchor, constant: -HoverHint.verticalPadding),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Decoration only: a hint must never intercept a click meant for the
        /// button underneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A tracking area's `userInfo` is retained by the area, and the area is
    /// retained by the button. Putting the button itself in there closes the
    /// loop button → area → userInfo → button and leaks every toolbar the app
    /// has ever built. The box breaks it.
    private final class WeakButton: NSObject {
        weak var button: NSButton?
        init(_ button: NSButton) { self.button = button }
    }

    /// The widest a hint may be. Beyond this the sentence wraps rather than
    /// growing: the scroll panel's window is only ~206pt, so a long hint would
    /// otherwise be wider than the view it must sit inside and clamp to a
    /// negative origin — visibly cut off at the left edge.
    static let maxWidth: CGFloat = 240
    fileprivate static let horizontalPadding: CGFloat = 8
    fileprivate static let verticalPadding: CGFloat = 5

    /// Measures the wrapped sentence. `intrinsicContentSize` reports a single
    /// unwrapped line, which is what made a long hint wider than its host.
    private static func size(
        for label: NSTextField, text: String, maxWidth: CGFloat
    ) -> CGSize {
        let inner = max(20, maxWidth - horizontalPadding * 2)
        label.preferredMaxLayoutWidth = inner
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 11)])
        return CGSize(
            width: min(maxWidth, ceil(bounding.width) + horizontalPadding * 2),
            height: max(22, ceil(bounding.height) + verticalPadding * 2))
    }

    private let hint = HintView()
    private var pending: DispatchWorkItem?
    private weak var shownFor: NSButton?
    private var attached: [WeakButton] = []
    private var mouseMonitor: Any?

    /// A press anywhere in the app takes the hint down and cancels anything
    /// scheduled. A tracking area never reports mouse-down, and routing it
    /// through each host would still miss the editor canvas, which does not
    /// own the hint — so the press is observed once, here. The monitor only
    /// OBSERVES: it returns the event untouched, so no host loses a click.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
    }

    /// Explicit mouse-down route for hosts that already funnel their presses,
    /// and for gates, which cannot post a real event into the monitor.
    func mouseDidGoDown() { hide() }
    /// The hint text, held here rather than read back from `toolTip`, because
    /// the native tooltip is switched OFF on every attached button: in the
    /// editor — an ordinary, activating window — AppKit would otherwise show
    /// its own tooltip beside this one and the user would see two.
    private var texts: [ObjectIdentifier: String] = [:]

    /// Watches these buttons. The tracking areas are `.activeAlways`, because
    /// `.activeInKeyWindow` would never fire on an overlay that is not key.
    func attach(to buttons: [NSButton]) {
        installMouseMonitor()
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
                userInfo: [
                    "snipprHoverHint": true, "button": WeakButton(button),
                ]))
            attached.append(WeakButton(button))
        }
    }

    /// Updates the sentence for a button that describes itself differently
    /// over time — the editor's size badge restates the pixel dimensions on
    /// every layout. Writing `toolTip` directly would switch AppKit's own
    /// tooltip back on and leave the hint quoting the previous size.
    func setText(_ text: String, for button: NSButton) {
        texts[ObjectIdentifier(button)] = text
        button.setAccessibilityLabel(text)
        button.setAccessibilityHelp(text)
        button.toolTip = nil
        if shownFor === button { hint.label.stringValue = text }
    }

    /// Undoes `attach`: removes the tracking areas, drops the catalog and
    /// takes any visible hint down. A host that is torn down while the pointer
    /// sits on a button would otherwise leave a scheduled hint to fire into a
    /// window that is already closing.
    func detachAll() {
        hide()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        for box in attached {
            guard let button = box.button else { continue }
            for area in button.trackingAreas
            where area.userInfo?["snipprHoverHint"] != nil {
                button.removeTrackingArea(area)
            }
        }
        attached.removeAll()
        texts.removeAll()
    }

    override func mouseEntered(with event: NSEvent) {
        guard let box = event.trackingArea?.userInfo?["button"] as? WeakButton,
              let button = box.button
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
        // Never while a mouse button is down. The hint is scheduled on enter,
        // so pressing and HOLDING a toolbar button — or pressing and dragging
        // onto the canvas — would otherwise let it appear mid-gesture, and the
        // click handler that dismisses it does not run until mouse-up.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        hint.label.stringValue = text
        // The rect the hint has to stay inside: the host's content view, and
        // — for a window that extends past the usable screen — the visible
        // frame as well, so a hint never lands under the menu bar or the Dock.
        var allowed = content.bounds.insetBy(dx: 2, dy: 2)
        if let window = button.window, let screen = window.screen {
            let visible = content.convert(
                window.convertFromScreen(screen.visibleFrame), from: nil)
            let clipped = allowed.intersection(visible)
            // Only when the intersection still leaves somewhere to draw: a
            // headless or off-screen window must not shrink it to nothing.
            if !clipped.isNull, clipped.width > 40, clipped.height > 30 {
                allowed = clipped
            }
        }
        hint.frame.size = Self.size(
            for: hint.label, text: text, maxWidth: min(
                Self.maxWidth, max(40, allowed.width)))
        content.addSubview(hint, positioned: .above, relativeTo: nil)
        let anchor = button.convert(button.bounds, to: content)
        var origin = CGPoint(
            x: anchor.midX - hint.frame.width / 2,
            y: anchor.minY - hint.frame.height - 6)
        // Below the button by default, above it when there is no room, and
        // never outside the region computed above.
        if origin.y < allowed.minY {
            origin.y = anchor.maxY + 6
        }
        origin.x = min(
            max(allowed.minX, origin.x), allowed.maxX - hint.frame.width)
        origin.y = min(
            max(allowed.minY, origin.y), allowed.maxY - hint.frame.height)
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
