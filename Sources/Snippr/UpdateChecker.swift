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
    nonisolated static let allowedDownloadHost = "snippr.pages.dev"
    nonisolated static let installerExitWaitSeconds = 15

    /// A single running Snippr process may only hand off one installer. This
    /// closes the window where repeated manual checks could race through the
    /// same installed-app backup paths while the first download is in flight.
    private static var updateInFlight = false

    // Kept in one place so the detached installer and its fail-first fixture
    // exercise the exact same code-signature verifier arguments.
    nonisolated static let codeSignatureVerifyArguments = [
        "--verify", "--deep", "--strict",
        "-R=identifier \"com.manhhoang.snippr\"",
    ]

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
        guard !updateInFlight else {
            if manual {
                ToastHUD.show("Snippr đang cập nhật — vui lòng chờ app mở lại")
            }
            return
        }
        guard let url = URL(string: manifestURL) else { return }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: req)
            guard isAllowedUpdateServerURL(response.url) else {
                if manual {
                    ToastHUD.show(
                        "Máy chủ manifest cập nhật không hợp lệ — đã hủy",
                        symbol: "exclamationmark.shield.fill", duration: 5)
                }
                return
            }
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
        #if arch(arm64)
        let urlString = remote.macUrlArm
        let expectedSha = remote.macSha256Arm
        #else
        let urlString = remote.macUrlIntel
        let expectedSha = remote.macSha256Intel
        #endif
        guard let normalizedSha = normalizedSHA256(expectedSha) else {
            ToastHUD.show(
                "Manifest cập nhật thiếu SHA-256 hợp lệ — đã hủy",
                symbol: "exclamationmark.shield.fill", duration: 5)
            return
        }
        // Claim before entering NSAlert's nested run loop. Otherwise two
        // completed network checks can present overlapping update prompts.
        guard claimUpdateAttempt() else {
            ToastHUD.show("Snippr đang cập nhật — vui lòng chờ app mở lại")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Snippr \(remote.mac) đã có bản mới"
        alert.informativeText = "Bạn đang dùng \(currentVersion). Cập nhật sẽ tải bản mới, thay thế và tự mở lại app — quyền hệ thống giữ nguyên."
        alert.addButton(withTitle: "Cập nhật & mở lại")
        alert.addButton(withTitle: "Để sau")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            releaseUpdateAttempt()
            return
        }
        Task {
            await performUpdate(
                from: urlString,
                expectedSha256: normalizedSha,
                expectedVersion: remote.mac)
        }
    }

    private static func performUpdate(
        from urlString: String,
        expectedSha256: String,
        expectedVersion: String
    ) async {
        var handedOff = false
        var attemptDirectory: URL?
        defer {
            if !handedOff {
                if let attemptDirectory {
                    try? FileManager.default.removeItem(at: attemptDirectory)
                }
            }
            finishUpdateAttempt(didHandoff: handedOff)
        }

        guard let url = URL(string: urlString) else { return }
        // Only download from the manifest's own host — a tampered manifest must
        // not be able to redirect the download to an attacker-chosen origin.
        guard isAllowedUpdateServerURL(url) else {
            ToastHUD.show("Địa chỉ bản cập nhật không hợp lệ — bỏ qua", symbol: "exclamationmark.shield.fill")
            return
        }
        ToastHUD.show("Đang tải bản cập nhật…", symbol: "arrow.down.circle", duration: 30)
        do {
            let (tmpFile, response) = try await URLSession.shared.download(from: url)
            try consumeTemporaryDownload(tmpFile) { ownedTmpFile in
                guard isAllowedUpdateServerURL(response.url) else {
                    ToastHUD.show(
                        "Máy chủ tải bản cập nhật không hợp lệ — đã hủy",
                        symbol: "exclamationmark.shield.fill", duration: 5)
                    return
                }
                let privateDirectory = try createUpdateAttemptDirectory()
                attemptDirectory = privateDirectory
                let dmg = privateDirectory.appendingPathComponent("SnipprUpdate.dmg")
                try FileManager.default.moveItem(at: ownedTmpFile, to: dmg)

                // Verify the download against the sha256 published in the manifest
                // (guards against a corrupt/truncated download or a swapped file).
                guard let actual = sha256Hex(of: dmg),
                      actual.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
                    try? FileManager.default.removeItem(at: dmg)
                    ToastHUD.show("Bản cập nhật không khớp chữ ký — đã hủy để an toàn",
                                  symbol: "exclamationmark.shield.fill", duration: 5)
                    return
                }

                // Detached shell survives our exit. It mounts the DMG, verifies the
                // new bundle's code signature, and swaps ONLY after the new copy is
                // fully in place — with rollback — so a failed copy never leaves the
                // user without an app. Every failure path re-opens the current app.
                let script = detachedInstallerScript()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = [
                    "-c", script, "snippr-updater",
                    dmg.path, "/Applications/Snippr.app", "1", "1",
                    expectedVersion, updateLogURL.path, expectedSha256,
                    String(ProcessInfo.processInfo.processIdentifier),
                    String(installerExitWaitSeconds),
                    "/usr/bin/open", "/bin/mv", privateDirectory.path,
                ]
                try proc.run()
                handedOff = true
                NSApp.terminate(nil)
            }
        } catch {
            ToastHUD.show("Tải bản cập nhật thất bại", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// The detached shell takes paths as positional arguments instead of
    /// interpolating them into shell source. Arguments are:
    ///   $1 DMG path, $2 installed app path, $3 delay seconds, $4 relaunch 0/1,
    ///   $5 expected marketing version, $6 persistent log path,
    ///   $7 expected DMG SHA-256, $8 old app PID, $9 PID wait timeout,
    ///   $10 open tool, $11 activation move tool, $12 private attempt directory.
    nonisolated static func detachedInstallerScript() -> String {
        let verificationFlags = codeSignatureVerifyArguments
            .map(shellQuote)
            .joined(separator: " ")
        return """
            DELAY="${3:-1}"
            RELAUNCH="${4:-1}"
            EXPECTED_VERSION="$5"
            LOG="$6"
            EXPECTED_SHA="$7"
            OLD_PID="${8:-0}"
            WAIT_TIMEOUT="${9:-15}"
            OPEN_TOOL="${10:-/usr/bin/open}"
            ACTIVATE_TOOL="${11:-/bin/mv}"
            ATTEMPT_DIR="${12:-}"
            [ -n "$LOG" ] || LOG="$HOME/Library/Logs/Snippr/update.log"
            LOG_DIR="${LOG%/*}"
            [ "$LOG_DIR" = "$LOG" ] && LOG_DIR="."
            /bin/mkdir -p "$LOG_DIR" 2>/dev/null
            # Logging is diagnostic, never a transaction prerequisite. Open a
            # safe sink first; replace fd 3 only after a writable log probe.
            exec 3>/dev/null
            if /usr/bin/touch "$LOG" 2>/dev/null && [ -w "$LOG" ]; then
              if exec 2>&3 3>>"$LOG"; then :; fi
            fi
            log() { /usr/bin/printf '%s %s\\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >&3; }
            MOUNT=""
            BACKED_UP=0
            ACTIVATED=0
            STAGE="delay"
            DMG="$1"
            APP="$2"
            cleanup_download() {
              CLEANUP_STATUS=0
              /bin/rm -f "$DMG" || CLEANUP_STATUS=1
              if [ -n "$ATTEMPT_DIR" ]; then
                /bin/rmdir "$ATTEMPT_DIR" 2>/dev/null || CLEANUP_STATUS=1
              fi
              return "$CLEANUP_STATUS"
            }
            reopen() {
              [ "$RELAUNCH" = "1" ] || return 0
              "$OPEN_TOOL" "$APP" >&3 2>&1
            }
            restore_old() {
              if [ "$BACKED_UP" = "1" ] && [ -e "$APP.old" ]; then
                if [ -e "$APP" ]; then
                  /bin/rm -rf "$APP" 2>&3 || return 1
                  [ ! -e "$APP" ] || return 1
                fi
                /bin/mv "$APP.old" "$APP" 2>&3 || return 1
                BACKED_UP=0
                ACTIVATED=0
              elif [ ! -e "$APP" ] && [ -e "$APP.old" ]; then
                /bin/mv "$APP.old" "$APP" 2>&3 || return 1
              fi
              return 0
            }
            detach_mount() {
              [ -n "$MOUNT" ] || return 0
              /usr/bin/hdiutil detach "$MOUNT" -quiet >&3 2>&1
              DETACH_STATUS=$?
              if [ "$DETACH_STATUS" -ne 0 ]; then
                /usr/bin/hdiutil detach "$MOUNT" -force -quiet >&3 2>&1
                DETACH_STATUS=$?
              fi
              if [ "$DETACH_STATUS" -eq 0 ]; then MOUNT=""; fi
              return "$DETACH_STATUS"
            }
            fail() {
              STATUS="${1:-$?}"
              trap '' HUP INT TERM
              log "FAIL stage=$STAGE exit=$STATUS"
              detach_mount || log "WARN stage=detach mount=$MOUNT"
              /bin/rm -rf "$APP.new"
              restore_old || log "FATAL stage=restore app_old=$APP.old"
              cleanup_download || log "WARN stage=cleanup-download dmg=$DMG"
              reopen
              REOPEN_STATUS=$?
              [ "$REOPEN_STATUS" -eq 0 ] || log "FATAL stage=rollback-relaunch exit=$REOPEN_STATUS"
              [ "$STATUS" -ne 0 ] || STATUS=1
              exit "$STATUS"
            }
            signal_fail() {
              SIGNAL_NAME="$1"
              SIGNAL_STATUS="$2"
              STAGE="signal-$SIGNAL_NAME"
              fail "$SIGNAL_STATUS"
            }
            trap 'signal_fail hup 129' HUP
            trap 'signal_fail int 130' INT
            trap 'signal_fail term 143' TERM

            case "$DELAY" in *[!0-9]*|'') STAGE="arguments"; fail 2 ;; esac
            case "$OLD_PID" in *[!0-9]*|'') STAGE="arguments"; fail 2 ;; esac
            case "$WAIT_TIMEOUT" in *[!0-9]*|'') STAGE="arguments"; fail 2 ;; esac
            [ -n "$DMG" ] && [ -n "$APP" ] && [ -n "$EXPECTED_VERSION" ] \
              && [ -n "$EXPECTED_SHA" ] || { STAGE="arguments"; fail 2; }

            /bin/sleep "$DELAY"
            STAGE="wait-old-process"
            REMAINING="$WAIT_TIMEOUT"
            if [ "$OLD_PID" -gt 0 ] && /bin/kill -0 "$OLD_PID" 2>/dev/null; then
              log "WAIT stage=old-process pid=$OLD_PID timeout=$WAIT_TIMEOUT"
            fi
            while [ "$OLD_PID" -gt 0 ] && /bin/kill -0 "$OLD_PID" 2>/dev/null; do
              [ "$REMAINING" -gt 0 ] || fail 1
              /bin/sleep 1
              REMAINING=$((REMAINING - 1))
            done
            [ "$OLD_PID" -eq 0 ] || log "READY stage=old-process pid=$OLD_PID"

            STAGE="recover-stale-backup"
            if [ ! -e "$APP" ] && [ -e "$APP.old" ]; then
              restore_old || fail 1
            fi

            STAGE="hash"
            ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$DMG" 2>&3 | /usr/bin/awk '{print $1}') || fail
            [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail 1

            STAGE="attach"
            MOUNT=$(/usr/bin/hdiutil attach -nobrowse -readonly "$DMG" 2>&3 | /usr/bin/awk -F'\\t' '/\\/Volumes\\//{print $NF}' | /usr/bin/tail -1)
            [ -n "$MOUNT" ] || fail
            SRC="$MOUNT/Snippr.app"
            [ -d "$SRC" ] || fail
            STAGE="copy"
            /bin/rm -rf "$APP.new" 2>&3 || fail
            [ ! -e "$APP.new" ] || fail
            /bin/cp -R "$SRC" "$APP.new" || fail
            STAGE="version"
            CANDIDATE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP.new/Contents/Info.plist" 2>&3) || fail
            [ "$CANDIDATE_VERSION" = "$EXPECTED_VERSION" ] || fail
            STAGE="verify-staged-copy"
            /usr/bin/codesign \(verificationFlags) "$APP.new" >&3 2>&1 || fail
            # The mounted image is no longer needed once the staged copy has
            # passed every validation. Detach before touching the live app so
            # a detach failure cannot leave a half-completed swap.
            STAGE="detach"
            detach_mount || fail
            STAGE="cleanup-download"
            cleanup_download || fail
            STAGE="backup"
            if [ -e "$APP.old" ]; then
              [ -e "$APP" ] || { restore_old || fail 1; }
              /bin/rm -rf "$APP.old" 2>&3 || fail
              [ ! -e "$APP.old" ] || fail
            fi
            if [ -e "$APP" ]; then
              /bin/mv "$APP" "$APP.old" 2>&3 || fail
              BACKED_UP=1
            fi
            STAGE="activate"
            if "$ACTIVATE_TOOL" "$APP.new" "$APP" 2>&3; then
              ACTIVATED=1
            else
              restore_old
              fail 1
            fi
            STAGE="cleanup"
            STAGE="relaunch"
            reopen
            REOPEN_STATUS=$?
            [ "$REOPEN_STATUS" -eq 0 ] || fail "$REOPEN_STATUS"
            /bin/rm -rf "$APP.old" 2>&3 || log "WARN stage=remove-backup app_old=$APP.old"
            BACKED_UP=0
            trap - HUP INT TERM
            log "SUCCESS version=$EXPECTED_VERSION app=$APP"
            exit 0
            """
    }

    static func claimUpdateAttempt() -> Bool {
        guard !updateInFlight else { return false }
        updateInFlight = true
        return true
    }

    static func releaseUpdateAttempt() {
        updateInFlight = false
    }

    static func finishUpdateAttempt(didHandoff: Bool) {
        if !didHandoff {
            releaseUpdateAttempt()
        }
    }

    static func consumeTemporaryDownload<Result>(
        _ url: URL,
        operation: (URL) throws -> Result
    ) rethrows -> Result {
        defer { try? FileManager.default.removeItem(at: url) }
        return try operation(url)
    }

    nonisolated static func createUpdateAttemptDirectory(
        in base: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let directory = base.appendingPathComponent(
            "SnipprUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    nonisolated static func normalizedSHA256(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), value.count == 64,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return nil }
        return value
    }

    nonisolated static func isAllowedUpdateServerURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedDownloadHost,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static var updateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Snippr/update.log")
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
