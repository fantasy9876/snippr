/// One action catalog for both the area-review and scrolling-result surfaces.
/// Button tags are the descriptor indices, so both hosts must build and route
/// from this exact array rather than maintaining parallel hard-coded lists.
struct OverlayActionItem: Equatable {
    let symbol: String
    let tooltip: String
    let intent: CaptureIntent
}

enum OverlayActionCatalog {
    static let items: [OverlayActionItem] = [
        OverlayActionItem(
            symbol: "doc.on.doc", tooltip: "Copy (Enter, ⌘C)", intent: .copy),
        OverlayActionItem(
            symbol: "square.and.arrow.down", tooltip: "Save…", intent: .save),
        OverlayActionItem(
            symbol: "pin", tooltip: "Pin to screen", intent: .pin),
        OverlayActionItem(
            symbol: "text.viewfinder", tooltip: "Copy text (OCR)", intent: .ocr),
        OverlayActionItem(
            symbol: "globe", tooltip: "OCR + Translate", intent: .translate),
        OverlayActionItem(
            symbol: "macwindow", tooltip: "Open in editor window",
            intent: .openEditor),
    ]
}
