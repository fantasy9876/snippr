import AppKit
import SwiftUI

// MARK: - Backdrop panel (Option A "Studio sidebar", WP6)
//
// Replaces the five-item NSMenu behind the editor's Backdrop button with a
// docked panel. Same policy as the menu it replaces: OPENING it changes
// nothing, and choosing one control edits exactly one field.

/// Sections whose fields `BackdropStyle` already carries but the compositor
/// does not read yet. Alignment / ratio / inset / auto-balance are stored and
/// ignored until WP3, and a control that visibly does nothing is worse than a
/// missing one — so the layout ships now and WP3 flips one flag rather than
/// redesigning the panel around it.
enum BackdropPanelFeature {
    /// WP3 (`6ee5e37`) landed the compositor side, so the controls are live.
    static var geometryEnabled = true
    /// WP2: custom image / wallpaper / blurred sources.
    static var imageSourcesEnabled = false
    /// WP7: named presets and auto-apply.
    static var presetsEnabled = false
}

// MARK: - Swatch

/// A chip is a preview of a fill, so it is drawn by the SAME function the
/// canvas and the export use.
///
/// Building one from `entry.stops` would be a second renderer: `paintFill`
/// ignores the catalog entirely for the four v0 ids and paints the production
/// ramp, so a hand-rolled chip would show a colour the canvas can never
/// produce — the user would pick Ocean and get a different Ocean.
enum BackdropSwatch {
    static let size = NSSize(width: 52, height: 38)

    /// A chip's context is a BITMAP in pixels, exactly like `compose`, so the
    /// grain tile is specified in the same units the export uses. Passing the
    /// chip's @2x scale here instead would halve the tile period and give the
    /// chip a finer grain than the picture it advertises — WP2 split these two
    /// numbers apart for blur for the same reason, and they must not be
    /// re-merged here.
    static let documentPixelsPerUserUnit: CGFloat = 1

    private struct Key: Hashable {
        let style: BackdropStyle
        let width: Int
        let height: Int
        let scale: Int
    }

    /// Bounded, because the key carries the style's CONTINUOUS fields: one
    /// slow drag across Padding is a few hundred distinct styles at ~31KB a
    /// chip, and an unbounded dictionary would keep every frame of that drag
    /// for the life of the process.
    private static let cacheLimit = 96
    private nonisolated(unsafe) static var cache: [Key: NSImage] = [:]
    private nonisolated(unsafe) static var cacheOrder: [Key] = []
    private static let cacheLock = NSLock()

    static var cacheCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }

    /// Called when the panel closes: chips are cheap to redraw and there is no
    /// reason to hold a drag's worth of them while the sidebar is shut.
    static func resetCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheOrder.removeAll()
        cacheLock.unlock()
    }

    static func image(
        for style: BackdropStyle, size: NSSize = size, scale: CGFloat = 2
    ) -> NSImage? {
        let key = Key(
            style: style, width: Int(size.width.rounded()),
            height: Int(size.height.rounded()), scale: Int(scale.rounded()))
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let made = render(style: style, size: size, scale: scale) else {
            return nil
        }
        cacheLock.lock()
        if cache[key] == nil {
            cache[key] = made
            cacheOrder.append(key)
            // Oldest first: a drag's intermediate frames are exactly the ones
            // the user will not come back to.
            while cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cacheLock.unlock()
        return made
    }

    /// Where the stand-in document sits on a chip of this pixel size. Exposed
    /// so the gate that proves the chip is drawn by `drawFrame` reads the SAME
    /// geometry the chip does instead of restating it and drifting from it.
    ///
    /// A chip is NOT a scale model of the canvas. At the document's own 6%
    /// the plate covers about seven eighths of a 52pt chip and the fill — the
    /// only thing the chip exists to show — survives as a hairline border.
    /// So the plate is deliberately small, and the padding fraction moves it
    /// rather than setting it: dragging Padding is still visible here, without
    /// the chip going blank at the default.
    static func frameTarget(pixelSize px: CGSize, style: BackdropStyle) -> CGRect {
        let short = min(px.width, px.height)
        let fraction = min(0.34, max(0.18, 0.18 + style.paddingFraction * 1.2))
        let inset = short * fraction
        return CGRect(
            x: inset, y: inset,
            width: max(1, px.width - inset * 2),
            height: max(1, px.height - inset * 2))
    }

    static func render(
        style: BackdropStyle, size: NSSize, scale: CGFloat
    ) -> NSImage? {
        let px = CGSize(
            width: max(1, size.width * scale), height: max(1, size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: Int(px.width), height: Int(px.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let target = frameTarget(pixelSize: px, style: style)

        if style.kind == .none {
            // No frame at all: the document is the whole chip. Drawing a
            // gradient here would advertise a backdrop that None removes.
            ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: px))
        } else {
            guard SliceBBackdrop.drawFrame(
                in: ctx, size: px, target: target, style: style,
                pixelScale: scale,
                documentPixelsPerUserUnit: documentPixelsPerUserUnit)
            else { return nil }
        }

        // `drawFrame` leaves `target` holding the fill, ready for the document.
        // The chip has no document, so it gets a stand-in plate clipped to the
        // same radius the real one would use.
        let plateRect = style.kind == .none
            ? CGRect(origin: .zero, size: px).insetBy(
                dx: px.width * 0.12, dy: px.height * 0.14)
            : target
        // The radius table has a POINT floor (12 at Medium) meant for a real
        // document; on a 20pt plate that floor is half the short edge and
        // every corner style renders as the same pill. The chip therefore
        // shows the radius as the fraction of the short edge it is, which is
        // what actually distinguishes □ / S / M / L.
        let plateShort = min(plateRect.width, plateRect.height)
        let radius: CGFloat = {
            switch style.cornerStyle {
            case .none: return 0
            case .small: return plateShort * 0.08
            case .medium: return plateShort * 0.16
            case .large: return plateShort * 0.26
            }
        }()
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
        ctx.fill(plateRect)
        ctx.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
        ctx.fill(CGRect(
            x: plateRect.minX, y: plateRect.maxY - 4 * scale,
            width: plateRect.width, height: 4 * scale))
        ctx.restoreGState()

        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}

// MARK: - Model

/// Holds the style the panel is editing and hands every change back to the
/// canvas. The panel never mutates the document itself: one owner, one undo.
final class BackdropPanelModel: ObservableObject {
    @Published private(set) var style: BackdropStyle

    /// Applies a whole style. Returns false when the canvas refused it — an
    /// over-budget backdrop, for example — so the panel can stay truthful
    /// about what the document is actually wearing.
    var onApply: ((BackdropStyle) -> Bool)?
    /// Corner is document state AND the Settings default for the next capture,
    /// so it has its own entry point rather than riding on `onApply`.
    var onCornerStyle: ((BackdropCornerStyle) -> Void)?
    /// A slider drag is ONE edit. The canvas registers single-field undo per
    /// change, so the drag is wrapped in an undo group instead: without this a
    /// user dragging Padding across 40 steps would need 40 undos to get back.
    ///
    /// The group is opened LAZILY, on the first change the drag actually
    /// produces. Clicking a slider's knob without moving it still sends
    /// begin/end, and opening a group there left an empty one on the stack —
    /// one Cmd+Z that undoes nothing, which reads as a lost undo.
    var onBeginContinuousEdit: (() -> Void)?
    var onEndContinuousEdit: (() -> Void)?

    private var isDragging = false
    private var groupIsOpen = false

    init(style: BackdropStyle) { self.style = style }

    /// The canvas is the source of truth; the panel follows it so that undo,
    /// a preset applied from elsewhere and the panel never disagree.
    func syncFromCanvas(_ style: BackdropStyle) {
        guard style != self.style else { return }
        self.style = style
    }

    func apply(_ next: BackdropStyle) {
        let clamped = next.clamped()
        guard clamped != style else { return }
        if isDragging && !groupIsOpen {
            groupIsOpen = true
            onBeginContinuousEdit?()
        }
        if onApply?(clamped) == true {
            style = clamped
        }
    }

    func beginContinuousEdit() { isDragging = true }

    func endContinuousEdit() {
        isDragging = false
        guard groupIsOpen else { return }
        groupIsOpen = false
        onEndContinuousEdit?()
    }

    func choose(gradientId: String) {
        var next = style
        next.kind = .gradient
        next.gradientId = gradientId
        apply(next)
    }

    func choose(solidHex: String) {
        var next = style
        next.kind = .solid
        next.solidColor = solidHex
        apply(next)
    }

    /// Picking a cell is a statement about where the shot sits, so it turns
    /// auto-balance off — in ONE apply, so it is one undo. The grid stays
    /// live while auto-balance is on rather than dimming: a control that is
    /// disabled by the default setting reads as broken.
    func choose(alignment: BackdropAlignment) {
        var next = style
        next.alignment = alignment
        next.autoBalance = false
        apply(next)
    }

    /// Turning auto-balance back on KEEPS the anchor. The compositor ignores
    /// it, and turning auto-balance off again returns the shot where the user
    /// last put it instead of to the centre.
    func setAutoBalance(_ on: Bool) {
        guard on != style.autoBalance else { return }
        var next = style
        next.autoBalance = on
        apply(next)
    }

    func chooseNone() {
        var next = style
        next.kind = .none
        apply(next)
    }

    func setCornerStyle(_ corner: BackdropCornerStyle) {
        guard corner != style.cornerStyle else { return }
        onCornerStyle?(corner)
        var next = style
        next.cornerStyle = corner
        style = next
    }

    var isNone: Bool { style.kind == .none }
}

// MARK: - View

/// The Option A sidebar. Every control edits one field of `BackdropStyle`.
struct BackdropPanelView: View {
    @ObservedObject var model: BackdropPanelModel

    static let width: CGFloat = 236

    private let gradientColumns = Array(
        repeating: GridItem(.fixed(BackdropSwatch.size.width), spacing: 8),
        count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                noneButton
                gradients
                solids
                sliders
                if BackdropPanelFeature.geometryEnabled { geometry }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: NSColor(white: 0.11, alpha: 1)))
    }

    private var noneButton: some View {
        Button {
            model.chooseNone()
        } label: {
            Text("None").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityIdentifier(BackdropPanelIdentifier.none)
        .help("Remove the backdrop")
    }

    private var gradients: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Gradients", trailing: "\(BackdropGradientCatalog.entries.count)")
            LazyVGrid(columns: gradientColumns, spacing: 8) {
                ForEach(BackdropGradientCatalog.entries, id: \.id) { entry in
                    swatchButton(
                        style: styleFor(gradientId: entry.id),
                        isSelected: model.style.kind == .gradient
                            && model.style.gradientId == entry.id,
                        help: entry.name,
                        identifier: BackdropPanelIdentifier.gradient(entry.id)
                    ) {
                        model.choose(gradientId: entry.id)
                    }
                }
            }
        }
    }

    private var solids: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Plain color")
            HStack(spacing: 7) {
                ForEach(BackdropSolidCatalog.swatches, id: \.id) { swatch in
                    let selected = model.style.kind == .solid
                        && model.style.solidColor?.caseInsensitiveCompare(swatch.hex)
                            == .orderedSame
                    Button {
                        model.choose(solidHex: swatch.hex)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: BackdropGradientCatalog
                                .nsColor(hex: swatch.hex) ?? .black))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().stroke(
                                    selected ? Color.accentColor
                                        : Color.white.opacity(0.25),
                                    lineWidth: selected ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.id.capitalized)
                    .accessibilityIdentifier(
                        BackdropPanelIdentifier.solid(swatch.id))
                }
            }
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelledSlider(
                "Padding",
                value: Binding(
                    get: { model.style.paddingFraction },
                    set: { v in
                        var next = model.style
                        next.paddingFraction = v
                        model.apply(next)
                    }),
                range: BackdropStyle.paddingFractionRange,
                identifier: BackdropPanelIdentifier.padding)

            // Corners is a FOUR-TICK control, not a 0–32 pt slider: the radius
            // scales with the short edge, so an absolute point value renders a
            // 4K capture square and a phone screenshot as a lozenge.
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Corners")
                Picker("", selection: Binding(
                    get: { model.style.cornerStyle },
                    set: { model.setCornerStyle($0) })
                ) {
                    ForEach(BackdropCornerStyle.allCases, id: \.self) { style in
                        Text(shortCornerTitle(style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(BackdropPanelIdentifier.corners)
            }

            labelledSlider(
                "Shadow",
                value: Binding(
                    get: { model.style.shadowStrength },
                    set: { v in
                        var next = model.style
                        next.shadowStrength = v
                        model.apply(next)
                    }),
                range: BackdropStyle.shadowStrengthRange,
                identifier: BackdropPanelIdentifier.shadow)
        }
        .disabled(model.isNone)
        .opacity(model.isNone ? 0.4 : 1)
    }

    /// WP3 owns the geometry these write to. Hidden until it lands so the
    /// panel never offers a control the compositor ignores.
    private var geometry: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelledSlider(
                "Inset",
                value: Binding(
                    get: { model.style.insetFraction },
                    set: { v in
                        var next = model.style
                        next.insetFraction = v
                        model.apply(next)
                    }),
                range: BackdropStyle.insetFractionRange,
                identifier: BackdropPanelIdentifier.inset)
            sectionTitle("Alignment")
            alignmentGrid
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Ratio")
                Picker("", selection: Binding(
                    get: { model.style.ratio },
                    set: { r in
                        var next = model.style
                        next.ratio = r
                        model.apply(next)
                    })
                ) {
                    ForEach(BackdropRatio.allCases, id: \.self) { r in
                        Text(r == .auto ? "Auto" : r.rawValue).tag(r)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(BackdropPanelIdentifier.ratio)
            }
            Toggle("Auto-balance", isOn: Binding(
                get: { model.style.autoBalance },
                set: { model.setAutoBalance($0) }))
                .accessibilityIdentifier(BackdropPanelIdentifier.autoBalance)
        }
        .disabled(model.isNone)
        .opacity(model.isNone ? 0.4 : 1)
    }

    private var alignmentGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        let anchor = BackdropAlignment.allCases[row * 3 + col]
                        // With auto-balance on the compositor divides the
                        // space evenly and ignores the anchor, so no cell is
                        // the one in force — highlighting one would claim an
                        // effect the picture does not have.
                        let selected = !model.style.autoBalance
                            && model.style.alignment == anchor
                        Button {
                            model.choose(alignment: anchor)
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected
                                    ? Color.accentColor
                                    : Color.white.opacity(0.14))
                                .frame(width: 20, height: 16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            BackdropPanelIdentifier.alignment(anchor))
                    }
                }
            }
        }
    }

    // MARK: pieces

    private func styleFor(gradientId: String) -> BackdropStyle {
        var chip = model.style
        chip.kind = .gradient
        chip.gradientId = gradientId
        return chip.clamped()
    }

    private func swatchButton(
        style: BackdropStyle, isSelected: Bool, help: String,
        identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let image = BackdropSwatch.image(for: style) {
                    Image(nsImage: image).resizable()
                } else {
                    Color.black
                }
            }
            .frame(
                width: BackdropSwatch.size.width,
                height: BackdropSwatch.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7).stroke(
                    isSelected ? Color.accentColor : Color.white.opacity(0.18),
                    lineWidth: isSelected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(help)
    }

    private func labelledSlider(
        _ title: String, value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>, identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = CGFloat($0) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                onEditingChanged: { editing in
                    if editing {
                        model.beginContinuousEdit()
                    } else {
                        model.endContinuousEdit()
                    }
                })
                .controlSize(.small)
                .accessibilityIdentifier(identifier)
        }
    }

    private func sectionTitle(
        _ text: String, trailing: String? = nil
    ) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let trailing {
                Spacer(minLength: 0)
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func shortCornerTitle(_ style: BackdropCornerStyle) -> String {
        switch style {
        case .none: return "□"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }
}

/// Stable identifiers so a gate names the control it drives instead of
/// counting subviews and hoping the order never changes.
enum BackdropPanelIdentifier {
    static let root = "backdrop.panel"
    static let none = "backdrop.panel.none"
    static let padding = "backdrop.panel.padding"
    static let corners = "backdrop.panel.corners"
    static let shadow = "backdrop.panel.shadow"
    static let inset = "backdrop.panel.inset"
    static let ratio = "backdrop.panel.ratio"
    static let autoBalance = "backdrop.panel.autoBalance"

    static func gradient(_ id: String) -> String { "backdrop.panel.gradient.\(id)" }
    static func solid(_ id: String) -> String { "backdrop.panel.solid.\(id)" }
    static func alignment(_ a: BackdropAlignment) -> String {
        "backdrop.panel.alignment.\(a.rawValue)"
    }
}
