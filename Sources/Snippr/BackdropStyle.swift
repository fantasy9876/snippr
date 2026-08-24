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
}

enum BackdropRatio: String, Codable, CaseIterable, Hashable {
    case auto
    case oneOne = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case nineSixteen = "9:16"
    case fiveFour = "5:4"
}

enum BackdropBlurSource: String, Codable, CaseIterable, Hashable {
    case wallpaper, image
}

/// One named fill from `RESEARCH/snippr-backdrop-spec/gradients-v1.json`.
/// `id` is the `gradientId` key Honey WP6 must bind swatches to.
struct BackdropGradientEntry: Equatable, Hashable {
    let id: String
    let name: String
    /// sRGB `#RRGGBB`, at least two.
    let stops: [String]
    let locations: [CGFloat]
    let isLight: Bool
    /// Alpha of the drop shadow at `BackdropStyle.defaultShadowStrength`
    /// (which is 1.0). Honey JSON field `shadowAlphaAtStrength1` — 0.35 on
    /// dark plates, 0.22 on paper/fog so the same black does not read as dirt.
    let shadowAlphaAtStrength1: CGFloat
    let meanLuminance: CGFloat
}

enum BackdropGradientCatalog {
    /// Visual axis, shared by all 12. CoreGraphics y-up unit endpoints
    /// `[0,1]→[1,0]`; GDI+ y-down `[0,0]→[1,1]`. Do not translate the name.
    static let visualAxis = "topLeftToBottomRight"
    static let coreGraphicsUnitStart = CGPoint(x: 0, y: 1)
    static let coreGraphicsUnitEnd = CGPoint(x: 1, y: 0)
    static let gdiPlusUnitStart = CGPoint(x: 0, y: 0)
    static let gdiPlusUnitEnd = CGPoint(x: 1, y: 1)

    static let entries: [BackdropGradientEntry] = [
        .init(id: "ocean", name: "Ocean",
              stops: ["#4F7DF3", "#3B2FB8"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.146),
        .init(id: "sunset", name: "Sunset",
              stops: ["#FF8A4C", "#E8447F"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.314),
        .init(id: "mint", name: "Mint",
              stops: ["#2FD3A5", "#1E9E8F"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.383),
        .init(id: "graphite", name: "Graphite",
              stops: ["#3A3F46", "#1C1F24"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.031),
        .init(id: "lavender", name: "Lavender",
              stops: ["#A78BFA", "#6D48D7"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.232),
        .init(id: "rose", name: "Rose",
              stops: ["#FB7AA8", "#C0348E"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.264),
        .init(id: "ember", name: "Ember",
              stops: ["#FBBF5C", "#D64545"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.388),
        .init(id: "meadow", name: "Meadow",
              stops: ["#A8E063", "#3F9142"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.421),
        .init(id: "lagoon", name: "Lagoon",
              stops: ["#5AD1E8", "#2A7FB8"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.364),
        .init(id: "midnight", name: "Midnight",
              stops: ["#2B3A67", "#0E1330"], locations: [0, 1],
              isLight: false, shadowAlphaAtStrength1: 0.35, meanLuminance: 0.026),
        .init(id: "paper", name: "Paper",
              stops: ["#F4F1EA", "#D9D2C4"], locations: [0, 1],
              isLight: true, shadowAlphaAtStrength1: 0.22, meanLuminance: 0.765),
        .init(id: "fog", name: "Fog",
              stops: ["#DCE3EC", "#A9B6C7"], locations: [0, 1],
              isLight: true, shadowAlphaAtStrength1: 0.22, meanLuminance: 0.611),
    ]

    static let ids: [String] = entries.map(\.id)

    static func entry(id: String) -> BackdropGradientEntry? {
        entries.first { $0.id == id }
    }

    /// The four v0 ids whose production fill is the 4-stop + wash + grain
    /// table in `SliceBBackdrop`, NOT the 2-stop JSON. JSON 2-stop colours
    /// stay as swatch chips and as the migrate key; shipping Ocean is the
    /// richer ramp. WP2 must not replace those four ramps with 2-stop.
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

    /// Geometry the compositor applies today. Alignment / ratio / inset /
    /// auto-balance are stored and ignored until WP3.
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
        if s.kind != .image { s.imagePath = nil }
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
