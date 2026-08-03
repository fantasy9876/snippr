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

Settings.registerDefaults()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
