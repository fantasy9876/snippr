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

    /// Pure decision — RED stub, real rules land in the GREEN commit.
    static func evaluate(
        running: URL, discovered: [URL], canonical: URL = canonicalURL
    ) -> Verdict {
        .canonical(duplicates: [])
    }

    static func isCanonical(_ url: URL, canonical: URL = canonicalURL) -> Bool {
        false
    }

    /// Every bundle with our identifier that LaunchServices knows about, plus
    /// the running bundle itself. Empty when not running from an .app bundle.
    static func discoveredBundles() -> [URL] { [] }

    /// nil when the process is not an .app bundle (selftest / dev binaries).
    static func currentVerdict() -> Verdict? { nil }
}
