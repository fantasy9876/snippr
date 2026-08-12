import AppKit
import CryptoKit

/// Checks https://snippr.pages.dev/version.json for new releases; on user
/// confirmation downloads the right DMG, verifies it (sha256 from the manifest
/// + the bundle's own code signature), swaps /Applications/Snippr.app via a
/// detached shell that only replaces the old app once the new copy is fully in
/// place, and relaunches.
@MainActor
enum UpdateChecker {
    struct RemoteVersion: Decodable {
        let mac: String
        let macUrlArm: String
        let macUrlIntel: String
        // Optional: present on manifests published alongside a verifying client.
        let macSha256Arm: String?
        let macSha256Intel: String?
    }

    static let manifestURL = "https://snippr.pages.dev/version.json"

    /// The DMG must be served from the same host as the manifest. Prevents a
    /// tampered manifest from pointing the downloader at an arbitrary origin.
    static let allowedDownloadHost = "snippr.pages.dev"

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
        let expectedSha = remote.macSha256Arm
        #else
        let urlString = remote.macUrlIntel
        let expectedSha = remote.macSha256Intel
        #endif
        Task { await performUpdate(from: urlString, expectedSha256: expectedSha) }
    }

    private static func performUpdate(from urlString: String, expectedSha256: String?) async {
        guard let url = URL(string: urlString) else { return }
        // Only download from the manifest's own host — a tampered manifest must
        // not be able to redirect the download to an attacker-chosen origin.
        guard url.scheme == "https", url.host == allowedDownloadHost else {
            ToastHUD.show("Địa chỉ bản cập nhật không hợp lệ — bỏ qua", symbol: "exclamationmark.shield.fill")
            return
        }
        ToastHUD.show("Đang tải bản cập nhật…", symbol: "arrow.down.circle", duration: 30)
        do {
            let (tmpFile, _) = try await URLSession.shared.download(from: url)
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnipprUpdate.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmpFile, to: dmg)

            // Verify the download against the sha256 published in the manifest
            // (guards against a corrupt/truncated download or a swapped file).
            if let expected = expectedSha256?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expected.isEmpty {
                guard let actual = sha256Hex(of: dmg),
                      actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    try? FileManager.default.removeItem(at: dmg)
                    ToastHUD.show("Bản cập nhật không khớp chữ ký — đã hủy để an toàn",
                                  symbol: "exclamationmark.shield.fill", duration: 5)
                    return
                }
            }

            // Detached shell survives our exit. It mounts the DMG, verifies the
            // new bundle's code signature, and swaps ONLY after the new copy is
            // fully in place — with rollback — so a failed copy never leaves the
            // user without an app. Every failure path re-opens the current app.
            let script = """
            sleep 1
            DMG='\(dmg.path)'
            APP='/Applications/Snippr.app'
            fail() { hdiutil detach "$MOUNT" -quiet 2>/dev/null; rm -rf "$APP.new"; rm -f "$DMG"; open "$APP" 2>/dev/null; exit 1; }
            MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\\t' '/\\/Volumes\\//{print $NF}' | tail -1)
            [ -n "$MOUNT" ] || { rm -f "$DMG"; open "$APP" 2>/dev/null; exit 1; }
            SRC="$MOUNT/Snippr.app"
            [ -d "$SRC" ] || fail
            codesign --verify --deep --quiet "$SRC" || fail
            rm -rf "$APP.new"
            cp -R "$SRC" "$APP.new" || fail
            rm -rf "$APP.old"
            mv "$APP" "$APP.old" 2>/dev/null
            if mv "$APP.new" "$APP"; then
              rm -rf "$APP.old"
            else
              mv "$APP.old" "$APP" 2>/dev/null
              rm -rf "$APP.new"
            fi
            hdiutil detach "$MOUNT" -quiet
            rm -f "$DMG"
            open "$APP"
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

    /// Streaming SHA-256 so a large DMG isn't held in memory all at once.
    private static func sha256Hex(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
