import AppKit

/// `Snippr --benchmark`: measures how long the editor takes to appear
/// for a realistic retina screenshot. Prints milliseconds per stage.
@MainActor
enum Benchmark {
    static var requested: Bool { CommandLine.arguments.contains("--benchmark") }

    static func run() {
        let width = 3600, height = 2338 // full retina display shot
        var t = Date()
        func lap(_ label: String) {
            let ms = Date().timeIntervalSince(t) * 1000
            print(String(format: "%-28s %7.1f ms", (label as NSString).utf8String!, ms))
            t = Date()
        }

        let cg = SelfTest.makeTestImage(width: width, height: height)
        lap("make test image")

        let shot = CapturedImage(cgImage: cg, scale: 2)
        lap("wrap CapturedImage")

        // full open path, exactly what a capture does
        let wc = EditorWindowController.open(with: shot)
        lap("EditorWindowController.open")

        wc.window?.displayIfNeeded()
        lap("first display (paint)")

        // second window: measures steady-state cost after warm caches
        let wc2 = EditorWindowController.open(with: shot)
        wc2.window?.displayIfNeeded()
        lap("second window open+paint")

        // Real capture path, measured the way a user experiences it: after the
        // app has been running (caches warm), not during cold launch.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000) // let prewarm finish
            print("--- warm app (what users actually hit) ---")
            for round in 1...2 {
                var t2 = Date()
                func lap2(_ label: String) {
                    let ms = Date().timeIntervalSince(t2) * 1000
                    print(String(format: "%-28s %7.1f ms", ("\(label) #\(round)" as NSString).utf8String!, ms))
                    t2 = Date()
                }
                let all = Date()
                guard let real = try? await CaptureEngine.shared.captureDisplay(screen: screen) else {
                    print("capture failed (no Screen Recording permission?)")
                    exit(1)
                }
                lap2("captureDisplay")
                let wc3 = EditorWindowController.open(with: real)
                lap2("editor open")
                wc3.window?.displayIfNeeded()
                wc3.window?.contentView?.displayIfNeeded()
                lap2("forced paint")
                print(String(format: "%-28s %7.1f ms",
                             ("END-TO-END #\(round)" as NSString).utf8String!,
                             Date().timeIntervalSince(all) * 1000))
                wc3.window?.close()
            }
            exit(0)
        }
    }
}
