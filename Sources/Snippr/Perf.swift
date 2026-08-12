import Foundation

/// Append-only event log with a size cap. Writes go through one shared handle
/// on a utility queue — the old code opened, sought and closed a FileHandle
/// synchronously on the main actor for every capture, and the file grew
/// forever.
enum EventLog {
    private static let queue = DispatchQueue(label: "com.manhhoang.snippr.eventlog", qos: .utility)
    private static var handle: FileHandle?
    private static let maxBytes: UInt64 = 262_144 // 256 KB, then start over

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snippr/events.log")
    }

    static func append(_ line: String) {
        let entry = "\(Date()) \(line)\n"
        queue.async {
            if handle == nil { open() }
            guard let h = handle else { return }
            if let offset = try? h.offset(), offset > maxBytes {
                try? h.truncate(atOffset: 0)
                try? h.seek(toOffset: 0)
            }
            try? h.write(contentsOf: entry.data(using: .utf8)!)
        }
    }

    private static func open() {
        let file = url
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }
}

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
