import AppKit
import Foundation

// MARK: - BackdropStyle (WP1 freeze, 2026-08-24)
//
// Contract Honey WP6 / Grok WP2–WP3 / Windows WP8 code against. Field names
// and raw values are frozen. Adding a field is a new WP; renaming is not.
//
// v0 five-case `BackdropPreset` stays as the migration key and the overlay
// annotation payload. `BackdropStyle.from(preset:)` is the only map.

enum BackdropKind: String, Codable, CaseIterable, Hashable {
    case none, gradient, solid, image, wallpaper, blurred
}

enum BackdropAlignment: String, Codable, CaseIterable, Hashable {
    case tl, tc, tr, cl, cc, cr, bl, bc, br

    /// −1 left, 0 centre, +1 right.
    var horizontal: Int {
        switch self {
        case .tl, .cl, .bl: return -1
        case .tc, .cc, .bc: return 0
        case .tr, .cr, .br: return 1
        }
    }

    /// −1 bottom, 0 centre, +1 top, in CoreGraphics / AppKit y-up.
    var vertical: Int {
        switch self {
        case .bl, .bc, .br: return -1
        case .cl, .cc, .cr: return 0
        case .tl, .tc, .tr: return 1
        }
    }
}

enum BackdropRatio: String, Codable, CaseIterable, Hashable {
    case auto
    case oneOne = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case nineSixteen = "9:16"
    case fiveFour = "5:4"

    /// Width / height, or nil for `.auto`.
    var widthOverHeight: CGFloat? {
        switch self {
        case .auto: return nil
        case .oneOne: return 1
        case .fourThree: return 4 / 3
        case .sixteenNine: return 16 / 9
        case .nineSixteen: return 9 / 16
        case .fiveFour: return 5 / 4
        }
    }
}

enum BackdropBlurSource: String, Codable, CaseIterable, Hashable {
    case wallpaper, image
}

/// Radial wash from Honey JSON v2. Additive on the catalog entry — not a
/// `BackdropStyle` field. Geometry matches production: centre (0.22, 0.78)
/// in CoreGraphics y-up units, radius 0.85 × diagonal.
struct BackdropWash: Equatable, Hashable {
    let color: String
    let alpha: CGFloat
    let centerUnit: CGPoint
    let radiusDiagonalFactor: CGFloat

    static func family(color: String, alpha: CGFloat) -> BackdropWash {
        BackdropWash(
            color: color, alpha: alpha,
            centerUnit: CGPoint(x: 0.22, y: 0.78),
            radiusDiagonalFactor: 0.85)
    }
}

/// One named fill from `RESEARCH/snippr-backdrop-spec/gradients-v1.json` v2.
/// `id` is the `gradientId` key Honey WP6 must bind swatches to.
struct BackdropGradientEntry: Equatable, Hashable {
    let id: String
    let name: String
    /// sRGB `#RRGGBB`, four stops in JSON v2 (graphite locations differ).
    let stops: [String]
    let locations: [CGFloat]
    let isLight: Bool
    /// Alpha of the drop shadow at `BackdropStyle.defaultShadowStrength`
    /// (which is 1.0). Honey JSON field `shadowAlphaAtStrength1` — 0.35 on
    /// dark plates, 0.22 on paper/fog so the same black does not read as dirt.
    let shadowAlphaAtStrength1: CGFloat
    let meanLuminance: CGFloat
    let wash: BackdropWash
}

enum BackdropGradientCatalog {
    /// Visual axis, shared by all 12. CoreGraphics y-up unit endpoints
    /// `[0,1]→[1,0]`; GDI+ y-down `[0,0]→[1,1]`. Do not translate the name.
    static let visualAxis = "topLeftToBottomRight"
    static let coreGraphicsUnitStart = CGPoint(x: 0, y: 1)
    static let coreGraphicsUnitEnd = CGPoint(x: 1, y: 0)
    static let gdiPlusUnitStart = CGPoint(x: 0, y: 0)
    static let gdiPlusUnitEnd = CGPoint(x: 1, y: 1)

    /// Shared 4-stop locations. Graphite is the exception (0.32 / 0.68).
    static let familyLocations: [CGFloat] = [0, 0.28, 0.62, 1]
    static let graphiteLocations: [CGFloat] = [0, 0.32, 0.68, 1]

    static let entries: [BackdropGradientEntry] = [
        entry("ocean", "Ocean",
              ["#8BB4FF", "#4A7CF0", "#2E3DB8", "#1A1868"],
              luma: 0.192, wash: "#FFFFFF", washAlpha: 0.20),
        entry("sunset", "Sunset",
              ["#FFD08A", "#FF7E4A", "#E63D78", "#7A2288"],
              luma: 0.334, wash: "#FFE8C0", washAlpha: 0.18),
        entry("mint", "Mint",
              ["#9AF5D4", "#3DDCB0", "#1A9A8A", "#0A4550"],
              luma: 0.406, wash: "#E8FFF6", washAlpha: 0.16),
        entry("graphite", "Graphite",
              ["#5A6270", "#343A46", "#1C2028", "#0B0D11"],
              locations: graphiteLocations,
              luma: 0.045, wash: "#8B9BB8", washAlpha: 0.14),
        entry("lavender", "Lavender",
              ["#C6B5FC", "#A78BFA", "#6D48D7", "#3C2876"],
              luma: 0.256, wash: "#F5F0FF", washAlpha: 0.18),
        entry("rose", "Rose",
              ["#FCAAC7", "#FB7AA8", "#C0348E", "#6A1D4E"],
              luma: 0.277, wash: "#FFEEF6", washAlpha: 0.18),
        entry("ember", "Ember",
              ["#FCD697", "#FBBF5C", "#D64545", "#762626"],
              luma: 0.385, wash: "#FFF0D6", washAlpha: 0.18),
        entry("meadow", "Meadow",
              ["#C7EB9B", "#A8E063", "#3F9142", "#235024"],
              luma: 0.411, wash: "#F0FFE6", washAlpha: 0.16),
        entry("lagoon", "Lagoon",
              ["#95E1F0", "#5AD1E8", "#2A7FB8", "#174665"],
              luma: 0.362, wash: "#EBFCFF", washAlpha: 0.18),
        entry("midnight", "Midnight",
              ["#6E7CAE", "#3F5290", "#2B3A67", "#0E1330"],
              luma: 0.088, wash: "#C8D6FF", washAlpha: 0.14),
        entry("paper", "Paper",
              ["#FAF9F5", "#F4F1EA", "#D9D2C4", "#BFB9AC"],
              isLight: true, shadow: 0.22,
              luma: 0.741, wash: "#FFFFFF", washAlpha: 0.10),
        entry("fog", "Fog",
              ["#E9EEF4", "#DCE3EC", "#A9B6C7", "#919DAB"],
              isLight: true, shadow: 0.22,
              luma: 0.601, wash: "#FFFFFF", washAlpha: 0.10),
    ]

    private static func entry(
        _ id: String, _ name: String, _ stops: [String],
        locations: [CGFloat] = [0, 0.28, 0.62, 1],
        isLight: Bool = false, shadow: CGFloat = 0.35,
        luma: CGFloat, wash: String, washAlpha: CGFloat
    ) -> BackdropGradientEntry {
        BackdropGradientEntry(
            id: id, name: name, stops: stops, locations: locations,
            isLight: isLight, shadowAlphaAtStrength1: shadow,
            meanLuminance: luma,
            wash: .family(color: wash, alpha: washAlpha))
    }

    static let ids: [String] = entries.map(\.id)

    static func entry(id: String) -> BackdropGradientEntry? {
        entries.first { $0.id == id }
    }

    /// The four v0 ids whose production fill is the 4-stop + wash + grain
    /// table in `SliceBBackdrop`, not `entry.stops` / `entry.wash`. Catalog
    /// bytes now match JSON v2 / production (so swatches and Windows agree),
    /// but the renderer still bypasses the catalog for these four — a later
    /// catalog edit cannot change a v1.2.7 Ocean export.
    static let v0ProductionIds: Set<String> = [
        "ocean", "sunset", "mint", "graphite",
    ]

    static func shadowAlphaAtStrength1(for style: BackdropStyle) -> CGFloat {
        if style.kind == .gradient, let id = style.gradientId,
           let entry = entry(id: id) {
            return entry.shadowAlphaAtStrength1
        }
        if style.kind == .solid, let hex = style.solidColor,
           let luma = srgbLuminance(hex: hex), luma > 0.55 {
            return 0.22
        }
        if style.kind == .none { return 0 }
        return 0.35
    }

    static func srgbLuminance(hex: String) -> CGFloat? {
        guard let c = nsColor(hex: hex) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func nsColor(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let hasAlpha = s.count == 8
        let r, g, b, a: CGFloat
        if hasAlpha {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Plain-colour chips for the Option A sidebar. Not user-named presets.
enum BackdropSolidCatalog {
    static let swatches: [(id: String, hex: String)] = [
        ("white", "#FFFFFF"),
        ("ink", "#111111"),
        ("slate", "#1E293B"),
        ("orange", "#F97316"),
        ("red", "#EF4444"),
        ("green", "#22C55E"),
        ("blue", "#3B82F6"),
        ("violet", "#A855F7"),
    ]
}

/// Document-level Backdrop. Preview, export, overlay, presets and Windows
/// JSON all serialise this type.
struct BackdropStyle: Equatable, Hashable, Codable {
    var kind: BackdropKind
    /// Honey catalog id (`ocean`…`fog`). Nil when `kind != .gradient`.
    var gradientId: String?
    /// sRGB `#RRGGBB` or `#RRGGBBAA`. Nil when `kind != .solid`.
    var solidColor: String?
    var imagePath: String?
    var blurSource: BackdropBlurSource?
    /// Gaussian radius in document points. WP2. Default 28.
    var blurRadiusPt: CGFloat

    /// 0.02…0.15. Default 0.06 — the v0 fraction.
    var paddingFraction: CGFloat
    /// Crop the source inward on all four edges, 0…0.15. Default 0. WP3.
    var insetFraction: CGFloat
    /// Named style that scales with the short edge (1.2.12). NOT absolute
    /// 0–32 pt — that was the 4K-looks-square bug. Honey WP6: 4-tick Corners
    /// control mapped onto these four cases. Default `.medium`.
    var cornerStyle: BackdropCornerStyle
    /// 0…1. Default **1.0** so v0 alpha stays 0.35 (and offset −8 / blur 24).
    /// Plan's "0.7 = current" is superseded: 0.7 × 0.35 would regress Ocean.
    /// Effective alpha = `shadowStrength * catalog.shadowAlphaAtStrength1`.
    var shadowStrength: CGFloat
    var alignment: BackdropAlignment
    var ratio: BackdropRatio
    var autoBalance: Bool

    static let paddingFractionRange: ClosedRange<CGFloat> = 0.02...0.15
    static let insetFractionRange: ClosedRange<CGFloat> = 0...0.15
    static let shadowStrengthRange: ClosedRange<CGFloat> = 0...1
    static let blurRadiusRange: ClosedRange<CGFloat> = 0...80
    static let defaultPaddingFraction: CGFloat = 0.06
    static let defaultShadowStrength: CGFloat = 1.0
    static let defaultBlurRadiusPt: CGFloat = 28
    static let defaultInsetFraction: CGFloat = 0

    static let none = BackdropStyle(
        kind: .none, gradientId: nil, solidColor: nil, imagePath: nil,
        blurSource: nil, blurRadiusPt: defaultBlurRadiusPt,
        paddingFraction: defaultPaddingFraction,
        insetFraction: defaultInsetFraction,
        cornerStyle: SliceBBackdrop.defaultCornerStyle,
        shadowStrength: defaultShadowStrength,
        alignment: .cc, ratio: .auto, autoBalance: true)

    static func gradient(_ id: String) -> BackdropStyle {
        var s = none
        s.kind = .gradient
        s.gradientId = id
        return s.clamped()
    }

    static func solid(_ hex: String) -> BackdropStyle {
        var s = none
        s.kind = .solid
        s.solidColor = hex
        return s.clamped()
    }

    static func image(_ path: String) -> BackdropStyle {
        var s = none
        s.kind = .image
        s.imagePath = path
        return s.clamped()
    }

    static func wallpaper() -> BackdropStyle {
        var s = none
        s.kind = .wallpaper
        return s.clamped()
    }

    static func blurred(
        source: BackdropBlurSource, imagePath: String? = nil
    ) -> BackdropStyle {
        var s = none
        s.kind = .blurred
        s.blurSource = source
        s.imagePath = imagePath
        return s.clamped()
    }

    /// Map the v0 five-case enum. Corner comes from Settings at the call
    /// site when the user is choosing a preset; tests pass the default.
    static func from(
        preset: BackdropPreset,
        cornerStyle: BackdropCornerStyle = SliceBBackdrop.defaultCornerStyle
    ) -> BackdropStyle {
        switch preset {
        case .none: return none
        case .ocean, .sunset, .mint, .graphite:
            var s = gradient(preset.rawValue)
            s.cornerStyle = cornerStyle
            return s
        }
    }

    /// The v0 five-case view. Non-v0 fills (lavender, solid, image, …) return
    /// nil — do not pretend they are Ocean.
    var legacyPreset: BackdropPreset? {
        switch kind {
        case .none: return .none
        case .gradient:
            guard let id = gradientId else { return nil }
            return BackdropPreset(rawValue: id)
        default: return nil
        }
    }

    var isCollapsed: Bool { kind == .none }

    /// True when WP3 geometry is a no-op: the layout is the v0 symmetric
    /// pad. Honey's panel hides the controls until this is false.
    var usesV0SymmetricGeometry: Bool {
        paddingFraction == Self.defaultPaddingFraction
            && insetFraction == 0
            && alignment == .cc
            && ratio == .auto
            && autoBalance == true
            && shadowStrength == Self.defaultShadowStrength
    }

    struct ShadowMetrics: Equatable {
        var offsetPt: CGFloat
        var blurPt: CGFloat
        var alpha: CGFloat
    }

    func shadowMetrics() -> ShadowMetrics {
        let t = max(0, min(1, shadowStrength))
        let catalog = BackdropGradientCatalog.shadowAlphaAtStrength1(for: self)
        return ShadowMetrics(
            offsetPt: SliceBBackdrop.shadowOffsetPt * t,
            blurPt: SliceBBackdrop.shadowBlurPt * t,
            alpha: catalog * t)
    }

    func clamped() -> BackdropStyle {
        var s = self
        s.paddingFraction = Self.clamp(
            paddingFraction, Self.paddingFractionRange)
        s.insetFraction = Self.clamp(insetFraction, Self.insetFractionRange)
        s.shadowStrength = Self.clamp(
            shadowStrength, Self.shadowStrengthRange)
        s.blurRadiusPt = Self.clamp(blurRadiusPt, Self.blurRadiusRange)
        if s.kind != .gradient { s.gradientId = nil }
        if s.kind != .solid { s.solidColor = nil }
        let keepImagePath = s.kind == .image
            || (s.kind == .blurred && s.blurSource == .image)
        if !keepImagePath { s.imagePath = nil }
        if s.kind != .blurred {
            s.blurSource = nil
        }
        if s.kind == .gradient, let id = s.gradientId,
           BackdropGradientCatalog.entry(id: id) == nil {
            s.gradientId = "ocean"
        }
        return s
    }

    private static func clamp(
        _ value: CGFloat, _ range: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

extension BackdropCornerStyle: Codable {}
