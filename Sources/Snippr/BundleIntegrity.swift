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
    /// Well-known drag-install locations probed DIRECTLY (LaunchServices /
    /// Spotlight are index-dependent and may be stale or empty).
    static var knownCopyLocations: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            canonicalURL,
            home.appendingPathComponent("Applications/Snippr.app"),
            home.appendingPathComponent("Downloads/Snippr.app"),
            home.appendingPathComponent("Desktop/Snippr.app"),
        ]
    }

    /// True when `url` is an existing bundle whose Info.plist carries OUR
    /// identifier (a stale LaunchServices row for a deleted or renamed app
    /// must not be reported as a duplicate).
    static func isSnipprBundle(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: url)
        else { return false }
        return bundle.bundleIdentifier == bundleIdentifier
    }

    static func discoveredBundles() -> [URL] {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return [] }
        let registered = (LSCopyApplicationURLsForBundleIdentifier(
            bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        return discoveredBundles(
            running: Bundle.main.bundleURL, registered: registered,
            knownLocations: knownCopyLocations)
    }

    /// Discovery over injectable inputs: the running bundle, whatever
    /// LaunchServices reports (filtered — stale rows for deleted/renamed
    /// apps are dropped) and the well-known locations probed DIRECTLY
    /// (index-independent). De-duplicated by normalized path.
    static func discoveredBundles(
        running: URL, registered: [URL], knownLocations: [URL]
    ) -> [URL] {
        var seen: Set<String> = [normalizedPath(running)]
        var urls: [URL] = [running]
        for url in registered + knownLocations where isSnipprBundle(at: url) {
            let key = normalizedPath(url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            urls.append(url)
        }
        return urls
    }

    /// nil when the process is not an .app bundle (selftest / dev binaries).
    static func currentVerdict() -> Verdict? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return evaluate(running: Bundle.main.bundleURL, discovered: discoveredBundles())
    }

    /// Single-instance arbitration (main.swift), canonical-aware. The stale
    /// wrong copy must never win against the installed app: if a canonical
    /// process starts while a wrong copy runs, the canonical evicts it and
    /// proceeds; a wrong copy never blocks a canonical one.
    enum InstanceArbitration: Equatable {
        /// No other instance — run.
        case proceed
        /// Another instance owns the role — this process exits quietly.
        case exitOtherRunning
        /// This is the canonical app and the others are wrong copies: ask
        /// them to terminate (bounded wait), then run.
        case evictThenProceed(pids: [pid_t])
    }

    static func instanceArbitration(
        selfIsCanonical: Bool, others: [(pid: pid_t, url: URL?)],
        canonical: URL = canonicalURL
    ) -> InstanceArbitration {
        guard !others.isEmpty else { return .proceed }
        guard selfIsCanonical else { return .exitOtherRunning }
        let canonicalOthers = others.filter {
            $0.url.map { isCanonical($0, canonical: canonical) } ?? false
        }
        // Another CANONICAL instance (double launch) keeps the role.
        guard canonicalOthers.isEmpty else { return .exitOtherRunning }
        return .evictThenProceed(pids: others.map(\.pid))
    }

    /// Eviction budget: a wrong copy may be inside its save failsafe (up to
    /// 10 s in AppDelegate), so the graceful request gets MORE than that
    /// before force is even considered; force gets its own verification
    /// window. Anything still alive afterwards means the canonical app must
    /// NOT proceed (two instances would race hotkeys and TCC). Total worst
    /// case = gracefulTimeout + forceTimeout = 15 s.
    static let evictionGracefulTimeout: TimeInterval = 12
    static let evictionForceTimeout: TimeInterval = 3
    static var evictionMaxDuration: TimeInterval { evictionGracefulTimeout + evictionForceTimeout }

    enum EvictionOutcome: Equatable {
        case evicted(forced: [pid_t])
        case stillAlive([pid_t])
    }

    /// Executor with injectable process primitives so the fail-closed order
    /// (request → wait ≥ save failsafe → force → verify → abort if alive) is
    /// provable against real child processes.
    static func evictInstances(
        _ pids: [pid_t],
        gracefulTimeout: TimeInterval = evictionGracefulTimeout,
        forceTimeout: TimeInterval = evictionForceTimeout,
        requestTerminate: (pid_t) -> Void,
        forceTerminate: (pid_t) -> Void,
        isAlive: (pid_t) -> Bool,
        wait: (TimeInterval) -> Void
    ) -> EvictionOutcome {
        func waitUntilGone(_ candidates: [pid_t], budget: TimeInterval) -> [pid_t] {
            let deadline = Date().addingTimeInterval(budget)
            var alive = candidates.filter(isAlive)
            while !alive.isEmpty, Date() < deadline {
                wait(0.1)
                alive = alive.filter(isAlive)
            }
            return alive
        }
        pids.forEach(requestTerminate)
        let survivors = waitUntilGone(pids, budget: gracefulTimeout)
        guard !survivors.isEmpty else { return .evicted(forced: []) }
        survivors.forEach(forceTerminate)
        let immortal = waitUntilGone(survivors, budget: forceTimeout)
        guard immortal.isEmpty else { return .stillAlive(immortal) }
        return .evicted(forced: survivors)
    }

    /// Launch order for AppDelegate, as data so it can be proven headlessly.
    /// The wrong-copy branch touches nothing; the canonical branch writes the
    /// launch status / health breadcrumb and finishes initialisation BEFORE
    /// any duplicates warning may block the main thread (the updater waits
    /// for that breadcrumb and would otherwise roll a healthy app back).
    enum LaunchStep: Equatable {
        case presentWrongCopyAlertAndExit
        case setupStatusItem
        case writeLaunchStatus
        case startHotkeys
        case requestScreenCapture
        case warnDuplicatesDeferred([URL])
    }

    static func launchPlan(
        for disposition: LaunchDisposition, isDevTool: Bool, needsCaptureServices: Bool
    ) -> [LaunchStep] {
        switch disposition {
        case .blockWrongCopy:
            return [.presentWrongCopyAlertAndExit]
        case let .proceed(warnDuplicates):
            var steps: [LaunchStep] = []
            if !isDevTool {
                steps += [.setupStatusItem, .writeLaunchStatus, .startHotkeys]
            }
            if needsCaptureServices { steps.append(.requestScreenCapture) }
            if !isDevTool, !warnDuplicates.isEmpty {
                steps.append(.warnDuplicatesDeferred(warnDuplicates))
            }
            return steps
        }
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
            handoffToCanonicalOrStayBlocked()
        }
    }

    /// The detached helper that performs the handoff. Ordering is the whole
    /// point: the canonical app's single-instance guard (main.swift) exits if
    /// ANY process with our bundle id is alive, so the wrong copy must be
    /// gone before `open` runs — otherwise the canonical quits and no Snippr
    /// is left. The helper polls our pid (bounded); if the pid is STILL alive
    /// after the timeout it exits non-zero WITHOUT opening anything (fail
    /// closed — never launch a second instance next to a live wrong copy);
    /// otherwise `open -n` (a fresh instance — never "activate whatever copy
    /// is running").
    static func handoffCommand(
        canonical: URL, waitForPID: pid_t, timeoutSeconds: Int = 10,
        openTool: String = "/usr/bin/open"
    ) -> [String] {
        let quotedPath = "'" + canonical.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quotedTool = "'" + openTool.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "i=0; while /bin/kill -0 \(waitForPID) 2>/dev/null && [ $i -lt \(timeoutSeconds * 10) ]; do /bin/sleep 0.1; i=$((i+1)); done; "
            + "if /bin/kill -0 \(waitForPID) 2>/dev/null; then exit 75; fi; "
            + "exec \(quotedTool) -n \(quotedPath)"
        return ["/bin/sh", "-c", script]
    }

    /// Spawns the detached helper; returns true only when the helper process
    /// actually started. The caller exits THIS process only on success — a
    /// spawn failure must never end the wrong copy (there would be no Snippr
    /// at all) and must never let it continue into TCC/hotkey setup either.
    @discardableResult
    static func spawnHandoffHelper(
        canonical: URL = canonicalURL,
        waitForPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        let argv = handoffCommand(canonical: canonical, waitForPID: waitForPID)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: argv[0])
        helper.arguments = Array(argv.dropFirst())
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            return helper.isRunning || helper.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Wrong copy chose "open the installed app": spawn the helper, then end
    /// this process. If the helper cannot be spawned, say so and stay
    /// blocked (the caller loops back to the alert) — never proceed.
    @MainActor
    static func handoffToCanonicalOrStayBlocked() {
        if spawnHandoffHelper() {
            exit(0)
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Không mở được bản trong /Applications"
        alert.informativeText = "Snippr không khởi động được trình trợ giúp. Hãy tự mở /Applications/Snippr.app; bản này sẽ thoát."
        alert.addButton(withTitle: "Thoát")
        alert.runModal()
        exit(1)
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
