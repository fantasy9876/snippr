import AppKit

// MARK: - Translation service

/// Free Google translate endpoint (gtx). Only called when the user
/// explicitly presses Translate — nothing is sent automatically.
enum TranslateService {
    struct Language {
        let code: String
        let label: String
    }

    static let languages: [Language] = [
        .init(code: "vi", label: "Tiếng Việt"),
        .init(code: "en", label: "English"),
        .init(code: "ja", label: "日本語"),
        .init(code: "ko", label: "한국어"),
        .init(code: "zh-CN", label: "中文 (简体)"),
        .init(code: "fr", label: "Français"),
        .init(code: "de", label: "Deutsch"),
        .init(code: "es", label: "Español"),
        .init(code: "th", label: "ไทย"),
    ]

    static func translate(_ text: String, to lang: String) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: lang),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = json.first as? [Any] else {
            throw URLError(.cannotParseResponse)
        }
        let parts = sentences.compactMap { ($0 as? [Any])?.first as? String }
        guard !parts.isEmpty else { throw URLError(.cannotParseResponse) }
        return parts.joined()
    }
}

// MARK: - OCR result window (text + translate, Lark-style)

@MainActor
final class TextResultWindow {
    private static var current: TextResultWindow?

    private let window: NSWindow
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()

    static func show(text: String, autoTranslate: Bool = false) {
        let w = TextResultWindow(text: text)
        current = w
        w.window.orderFrontRegardless()
        w.window.makeKeyAndOrderFront(nil)
        AppActivation.activateNow()
        if autoTranslate {
            w.translateTapped()
        }
    }

    private init(text: String) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Recognized Text"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = true
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.autoresizingMask = [.width]
        textView.textContainerInset = CGSize(width: 6, height: 8)
        scroll.documentView = textView

        for lang in TranslateService.languages {
            languagePopup.addItem(withTitle: lang.label)
        }
        if let idx = TranslateService.languages.firstIndex(where: { $0.code == Settings.shared.translateTarget }) {
            languagePopup.selectItem(at: idx)
        }

        let translateBtn = NSButton(title: "Translate", target: self, action: #selector(translateTapped))
        translateBtn.bezelStyle = .rounded
        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "c"
        copyBtn.keyEquivalentModifierMask = .command

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [languagePopup, translateBtn, statusLabel, NSView(), copyBtn])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 26),
        ])
        window.contentView = content
    }

    @objc private func translateTapped() {
        let idx = languagePopup.indexOfSelectedItem
        guard idx >= 0, idx < TranslateService.languages.count else { return }
        let lang = TranslateService.languages[idx]
        Settings.shared.translateTarget = lang.code
        let source = textView.string
        guard !source.isEmpty else { return }
        statusLabel.stringValue = "Đang dịch…"
        Task { @MainActor in
            do {
                let translated = try await TranslateService.translate(source, to: lang.code)
                textView.string = translated
                statusLabel.stringValue = "Đã dịch sang \(lang.label)"
            } catch {
                statusLabel.stringValue = "Dịch thất bại — kiểm tra mạng"
            }
        }
    }

    @objc private func copyTapped() {
        SaveService.copyText(textView.string)
        ToastHUD.show("Text copied")
    }
}
