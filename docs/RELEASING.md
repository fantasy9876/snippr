# Release checklist

Từ macOS ≥ 1.2.0 / Windows ≥ 1.2.7, **updater xác minh tính toàn vẹn trước khi
cài** — release thiếu hash sẽ khiến client từ chối auto-update (fail-closed).

## macOS (vd. 1.2.0)

1. Bump version: `Support/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`),
   `PreferencesWindow.swift` (AboutTab).
2. `./build.sh` → đóng DMG cho arm64 + intel, copy vào `site/`.
3. `shasum -a 256 site/Snippr-<ver>.dmg site/Snippr-<ver>-intel.dmg`
4. Cập nhật `site/version.json`: `mac`, `macUrlArm`, `macUrlIntel`,
   **`macSha256Arm`, `macSha256Intel`** (bắt buộc — client mới sẽ so khớp).
5. Cập nhật nút tải trong `site/index.html`.

Lưu ý: script cập nhật giờ swap an toàn (`Snippr.app.new` → đổi tên sau khi
copy xong, có rollback) và verify `codesign --verify --deep` + sha256.

## Windows (vd. 1.2.7)

1. Bump version ở **3 chỗ**: `windows/Snippr.Win.csproj` (`<Version>`),
   `windows/installer.nsi` (`OutFile` + `DisplayVersion`).
2. Build + ký installer (SignPath qua CI).
3. `sha256sum SnipprSetup-<ver>-win-x64.exe`
4. Cập nhật `site/version.json`: `win`, `winUrl`, **`winSha256`** (bắt buộc
   nếu installer KHÔNG được ký Authenticode; nên điền luôn kể cả khi đã ký).
5. ⚠️ Đặt tag GitHub Release theo version Windows hoặc dùng tag chung rõ ràng —
   `winUrl` trỏ nhầm tag cũ là mọi client ăn 404.

Logic verify phía client (Update.cs): sha khớp **hoặc** chữ ký Authenticode
hợp lệ → chạy; sha lệch → từ chối; không chữ ký + không sha → từ chối.

## Cả hai

- Host được phép tải: `snippr.pages.dev`, `github.com`,
  `objects.githubusercontent.com` (sửa `AllowedHosts`/`allowedDownloadHost`
  nếu đổi nơi phát hành).
- Chạy test trước khi phát hành:
  - macOS: `Snippr --selftest` và `Snippr --test-scrollstitch`
  - Windows: `dotnet build -c Release` (và test tay scroll capture)
