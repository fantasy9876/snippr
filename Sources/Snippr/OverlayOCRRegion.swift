import AppKit

// MARK: - Region OCR result panel (1.2.16)
//
// Owner request: pressing OCR picks a REGION, and the recognized text arrives
// in a panel next to it with a Copy button — the capture frame stays on screen
// instead of the session ending. The old behaviour tore the overlay down and
// pushed the text straight to the clipboard, so there was nothing to read and
// nothing to correct.

enum OverlayOCRPanel {
    static let size = CGSize(width: 300, height: 176)
    static let contentInset: CGFloat = 10
    static let footerHeight: CGFloat = 24
    static let sectionGap: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    static let copyIdentifier = "overlay.ocr.copy"
    static let closeIdentifier = "overlay.ocr.close"

    /// Smallest region worth recognizing. Below this a drag is a stray click,
    /// and Vision on a 3pt strip returns noise the user would have to undo.
    static let minimumRegionSide: CGFloat = 8

    static var textFrame: CGRect {
        CGRect(
            x: contentInset,
            y: contentInset + footerHeight + sectionGap,
            width: size.width - contentInset * 2,
            height: size.height - contentInset * 2 - footerHeight - sectionGap)
    }
}

/// The panel itself. Deliberately not a window: a `.screenSaver`-level overlay
/// would cover a child window, and the panel has to sit ON the shot.
final class OverlayOCRResultView: NSView {
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let copyButton: NSButton
    private let closeButton: NSButton
    private let statusLabel = NSTextField(labelWithString: "")

    private(set) var hintButtons: [NSButton] = []
    private(set) var recognizedText: String = ""

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    init(target: AnyObject, copyAction: Selector, closeAction: Selector) {
        copyButton = NSButton(
            title: "Copy", target: target, action: copyAction)
        closeButton = NSButton(
            title: "✕", target: target, action: closeAction)
        super.init(frame: CGRect(origin: .zero, size: OverlayOCRPanel.size))

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.96).cgColor
        layer?.cornerRadius = OverlayOCRPanel.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor

        // Selectable but NOT editable: the user copies it or edits it after
        // pasting. An editable field here would invite corrections that the
        // panel then throws away when it closes.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 0.07, alpha: 1)
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.frame = OverlayOCRPanel.textFrame
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        textView.frame = CGRect(origin: .zero, size: scroll.contentSize)
        addSubview(scroll)

        copyButton.bezelStyle = .rounded
        copyButton.identifier = NSUserInterfaceItemIdentifier(
            OverlayOCRPanel.copyIdentifier)
        copyButton.toolTip = "Copy recognized text"
        copyButton.setAccessibilityLabel("Copy recognized text")
        copyButton.frame = CGRect(
            x: OverlayOCRPanel.contentInset, y: OverlayOCRPanel.contentInset,
            width: 72, height: OverlayOCRPanel.footerHeight)
        addSubview(copyButton)

        closeButton.bezelStyle = .rounded
        closeButton.identifier = NSUserInterfaceItemIdentifier(
            OverlayOCRPanel.closeIdentifier)
        closeButton.toolTip = "Close (Esc)"
        closeButton.setAccessibilityLabel("Close OCR result")
        closeButton.frame = CGRect(
            x: OverlayOCRPanel.size.width - OverlayOCRPanel.contentInset - 32,
            y: OverlayOCRPanel.contentInset,
            width: 32, height: OverlayOCRPanel.footerHeight)
        addSubview(closeButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = CGRect(
            x: OverlayOCRPanel.contentInset + 80,
            y: OverlayOCRPanel.contentInset + 3,
            width: OverlayOCRPanel.size.width - OverlayOCRPanel.contentInset * 2
                - 80 - 36,
            height: OverlayOCRPanel.footerHeight - 6)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        hintButtons = [copyButton, closeButton]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Recognition runs off the main thread, so the panel opens EMPTY and is
    /// filled when the result lands. Showing nothing until Vision finishes
    /// would leave the user staring at the shot wondering if the drag worked.
    func showRecognizing() {
        recognizedText = ""
        textView.string = ""
        statusLabel.stringValue = "Recognizing…"
        copyButton.isEnabled = false
    }

    func show(result: OCRResult) {
        let text = result.clipboardText
        recognizedText = text
        textView.string = text
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        if text.isEmpty {
            statusLabel.stringValue = "No text found"
            copyButton.isEnabled = false
        } else {
            let lines = text.split(
                separator: "\n", omittingEmptySubsequences: false).count
            statusLabel.stringValue = lines == 1 ? "1 line" : "\(lines) lines"
            copyButton.isEnabled = true
        }
    }

    var copyButtonIsEnabledForTesting: Bool { copyButton.isEnabled }
    var statusForTesting: String { statusLabel.stringValue }

    func control(identifier: String) -> NSButton? {
        [copyButton, closeButton].first {
            $0.identifier?.rawValue == identifier
        }
    }

    /// The panel eats clicks that land on it: a click here must not reach the
    /// crop underneath and start a move, a resize or a cancel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }
}
