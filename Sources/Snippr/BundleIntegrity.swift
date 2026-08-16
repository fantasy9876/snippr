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

    /// What the app process may do at launch, decided BEFORE any status item,
    /// hotkey, launch-status file or TCC prompt exists.
    enum LaunchDisposition: Equatable {
        /// Canonical copy: run normally, name any duplicates.
        case proceed(warnDuplicates: [URL])
        /// Wrong copy: block. Nothing may be initialised; the process ends
        /// after the user has been pointed at the installed app.
        case blockWrongCopy(running: URL, canonicalExists: Bool)
    }

    /// Pure mapping. `allowNonCanonical` is the DEBUG override (dev tools /
    /// SNIPPR_ALLOW_NONCANONICAL=1); production never continues from a wrong
    /// copy — that is exactly the path that ends in "grant it again".
    static func launchDisposition(
        for verdict: Verdict?, allowNonCanonical: Bool = false
    ) -> LaunchDisposition {
        switch verdict {
        case nil:
            return .proceed(warnDuplicates: [])
        case let .canonical(duplicates)?:
            return .proceed(warnDuplicates: duplicates)
        case let .runningNonCanonical(running, canonicalExists, duplicates)?:
            if allowNonCanonical {
                return .proceed(warnDuplicates: duplicates)
            }
            return .blockWrongCopy(running: running, canonicalExists: canonicalExists)
        }
    }

    static var debugOverrideRequested: Bool {
        ProcessInfo.processInfo.environment["SNIPPR_ALLOW_NONCANONICAL"] == "1"
    }

    /// Wrong copy: modal that names the path; "Mở bản trong /Applications"
    /// (when it exists) opens the installed app. Returns only after the user
    /// dismissed it — the caller terminates immediately. Never deletes,
    /// never touches TCC.
    @MainActor
    static func presentWrongCopyAlert(running: URL, canonicalExists: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Snippr đang chạy từ vị trí không chuẩn"
        alert.informativeText = "Bản này chạy từ:\n\(running.path)\n\nQuyền Screen Recording/Accessibility được cấp cho /Applications/Snippr.app; chạy bản khác sẽ bị hỏi quyền lại. "
            + (canonicalExists
                ? "Snippr sẽ mở bản đã cài trong /Applications; hãy xóa bản này."
                : "Hãy kéo Snippr vào /Applications rồi mở từ đó.")
        if canonicalExists { alert.addButton(withTitle: "Mở bản trong /Applications") }
        alert.addButton(withTitle: "Thoát")
        let response = alert.runModal()
        if canonicalExists, response == .alertFirstButtonReturn {
            handoffToCanonicalAndExit()
        }
    }

    /// The detached helper that performs the handoff. Ordering is the whole
    /// point: the canonical app's single-instance guard (main.swift) exits if
    /// ANY process with our bundle id is alive, so the wrong copy must be
    /// gone before `open` runs — otherwise the canonical quits and no Snippr
    /// is left. The helper polls our pid (bounded), then `open -n` (a fresh
    /// instance — never "activate whatever copy is running").
    static func handoffCommand(
        canonical: URL, waitForPID: pid_t, timeoutSeconds: Int = 10,
        openTool: String = "/usr/bin/open"
    ) -> [String] {
        let quotedPath = "'" + canonical.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quotedTool = "'" + openTool.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "i=0; while /bin/kill -0 \(waitForPID) 2>/dev/null && [ $i -lt \(timeoutSeconds * 10) ]; do /bin/sleep 0.1; i=$((i+1)); done; exec \(quotedTool) -n \(quotedPath)"
        return ["/bin/sh", "-c", script]
    }

    /// Spawns the detached helper and ends THIS process immediately (before
    /// any status item / hotkey / TCC prompt could exist — the caller only
    /// reaches here from the launch disposition switch).
    static func handoffToCanonicalAndExit() -> Never {
        let argv = handoffCommand(
            canonical: canonicalURL,
            waitForPID: ProcessInfo.processInfo.processIdentifier)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: argv[0])
        helper.arguments = Array(argv.dropFirst())
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
        exit(0)
    }

    /// Canonical copy with duplicates: warning naming every path.
    @MainActor
    static func presentDuplicatesWarning(_ duplicates: [URL]) {
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
    }
}
