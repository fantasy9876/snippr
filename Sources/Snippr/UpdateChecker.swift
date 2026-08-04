import AppKit

/// Checks https://snippr.pages.dev/version.json for new releases; on user
/// confirmation downloads the right DMG (curl-style, no quarantine), swaps
/// /Applications/Snippr.app via a detached shell and relaunches.
@MainActor
enum UpdateChecker {
    struct RemoteVersion: Decodable {
        let mac: String
        let macUrlArm: String
        let macUrlIntel: String
    }

    static let manifestURL = "https://snippr.pages.dev/version.json"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Silent daily check at launch.
    static func checkOnLaunch() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task { await check(manual: false) }
    }

    static func check(manual: Bool) async {
        guard let url = URL(string: manifestURL) else { return }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: req)
            let remote = try JSONDecoder().decode(RemoteVersion.self, from: data)
            if isNewer(remote.mac, than: currentVersion) {
                promptUpdate(remote)
            } else if manual {
                ToastHUD.show("Snippr \(currentVersion) là bản mới nhất ✓")
            }
        } catch {
            if manual {
                ToastHUD.show("Không kiểm tra được bản mới — thử lại sau", symbol: "wifi.exclamationmark")
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func promptUpdate(_ remote: RemoteVersion) {
        let alert = NSAlert()
        alert.messageText = "Snippr \(remote.mac) đã có bản mới"
        alert.informativeText = "Bạn đang dùng \(currentVersion). Cập nhật sẽ tải bản mới, thay thế và tự mở lại app — quyền hệ thống giữ nguyên."
        alert.addButton(withTitle: "Cập nhật & mở lại")
        alert.addButton(withTitle: "Để sau")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        #if arch(arm64)
        let urlString = remote.macUrlArm
        #else
        let urlString = remote.macUrlIntel
        #endif
        Task { await performUpdate(from: urlString) }
    }

    private static func performUpdate(from urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        ToastHUD.show("Đang tải bản cập nhật…", symbol: "arrow.down.circle", duration: 30)
        do {
            let (tmpFile, _) = try await URLSession.shared.download(from: url)
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnipprUpdate.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmpFile, to: dmg)

            // detached shell survives our exit: mount → swap → relaunch → clean
            let script = """
            sleep 1
            MOUNT=$(hdiutil attach -nobrowse -readonly '\(dmg.path)' | awk -F'\\t' '/\\/Volumes\\//{print $NF}' | tail -1)
            if [ -d "$MOUNT/Snippr.app" ]; then
              rm -rf /Applications/Snippr.app
              cp -R "$MOUNT/Snippr.app" /Applications/
            fi
            hdiutil detach "$MOUNT" -quiet
            rm -f '\(dmg.path)'
            open /Applications/Snippr.app
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]
            try proc.run()
            NSApp.terminate(nil)
        } catch {
            ToastHUD.show("Tải bản cập nhật thất bại", symbol: "exclamationmark.triangle.fill")
        }
    }
}
