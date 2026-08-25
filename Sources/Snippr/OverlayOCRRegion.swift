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
    /// Translate mode adds one row for the language chooser. The panel grows
    /// instead of the text box shrinking: the text is the thing being read.
    static let languageRowHeight: CGFloat = 22

    static let copyIdentifier = "overlay.ocr.copy"
    static let closeIdentifier = "overlay.ocr.close"
    static let languageIdentifier = "overlay.ocr.language"
    static let retryIdentifier = "overlay.ocr.retry"

    /// Retry sits on the language row so the footer still has room for the
    /// fail reason. Width matches the Copy button; the popup shrinks to fit.
    static let retryWidth: CGFloat = 72

    static func retryFrame(translating: Bool) -> CGRect {
        let language = languageFrame(translating: translating)
        return CGRect(
            x: language.maxX - retryWidth, y: language.minY,
            width: retryWidth, height: language.height)
    }

    /// Smallest region worth recognizing. Below this a drag is a stray click,
    /// and Vision on a 3pt strip returns noise the user would have to undo.
    static let minimumRegionSide: CGFloat = 8

    /// THE size. `textFrame` is derived from it and `layoutOCRResult` hands it
    /// to `OverlayToolbarLayout.popover`, so a second hard-coded height would
    /// place the panel by one size and draw it at another — and the
    /// "never covers the region" gate would measure the wrong rectangle.
    static func size(translating: Bool) -> CGSize {
        guard translating else { return size }
        return CGSize(
            width: size.width,
            height: size.height + languageRowHeight + sectionGap)
    }

    static func textFrame(translating: Bool) -> CGRect {
        let box = size(translating: translating)
        let languageBand = translating
            ? languageRowHeight + sectionGap : 0
        return CGRect(
            x: contentInset,
            y: contentInset + footerHeight + sectionGap + languageBand,
            width: box.width - contentInset * 2,
            height: box.height - contentInset * 2 - footerHeight - sectionGap
                - languageBand)
    }

    static var textFrame: CGRect { textFrame(translating: false) }

    static func languageFrame(translating: Bool) -> CGRect {
        CGRect(
            x: contentInset,
            y: contentInset + footerHeight + sectionGap,
            width: size(translating: translating).width - contentInset * 2,
            height: languageRowHeight)
    }
}

/// Where the panel's Copy button puts its text.
///
/// Production is the general pasteboard. A gate overrides the sink so it can
/// press the REAL button and read the exact string the handler chose — the
/// panel's own `recognizedText` is a field, and asserting a field cannot tell
/// "Copy took the translation" from "Copy took the recognition instead". The
/// override also keeps a suite run from overwriting the clipboard of whoever
/// happens to be using the machine.
enum OverlayOCRClipboard {
    nonisolated(unsafe) static var sinkForTesting: ((String) -> Void)?

    @MainActor static func put(_ text: String) {
        if let sink = sinkForTesting {
            sink(text)
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// The panel itself. Deliberately not a window: a `.screenSaver`-level overlay
/// would cover a child window, and the panel has to sit ON the shot.
final class OverlayOCRResultView: NSView {
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let copyButton: NSButton
    private let closeButton: NSButton
    private let retryButton: NSButton
    private let languagePopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private(set) var hintButtons: [NSButton] = []
    /// What Copy puts on the clipboard: the recognized text, or the
    /// translation once one has landed. Copying the original after the user
    /// asked for a translation would hand back the thing they did not want.
    private(set) var recognizedText: String = ""
    /// The recognition itself, kept so a language change re-translates the
    /// ORIGINAL rather than a translation of a translation, and so a failed
    /// request can fail open back to it.
    private(set) var sourceText: String = ""
    /// Translate mode shows the language row and auto-translates; plain OCR
    /// mode does neither. The panel is reused across picks, so this is a
    /// property rather than a construction-time choice.
    private(set) var isTranslateMode = false

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    init(
        target: AnyObject, copyAction: Selector, closeAction: Selector,
        languageAction: Selector, retryAction: Selector
    ) {
        copyButton = NSButton(
            title: "Copy", target: target, action: copyAction)
        closeButton = NSButton(
            title: "✕", target: target, action: closeAction)
        retryButton = NSButton(
            title: "Thử lại", target: target, action: retryAction)
        super.init(frame: CGRect(origin: .zero, size: OverlayOCRPanel.size))

        // The overlay's chrome is dark in BOTH system appearances — the same
        // contract the editor window pins (`EditorWindow`: window.appearance =
        // .darkAqua). Without this the panel mixes a hard-coded dark
        // background with dynamic text colours, so in Light mode `.labelColor`
        // resolves to near-black and the recognized text vanishes into the
        // panel: the 1.2.16 "khung tối thui" report.
        appearance = NSAppearance(named: .darkAqua)

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

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        addSubview(scroll)

        copyButton.bezelStyle = .rounded
        copyButton.identifier = NSUserInterfaceItemIdentifier(
            OverlayOCRPanel.copyIdentifier)
        copyButton.toolTip = "Copy recognized text"
        copyButton.setAccessibilityLabel("Copy recognized text")
        addSubview(copyButton)

        closeButton.bezelStyle = .rounded
        closeButton.identifier = NSUserInterfaceItemIdentifier(
            OverlayOCRPanel.closeIdentifier)
        closeButton.toolTip = "Close (Esc)"
        closeButton.setAccessibilityLabel("Close OCR result")
        addSubview(closeButton)

        // The same list and the same stored preference the translate window
        // offers, so the target language a user picks in one place is the
        // language the other one starts from.
        for language in TranslateService.languages {
            languagePopup.addItem(withTitle: language.label)
        }
        if let index = TranslateService.languages.firstIndex(
            where: { $0.code == Settings.shared.translateTarget }) {
            languagePopup.selectItem(at: index)
        }
        languagePopup.target = target
        languagePopup.action = languageAction
        languagePopup.identifier = NSUserInterfaceItemIdentifier(
            OverlayOCRPanel.languageIdentifier)
        languagePopup.controlSize = .small
        languagePopup.font = .systemFont(ofSize: 11)
        languagePopup.toolTip = "Dịch sang…"
        languagePopup.setAccessibilityLabel("Ngôn ngữ dịch")
        languagePopup.isHidden = true
        addSubview(languagePopup)

        retryButton.bezelStyle = .rounded
        retryButton.identifier = NSUserInterfaceItemIdentifier(
            OverlayOCRPanel.retryIdentifier)
        retryButton.controlSize = .small
        retryButton.font = .systemFont(ofSize: 11)
        retryButton.toolTip = "Thử lại bản dịch"
        retryButton.setAccessibilityLabel("Thử lại bản dịch")
        retryButton.isHidden = true
        addSubview(retryButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        layoutContents()
        hintButtons = [copyButton, closeButton, languagePopup, retryButton]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// One place that knows where the pieces sit, so the taller translate
    /// layout cannot drift from the plain one.
    private func layoutContents() {
        let box = OverlayOCRPanel.size(translating: isTranslateMode)
        setFrameSize(box)
        scroll.frame = OverlayOCRPanel.textFrame(translating: isTranslateMode)
        textView.frame = CGRect(origin: .zero, size: scroll.contentSize)
        let language = OverlayOCRPanel.languageFrame(
            translating: isTranslateMode)
        languagePopup.isHidden = !isTranslateMode
        let retryVisible = isTranslateMode && !retryButton.isHidden
        retryButton.isHidden = !retryVisible
        if retryVisible {
            let retry = OverlayOCRPanel.retryFrame(translating: isTranslateMode)
            retryButton.frame = retry
            languagePopup.frame = CGRect(
                x: language.minX, y: language.minY,
                width: retry.minX - language.minX - OverlayOCRPanel.sectionGap,
                height: language.height)
        } else {
            languagePopup.frame = language
            retryButton.frame = OverlayOCRPanel.retryFrame(
                translating: isTranslateMode)
        }
        copyButton.frame = CGRect(
            x: OverlayOCRPanel.contentInset, y: OverlayOCRPanel.contentInset,
            width: 72, height: OverlayOCRPanel.footerHeight)
        closeButton.frame = CGRect(
            x: box.width - OverlayOCRPanel.contentInset - 32,
            y: OverlayOCRPanel.contentInset,
            width: 32, height: OverlayOCRPanel.footerHeight)
        statusLabel.frame = CGRect(
            x: OverlayOCRPanel.contentInset + 80,
            y: OverlayOCRPanel.contentInset + 3,
            width: box.width - OverlayOCRPanel.contentInset * 2 - 80 - 36,
            height: OverlayOCRPanel.footerHeight - 6)
    }

    /// Switches the panel between plain OCR and OCR + Translate. Called before
    /// the panel is placed, because the placement is computed from its size.
    func setTranslateMode(_ on: Bool) {
        guard isTranslateMode != on else { return }
        isTranslateMode = on
        layoutContents()
    }

    var selectedLanguage: TranslateService.Language {
        let index = languagePopup.indexOfSelectedItem
        guard TranslateService.languages.indices.contains(index) else {
            return TranslateService.languages[0]
        }
        return TranslateService.languages[index]
    }

    /// Recognition runs off the main thread, so the panel opens EMPTY and is
    /// filled when the result lands. Showing nothing until Vision finishes
    /// would leave the user staring at the shot wondering if the drag worked.
    func showRecognizing() {
        recognizedText = ""
        sourceText = ""
        textView.string = ""
        statusLabel.stringValue = "Recognizing…"
        copyButton.isEnabled = false
        retryButton.isHidden = true
        layoutContents()
    }

    /// The recognition is shown FIRST, even in translate mode: the user gets
    /// something readable while the network round trip is still out, and if it
    /// never comes back this is what stays on screen.
    func showTranslating(to language: TranslateService.Language) {
        statusLabel.stringValue = "Đang dịch sang \(language.label)…"
        retryButton.isHidden = true
        layoutContents()
    }

    func showTranslated(_ text: String, to language: TranslateService.Language) {
        recognizedText = text
        textView.string = text
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        statusLabel.stringValue = "Đã dịch sang \(language.label)"
        copyButton.isEnabled = !text.isEmpty
        retryButton.isHidden = true
        layoutContents()
    }

    /// Fail OPEN: a dead network leaves the recognized text on screen and
    /// copyable. Blanking the panel would throw away work Vision already did.
    /// `reason` is the classified Failure message — not a generic one-liner
    /// that could have been offline, 429, or HTML in disguise.
    func showTranslateFailed(_ reason: String) {
        recognizedText = sourceText
        textView.string = sourceText
        statusLabel.stringValue = reason
        copyButton.isEnabled = !sourceText.isEmpty
        retryButton.isHidden = !isTranslateMode
        layoutContents()
    }

    func show(result: OCRResult) {
        let text = result.clipboardText
        recognizedText = text
        sourceText = text
        textView.string = text
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        retryButton.isHidden = true
        if text.isEmpty {
            statusLabel.stringValue = "No text found"
            copyButton.isEnabled = false
        } else {
            let lines = text.split(
                separator: "\n", omittingEmptySubsequences: false).count
            statusLabel.stringValue = lines == 1 ? "1 line" : "\(lines) lines"
            copyButton.isEnabled = true
        }
        layoutContents()
    }

    var copyButtonIsEnabledForTesting: Bool { copyButton.isEnabled }
    var statusForTesting: String { statusLabel.stringValue }
    var languageIsShownForTesting: Bool { !languagePopup.isHidden }

    /// The text colour AS RESOLVED in the appearance the panel actually draws
    /// in. Reading `textView.textColor` alone proves nothing: `.labelColor` is
    /// dynamic, and the whole 1.2.16 bug was that it resolved dark against a
    /// dark background in Light mode.
    var resolvedTextColorForTesting: NSColor? {
        var resolved: NSColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = (textView.textColor ?? .labelColor)
                .usingColorSpace(.sRGB)
        }
        return resolved
    }

    /// The panel's own background, for the contrast assertion above.
    static let backgroundColorForTesting = NSColor(white: 0.11, alpha: 1)

    func control(identifier: String) -> NSButton? {
        [copyButton, closeButton, languagePopup, retryButton].first {
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
