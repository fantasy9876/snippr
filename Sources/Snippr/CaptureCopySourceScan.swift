import Foundation

/// Reads capture-flow sources and flags user-facing string literals that
/// did not go through `CaptureCopy`. Closes the "human grep another leftover"
/// loop (Honey G2) so the Win port inherits the same net.
enum CaptureCopySourceScan {
    static let captureFlowFiles = [
        "AppDelegate.swift",
        "ScrollingCapture.swift",
        "ScrollResultPanel.swift",
        "OverlaySession.swift",
        "SelectionOverlay.swift",
    ]

    /// Out-of-slice or non-result toasts. Reason is part of the gate so a
    /// silent allowlist cannot grow without a sentence.
    static let allowlist: [(needle: String, reason: String)] = [
        ("Snippr is running —", "launch splash, not a capture-result toast"),
        ("URL scheme is disabled", "Advanced settings, not capture"),
        ("No image in clipboard", "Load From Clipboard, not a capture path"),
        ("No text found", "OCR — out of i18n slice"),
        ("Text copied", "OCR overlay — out of i18n slice"),
        ("No pixel", "eyedropper / Slice A measure, not capture-result"),
    ]

    static func sourceDirectory(fromFile file: String = #file) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent()
    }

    static func hits(in sourceDir: URL) -> [String] {
        var found: [String] = []
        for name in captureFlowFiles {
            let url = sourceDir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                found.append("\(name):unreadable")
                continue
            }
            found.append(contentsOf: scan(file: name, source: text))
        }
        return found
    }

    static func scan(file: String, source: String) -> [String] {
        let stripped = stripComments(source)
        var hits: [String] = []
        let markers = ["ToastHUD.show(", "updateProgress(", ".stringValue ="]
        var searchFrom = stripped.startIndex
        while searchFrom < stripped.endIndex {
            var best: (idx: String.Index, marker: String)? = nil
            for marker in markers {
                if let r = stripped.range(of: marker, range: searchFrom..<stripped.endIndex) {
                    if best == nil || r.lowerBound < best!.idx {
                        best = (r.lowerBound, marker)
                    }
                }
            }
            guard let hit = best else { break }
            let afterMarker = stripped.index(hit.idx, offsetBy: hit.marker.count)
            let snippet: String
            if hit.marker.hasSuffix("(") {
                snippet = argumentSnippet(stripped, from: afterMarker)
            } else {
                snippet = rhsSnippet(stripped, from: afterMarker)
            }
            searchFrom = stripped.index(afterMarker, offsetBy: min(1, stripped.distance(from: afterMarker, to: stripped.endIndex)))
            if callGoesThroughCaptureCopy(snippet) { continue }
            for lit in stringLiterals(in: snippet) {
                if isPunctuationOnly(lit) { continue }
                if isSymbolName(lit) { continue }
                if allowlist.contains(where: { lit.contains($0.needle) }) { continue }
                let line = lineNumber(of: hit.idx, in: stripped)
                hits.append("\(file):\(line):\(lit)")
            }
        }
        return hits
    }

    private static func stripComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var inStr = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inStr {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inStr = false }
                i += 1
                continue
            }
            if c == "\"" {
                inStr = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" {
                    i += 1
                }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                i = min(i + 2, chars.count)
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func argumentSnippet(_ text: String, from start: String.Index) -> String {
        var depth = 1
        var i = start
        var inStr = false
        var escaped = false
        while i < text.endIndex {
            let c = text[i]
            if inStr {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inStr = false }
            } else {
                if c == "\"" { inStr = true }
                else if c == "(" { depth += 1 }
                else if c == ")" {
                    depth -= 1
                    if depth == 0 { return String(text[start..<i]) }
                }
            }
            i = text.index(after: i)
        }
        return String(text[start...])
    }

    private static func rhsSnippet(_ text: String, from start: String.Index) -> String {
        if let end = text[start...].firstIndex(where: { $0 == "\n" || $0 == ";" }) {
            return String(text[start..<end])
        }
        return String(text[start...])
    }

    private static func callGoesThroughCaptureCopy(_ snippet: String) -> Bool {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("CaptureCopy.") { return true }
        if trimmed.hasPrefix("$") { return true }
        // Interpolation whose pieces are CaptureCopy / session fields.
        if trimmed.hasPrefix("\"\\(") && trimmed.contains("CaptureCopy.") { return true }
        if trimmed.contains("CaptureCopy.") && !trimmed.contains("\"") { return true }
        if trimmed.contains("Self.bidirectionalScrollHint") { return true }
        return false
    }

    private static func stringLiterals(in snippet: String) -> [String] {
        var lits: [String] = []
        var i = snippet.startIndex
        while i < snippet.endIndex {
            if snippet[i] == "\"" {
                var j = snippet.index(after: i)
                var escaped = false
                var buf = ""
                while j < snippet.endIndex {
                    let c = snippet[j]
                    if escaped { buf.append(c); escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { break }
                    else { buf.append(c) }
                    j = snippet.index(after: j)
                }
                lits.append(buf)
                i = j < snippet.endIndex ? snippet.index(after: j) : j
                continue
            }
            i = snippet.index(after: i)
        }
        return lits
    }

    /// SF Symbol token in `symbol:` — not user-facing copy.
    private static func isSymbolName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(where: { $0.isWhitespace }) else { return false }
        return t.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "."
        }
    }

    private static func isPunctuationOnly(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) == false
                && CharacterSet.decimalDigits.contains($0) == false
        }
    }

    private static func lineNumber(of idx: String.Index, in text: String) -> Int {
        text[text.startIndex..<idx].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
