import AppKit

/// Bringing a menu-bar (`.accessory`) app forward on macOS 14+ is unreliable:
/// cooperative activation may simply refuse. Instead of flipping the
/// activation policy (which flashes a Dock icon and reorders windows — it
/// made editor windows visibly "jump"), windows that must be seen are opened
/// with `orderFrontRegardless` at a floating level and settle down to normal
/// once the app genuinely holds focus.
@MainActor
enum AppActivation {
    static func activateNow() {
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        // Deprecated on 14+, but unlike the cooperative `activate()` it still
        // takes focus in the common cases; visibility never depends on it.
        NSApp.activate(ignoringOtherApps: true)
    }
}
