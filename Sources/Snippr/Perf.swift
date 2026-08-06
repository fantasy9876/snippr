import Foundation

/// Lightweight stage timing, enabled with `SNIPPR_PERF=1`. Prints to stderr
/// and appends to ~/Library/Application Support/Snippr/perf.log.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["SNIPPR_PERF"] == "1"

    static func log(_ label: String, since start: Date) {
        guard enabled else { return }
        let ms = Date().timeIntervalSince(start) * 1000
        let line = String(format: "%-24@ %7.1f ms", label as NSString, ms)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snippr")
        let url = dir.appendingPathComponent("perf.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t = Date()
        defer { log(label, since: t) }
        return try body()
    }
}
