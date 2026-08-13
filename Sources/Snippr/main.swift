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
    if !isDevTool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.manhhoang.snippr"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            NSLog("Snippr: another instance is already running (pid \(others[0].processIdentifier)) — exiting")
            exit(0)
        }
    }

    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
