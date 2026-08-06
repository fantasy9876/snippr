import AppKit

/// Snippr lives in the menu bar (`.accessory`), and macOS 14+ frequently
/// refuses activation requests from apps that aren't already frontmost —
/// which left editor windows opening *behind* whatever the user was using.
/// While any real window is open the app is promoted to `.regular`, so it can
/// take focus like a normal app, and demoted again when the last one closes.
@MainActor
enum AppActivation {
    private static var openWindows = 0

    static func beginWindowSession() {
        openWindows += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        // must happen before ordering windows: a hidden app shows nothing
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
    }

    static func endWindowSession() {
        openWindows = max(0, openWindows - 1)
        guard openWindows == 0 else { return }
        // let the closing animation finish before hiding the Dock tile again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard openWindows == 0 else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Bring the app (and its windows) forward. Every step matters: a hidden
    /// app shows nothing until unhidden, and cooperative activation can ignore
    /// `NSApp.activate()` alone, so the running-application call backs it up.
    static func activateNow() {
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
