import AppKit

/// Guards against the "second Snippr" trap: macOS TCC binds Screen Recording /
/// Accessibility grants to the app's designated requirement, so an OLD copy of
/// Snippr with a different signature (an ad-hoc dev build left in
/// ~/Applications, a DMG mounted image, a Downloads folder copy) that shares
/// the bundle identifier can be picked by Spotlight/Launchpad/LaunchServices
/// instead of the installed app — and then the user is told to grant the
/// permission "again" (field report 2026-08-16, Mac Studio: LaunchServices
/// opened ~/Applications/Snippr.app 1.2.2 ad-hoc before /Applications 1.2.3).
///
/// Only `/Applications/Snippr.app` is canonical: the updater and installer
/// write there, and every grant the user made is for the app at that path.
/// This type never deletes anything — it names the duplicates and blocks the
/// paths (updater) where running from the wrong copy would corrupt state.
enum BundleIntegrity {
    static let bundleIdentifier = "com.manhhoang.snippr"
    static let canonicalURL = URL(fileURLWithPath: "/Applications/Snippr.app")

    enum Verdict: Equatable {
        /// Running from the canonical path. `duplicates` lists every OTHER
        /// bundle with our identifier LaunchServices knows about (may be empty).
        case canonical(duplicates: [URL])
        /// Running from somewhere else. `canonicalExists` says whether the
        /// installed app is present at the canonical path.
        case runningNonCanonical(running: URL, canonicalExists: Bool, duplicates: [URL])
    }

    /// Path identity: standardized, symlinks resolved, trailing slash
    /// dropped, case-insensitive (APFS default).
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.lowercased()
    }

    static func isCanonical(_ url: URL, canonical: URL = canonicalURL) -> Bool {
        normalizedPath(url) == normalizedPath(canonical)
    }

    /// Pure decision over paths (provable headlessly).
    static func evaluate(
        running: URL, discovered: [URL], canonical: URL = canonicalURL
    ) -> Verdict {
        let runningKey = normalizedPath(running)
        var seen: Set<String> = []
        var others: [URL] = []
        var canonicalExists = false
        for url in discovered {
            let key = normalizedPath(url)
            if key == normalizedPath(canonical) { canonicalExists = true }
            guard key != runningKey, !seen.contains(key) else { continue }
            seen.insert(key)
            others.append(url)
        }
        if isCanonical(running, canonical: canonical) {
            return .canonical(duplicates: others)
        }
        return .runningNonCanonical(
            running: running, canonicalExists: canonicalExists, duplicates: others)
    }

    /// Every bundle with our identifier that LaunchServices knows about, plus
    /// the running bundle itself. Empty when not running from an .app bundle.
    static func discoveredBundles() -> [URL] {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return [] }
        var urls: [URL] = [Bundle.main.bundleURL]
        if let found = LSCopyApplicationURLsForBundleIdentifier(
            bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL] {
            urls.append(contentsOf: found)
        }
        // A copy LaunchServices has not registered yet can still be opened by
        // the user; the canonical path is always worth a look.
        if FileManager.default.fileExists(atPath: canonicalURL.path) {
            urls.append(canonicalURL)
        }
        return urls
    }

    /// nil when the process is not an .app bundle (selftest / dev binaries).
    static func currentVerdict() -> Verdict? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return evaluate(running: Bundle.main.bundleURL, discovered: discoveredBundles())
    }

    /// Launch-time warning. Non-canonical: a modal that names the path and
    /// offers to open the installed app instead (or continue — dev builds).
    /// Canonical with duplicates: a modal that names the copies to remove.
    /// Never deletes, never touches TCC.
    @MainActor
    static func warnOnLaunchIfNeeded(terminate: (() -> Void)? = nil) {
        guard let verdict = currentVerdict() else { return }
        switch verdict {
        case .canonical(let duplicates):
            guard !duplicates.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Phát hiện bản Snippr trùng"
            alert.informativeText = "Có \(duplicates.count) bản Snippr khác trên máy. Spotlight/Launchpad có thể mở nhầm bản đó và macOS sẽ hỏi lại quyền Screen Recording. Hãy xóa các bản này, chỉ giữ /Applications/Snippr.app:\n\n"
                + duplicates.map(\.path).joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Hiện trong Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(duplicates)
            }
        case .runningNonCanonical(let running, let canonicalExists, _):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Snippr đang chạy từ vị trí không chuẩn"
            alert.informativeText = "Bản này chạy từ:\n\(running.path)\n\nQuyền Screen Recording/Accessibility được cấp cho /Applications/Snippr.app; chạy bản khác sẽ bị hỏi quyền lại. "
                + (canonicalExists
                    ? "Hãy mở bản đã cài trong /Applications và xóa bản này."
                    : "Hãy kéo Snippr vào /Applications rồi mở từ đó.")
            if canonicalExists { alert.addButton(withTitle: "Mở bản trong /Applications") }
            alert.addButton(withTitle: "Vẫn tiếp tục")
            let response = alert.runModal()
            if canonicalExists, response == .alertFirstButtonReturn {
                NSWorkspace.shared.openApplication(
                    at: canonicalURL, configuration: .init()) { _, _ in
                    DispatchQueue.main.async { terminate?() ?? NSApp.terminate(nil) }
                }
            }
        }
    }
}
