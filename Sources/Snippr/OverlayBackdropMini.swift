import AppKit

// MARK: - Overlay quick-backdrop (WP4b)
//
// Subset of the editor sidebar, living on the area-review overlay. Smaller
// than the WP4a mockup (292×200, chips 60×40). Ember and Meadow stay in the
// editor — the overlay's ten thumbs plus None are the quick set boenben
// approved (original six + Lavender/Rose/Lagoon/Midnight).

enum OverlayQuickBackdrop {
    static let gradientIds = [
        "ocean", "sunset", "mint", "graphite",
        "lavender", "rose", "lagoon", "midnight",
        "paper", "fog",
    ]
    static let paddingTicks: [(label: String, fraction: CGFloat)] = [
        ("S", 0.04), ("M", 0.06), ("L", 0.10),
    ]
    static let columns = 4
    static let chipSize = CGSize(width: 44, height: 28)
    static let chipSpacing: CGFloat = 4
    static let contentInset: CGFloat = 8
    static let headerHeight: CGFloat = 16
    static let paddingRowHeight: CGFloat = 24
    static let footerHeight: CGFloat = 18
    static let sectionGap: CGFloat = 6
    static let cornerRadius: CGFloat = 10

    /// WP4a HTML mockup. WP4b must beat both numbers.
    static let mockupSize = CGSize(width: 292, height: 200)
    static let mockupChipSize = CGSize(width: 60, height: 40)

    static var itemCount: Int { 1 + gradientIds.count }

    static var chipRows: Int {
        (itemCount + columns - 1) / columns
    }

    static var gridSize: CGSize {
        CGSize(
            width: CGFloat(columns) * chipSize.width
                + CGFloat(columns - 1) * chipSpacing,
            height: CGFloat(chipRows) * chipSize.height
                + CGFloat(chipRows - 1) * chipSpacing)
    }

    static var size: CGSize {
        let grid = gridSize
        return CGSize(
            width: contentInset * 2 + grid.width,
            height: contentInset
                + headerHeight + sectionGap
                + grid.height + sectionGap
                + paddingRowHeight + sectionGap
                + footerHeight
                + contentInset)
    }

    static func style(gradientId: String, padding: CGFloat) -> BackdropStyle {
        var s = BackdropStyle.gradient(gradientId)
        s.paddingFraction = padding
        return s.clamped()
    }
}

enum OverlayBackdropMiniIdentifier {
    static let root = "backdrop.overlay.mini"
    static let none = "backdrop.overlay.none"
    static let paddingS = "backdrop.overlay.padding.S"
    static let paddingM = "backdrop.overlay.padding.M"
    static let paddingL = "backdrop.overlay.padding.L"
    static let openEditor = "backdrop.overlay.openEditor"

    static func gradient(_ id: String) -> String {
        "backdrop.overlay.gradient.\(id)"
    }

    static func padding(_ label: String) -> String {
        "backdrop.overlay.padding.\(label)"
    }
}

/// Built separately from being shown: a nested `NSMenu.popUp` run loop is
/// what the five-item menu used, and a headless gate cannot drive that.
/// The mini is an ordinary subview so construction, layout and clicks are
/// the same path the gate takes.
final class OverlayBackdropMiniView: NSView {
    var onChoose: ((BackdropStyle) -> Void)?
    var onOpenEditor: (() -> Void)?

    private(set) var style: BackdropStyle = .none
    private(set) var hintButtons: [NSButton] = []

    private var noneButton: NSButton!
    private var gradientButtons: [String: NSButton] = [:]
    private var paddingButtons: [String: NSButton] = [:]
    private var openEditorButton: NSButton!
    private var titleLabel: NSTextField!

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 28 / 255, green: 30 / 255,
                                         blue: 36 / 255, alpha: 0.96).cgColor
        layer?.cornerRadius = OverlayQuickBackdrop.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        identifier = NSUserInterfaceItemIdentifier(
            OverlayBackdropMiniIdentifier.root)
        setAccessibilityIdentifier(OverlayBackdropMiniIdentifier.root)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Backdrop")
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func sync(style: BackdropStyle) {
        self.style = style
        refreshSelection()
    }

    func control(identifier: String) -> NSButton? {
        if noneButton.identifier?.rawValue == identifier { return noneButton }
        if openEditorButton.identifier?.rawValue == identifier {
            return openEditorButton
        }
        if let button = gradientButtons.values.first(where: {
            $0.identifier?.rawValue == identifier
        }) { return button }
        return paddingButtons.values.first {
            $0.identifier?.rawValue == identifier
        }
    }

    private func build() {
        let spec = OverlayQuickBackdrop.self
        let inset = spec.contentInset
        var y = inset

        titleLabel = NSTextField(labelWithString: "Backdrop")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.96, alpha: 1)
        titleLabel.frame = CGRect(
            x: inset, y: y, width: spec.gridSize.width, height: spec.headerHeight)
        addSubview(titleLabel)
        y += spec.headerHeight + spec.sectionGap

        noneButton = makeChipButton(
            title: "None",
            identifier: OverlayBackdropMiniIdentifier.none,
            help: "None")
        noneButton.image = BackdropSwatch.image(
            for: .none, size: spec.chipSize)
        noneButton.frame = chipFrame(index: 0, originY: y)
        addSubview(noneButton)

        for (offset, id) in spec.gradientIds.enumerated() {
            let entry = BackdropGradientCatalog.entry(id: id)
            let help = entry?.name ?? id.capitalized
            let button = makeChipButton(
                title: help,
                identifier: OverlayBackdropMiniIdentifier.gradient(id),
                help: help)
            button.image = BackdropSwatch.image(
                for: .gradient(id), size: spec.chipSize)
            button.frame = chipFrame(index: offset + 1, originY: y)
            gradientButtons[id] = button
            addSubview(button)
        }
        y += spec.gridSize.height + spec.sectionGap

        let padWidth = spec.gridSize.width / CGFloat(spec.paddingTicks.count)
        for (index, tick) in spec.paddingTicks.enumerated() {
            let button = NSButton(frame: CGRect(
                x: inset + CGFloat(index) * padWidth,
                y: y, width: padWidth - 2, height: spec.paddingRowHeight))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.title = tick.label
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.contentTintColor = NSColor(white: 0.72, alpha: 1)
            button.setAccessibilityLabel("Padding \(tick.label)")
            button.toolTip = "Padding \(tick.label)"
            button.identifier = NSUserInterfaceItemIdentifier(
                OverlayBackdropMiniIdentifier.padding(tick.label))
            button.setAccessibilityIdentifier(
                OverlayBackdropMiniIdentifier.padding(tick.label))
            button.tag = 100 + index
            button.target = self
            button.action = #selector(paddingClicked(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            paddingButtons[tick.label] = button
            addSubview(button)
        }
        y += spec.paddingRowHeight + spec.sectionGap

        openEditorButton = NSButton(frame: CGRect(
            x: inset, y: y, width: spec.gridSize.width,
            height: spec.footerHeight))
        openEditorButton.bezelStyle = .regularSquare
        openEditorButton.isBordered = false
        openEditorButton.title = "Open in Editor…"
        openEditorButton.font = .systemFont(ofSize: 11, weight: .medium)
        openEditorButton.contentTintColor = NSColor(
            srgbRed: 0.49, green: 0.69, blue: 1, alpha: 1)
        openEditorButton.alignment = .right
        openEditorButton.setAccessibilityLabel("Open in Editor…")
        openEditorButton.toolTip = "Open in Editor…"
        openEditorButton.identifier = NSUserInterfaceItemIdentifier(
            OverlayBackdropMiniIdentifier.openEditor)
        openEditorButton.setAccessibilityIdentifier(
            OverlayBackdropMiniIdentifier.openEditor)
        openEditorButton.target = self
        openEditorButton.action = #selector(openEditorClicked)
        addSubview(openEditorButton)

        var hints: [NSButton] = [noneButton]
        hints.append(contentsOf: spec.gradientIds.compactMap { gradientButtons[$0] })
        hints.append(contentsOf: spec.paddingTicks.compactMap { paddingButtons[$0.label] })
        hints.append(openEditorButton)
        hintButtons = hints
        refreshSelection()
    }

    private func chipFrame(index: Int, originY: CGFloat) -> CGRect {
        let spec = OverlayQuickBackdrop.self
        let row = index / spec.columns
        let column = index % spec.columns
        return CGRect(
            x: spec.contentInset
                + CGFloat(column) * (spec.chipSize.width + spec.chipSpacing),
            y: originY
                + CGFloat(row) * (spec.chipSize.height + spec.chipSpacing),
            width: spec.chipSize.width,
            height: spec.chipSize.height)
    }

    private func makeChipButton(
        title _: String, identifier: String, help: String
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleAxesIndependently
        button.setAccessibilityLabel(help)
        button.toolTip = help
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.target = self
        button.action = #selector(chipClicked(_:))
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        return button
    }

    private func refreshSelection() {
        let selectedId: String? = {
            if style.kind == .none { return nil }
            if style.kind == .gradient { return style.gradientId }
            return nil
        }()
        ring(noneButton, on: style.kind == .none)
        for (id, button) in gradientButtons {
            ring(button, on: selectedId == id)
        }
        let pad = style.paddingFraction
        let closest = OverlayQuickBackdrop.paddingTicks.min {
            abs($0.fraction - pad) < abs($1.fraction - pad)
        }?.label
        for (label, button) in paddingButtons {
            let on = label == closest
            button.layer?.backgroundColor = on
                ? NSColor.controlAccentColor.cgColor
                : NSColor(white: 0.09, alpha: 1).cgColor
            button.contentTintColor = on
                ? .white : NSColor(white: 0.72, alpha: 1)
        }
    }

    private func ring(_ button: NSButton, on: Bool) {
        button.layer?.borderWidth = on ? 2 : 1
        button.layer?.borderColor = on
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
    }

    @objc private func chipClicked(_ sender: NSButton) {
        if sender === noneButton {
            var next = style
            next.kind = .none
            next.gradientId = nil
            next.solidColor = nil
            onChoose?(next.clamped())
            return
        }
        guard let id = gradientButtons.first(where: { $0.value === sender })?.key
        else { return }
        var next = style
        next.kind = .gradient
        next.gradientId = id
        next.solidColor = nil
        onChoose?(next.clamped())
    }

    @objc private func paddingClicked(_ sender: NSButton) {
        guard let label = paddingButtons.first(where: { $0.value === sender })?.key,
              let tick = OverlayQuickBackdrop.paddingTicks.first(where: {
                  $0.label == label
              })
        else { return }
        var next = style
        next.paddingFraction = tick.fraction
        onChoose?(next.clamped())
    }

    @objc private func openEditorClicked() {
        onOpenEditor?()
    }
}
