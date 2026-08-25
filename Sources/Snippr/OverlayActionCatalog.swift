/// One action catalog for both the area-review and scrolling-result surfaces.
/// Button tags are the descriptor indices, so both hosts must build and route
/// from this exact array rather than maintaining parallel hard-coded lists.
struct OverlayActionItem: Equatable {
    let symbol: String
    let tooltip: String
    let intent: CaptureIntent
    /// The plain key that reaches this intent on the area-review overlay, or
    /// nil when the action has no single-key route.
    ///
    /// Routing and the hint read the SAME field. The tool map already learned
    /// this the hard way: a hint that names a key the host does not route is a
    /// promise the app breaks the first time a user believes it — and a key
    /// that routes without appearing in any hint is a feature nobody finds.
    let shortcut: String?
}

enum OverlayActionCatalog {
    /// Chosen against the tool map in
    /// `OverlayAnnotationTool.tool(forShortcutKey:)` — v/p/a/r/t/l/o/h/n/b/s/m
    /// — plus D (backdrop), Tab (colour pick), the digits (spotlight dim) and
    /// Return/Esc. E, X, G and F are the letters left. C is deliberately
    /// avoided: it is Crop in the editor, and one letter meaning two things
    /// across the two surfaces is worse than a letter that means nothing yet.
    static let items: [OverlayActionItem] = [
        OverlayActionItem(
            symbol: "doc.on.doc", tooltip: "Copy (Enter, ⌘C)", intent: .copy,
            shortcut: nil),
        OverlayActionItem(
            symbol: "square.and.arrow.down", tooltip: "Save… (⌘S)",
            intent: .save, shortcut: nil),
        OverlayActionItem(
            symbol: "pin", tooltip: "Pin to screen (F)", intent: .pin,
            shortcut: "f"),
        OverlayActionItem(
            symbol: "text.viewfinder", tooltip: "Copy text (OCR) (X)",
            intent: .ocr, shortcut: "x"),
        OverlayActionItem(
            symbol: "globe", tooltip: "OCR + Translate (G)", intent: .translate,
            shortcut: "g"),
        OverlayActionItem(
            symbol: "macwindow", tooltip: "Open in editor window (E)",
            intent: .openEditor, shortcut: "e"),
    ]

    /// Save is ⌘S, not a bare letter: it opens a sheet and writes a file while
    /// every bare letter here is instant. Kept out of `shortcut` so the
    /// plain-key lookup can never reach it.
    static let saveKey = "s"

    static func intent(forShortcutKey key: String) -> CaptureIntent? {
        let lowered = key.lowercased()
        return items.first { $0.shortcut == lowered }?.intent
    }
}
