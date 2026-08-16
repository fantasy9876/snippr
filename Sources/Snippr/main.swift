import AppKit

// Entry point. `--selftest [outdir]` runs headless feature tests and exits.
let arguments = CommandLine.arguments
if let idx = arguments.firstIndex(of: "--selftest") {
    let outDir = arguments.count > idx + 1
        ? arguments[idx + 1]
        : NSTemporaryDirectory() + "snippr-selftest"
    exit(SelfTest.run(outputDir: outDir))
}

if arguments.contains("--check-permissions") {
    let screen = CGPreflightScreenCaptureAccess()
    let ax = AXIsProcessTrusted()
    print("screen-recording: \(screen ? "granted" : "NOT granted")")
    print("accessibility: \(ax ? "granted" : "NOT granted")")
    exit(0)
}

let devToolFlags = [
    "--uitest", "--benchmark", "--test-firstopen", "--test-scrollpreview",
    "--test-scrollstitch", "--test-scrollreal", "--test-scrollapp",
    "--test-scrollreplay", "--test-scrollreplay-split",
]
let isDevTool = devToolFlags.contains { arguments.contains($0) }

// Test harnesses share the installed app's defaults domain when launched from
// an app bundle. Register fallback values for them, but never run a persistent
// behavior migration against the user's real preferences.
Settings.registerDefaults(applyMigrations: !isDevTool)
MainActor.assumeIsolated {
    // Single instance: a stray copy (e.g. a dev/test build) silently steals
    // the global hotkeys from the real one — never allow two Snipprs.
    // Dev tool flags bypass the guard because those runs exit by themselves.
    // Canonical-aware: the installed /Applications/Snippr.app must never lose
    // to a stale copy that happens to be running (that is exactly how the
    // wrong signature ends up asking for Screen Recording again) — it evicts
    // the wrong copy and proceeds; a wrong copy never blocks the canonical.
    if !isDevTool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.manhhoang.snippr"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine }
        let arbitration = BundleIntegrity.instanceArbitration(
            selfIsCanonical: BundleIntegrity.isCanonical(Bundle.main.bundleURL),
            others: running.map { ($0.processIdentifier, $0.bundleURL) })
        switch arbitration {
        case .proceed:
            break
        case .exitOtherRunning:
            NSLog("Snippr: another instance is already running (pid \(running[0].processIdentifier)) — exiting")
            exit(0)
        case let .evictThenProceed(pids):
            NSLog("Snippr: canonical app evicting non-canonical instance(s) \(pids)")
            func app(_ pid: pid_t) -> NSRunningApplication? {
                running.first { $0.processIdentifier == pid }
            }
            let outcome = BundleIntegrity.evictInstances(
                pids,
                requestTerminate: { app($0)?.terminate() },
                forceTerminate: { app($0)?.forceTerminate() },
                isAlive: { pid in
                    guard let a = app(pid) else { return false }
                    return !a.isTerminated && kill(pid, 0) == 0
                },
                wait: { RunLoop.current.run(until: Date().addingTimeInterval($0)) })
            switch outcome {
            case let .evicted(forced):
                if !forced.isEmpty { NSLog("Snippr: force-terminated \(forced)") }
            case let .stillAlive(alive):
                // Fail closed: never run two Snipprs. Nothing has been set up
                // (no hotkeys, no TCC, no launch status) — just leave.
                NSLog("Snippr: non-canonical instance(s) \(alive) still alive after \(BundleIntegrity.evictionMaxDuration)s — exiting")
                exit(0)
            }
        }
    }

    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
