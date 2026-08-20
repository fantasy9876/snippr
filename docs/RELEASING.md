# Release checklist

Từ macOS ≥ 1.2.0 / Windows ≥ 1.2.7, **updater xác minh tính toàn vẹn trước khi
cài** — release thiếu hash sẽ khiến client từ chối auto-update (fail-closed).

## macOS (vd. 1.2.2)

0. **Danh tính ký phải ổn định.** Release được khóa vào fingerprint công khai
   `946c43e6456970f5ec11544b3244c192aae949d6` trong `Support/Info.plist`.
   `./build.sh release` chỉ ký bằng đúng private key đó và **không tự tạo cert
   thay thế** nếu key vắng. Keychain riêng gồm ba file
   `~/Library/Keychains/snippr-dev.keychain-db`, `snippr-dev.password` và
   `snippr-dev.keychain-db.cert.pem`; chuyển build host phải chuyển đủ ba file
   bằng kênh bí mật, giữ permission file mật khẩu 0600, rồi chạy
   `scripts/ensure-dev-cert.sh` một lần. Release build **từ chối** ký ad-hoc:
   ad-hoc pin designated requirement vào
   cdhash, mỗi bản build/update mới làm macOS coi là app khác → mất Screen
   Recording/Accessibility dù toggle vẫn bật (sự cố 1.2.2/1.2.3 trên Mac Studio).
   Không commit/upload keychain hoặc file mật khẩu.

1. Bump version: `Support/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`),
   `PreferencesWindow.swift` (AboutTab).
2. `./build.sh release arm64` và `./build.sh release x86_64`; mỗi lần copy app
   ra staging riêng trước khi build kiến trúc kế tiếp. Script ký và kiểm **cùng
   pinned DR** cho cả hai. Sau đó đóng hai DMG và copy vào thư mục staging deploy
   (các DMG bị gitignore, không nằm sẵn trong `site/`).
3. `shasum -a 256 <staging>/Snippr-<ver>.dmg <staging>/Snippr-<ver>-intel.dmg`
4. Cập nhật `site/version.json`: `mac`, `macUrlArm`, `macUrlIntel`,
   **`macSha256Arm`, `macSha256Intel`** (bắt buộc — client mới sẽ so khớp).
   `index.html` đọc các trường này lúc mở trang — **không** sửa nút tải
   trong HTML. Chạy `scripts/test-site-versions-from-json.sh` trước khi
   deploy: cứng số phiên bản hiện tại vào `index.html` là đỏ.

Lưu ý: script cập nhật giờ swap an toàn (`Snippr.app.new` → đổi tên sau khi
copy xong, có rollback) và verify SHA-256 + đúng bundle ID + đúng certificate
root; một DMG ký bằng cert khác bị từ chối trước khi đụng app đang cài.

## Windows (vd. 1.2.7)

1. Bump version ở **3 chỗ**: `windows/Snippr.Win.csproj` (`<Version>`),
   `windows/installer.nsi` (`OutFile` + `DisplayVersion`).
2. Build + ký installer (SignPath qua CI).
3. `sha256sum SnipprSetup-<ver>-win-x64.exe`
4. Cập nhật `site/version.json`: `win`, `winUrl`, **`winSha256`** (bắt buộc
   nếu installer KHÔNG được ký Authenticode; nên điền luôn kể cả khi đã ký).
   Link Setup + ZIP portable trên trang chủ lấy từ `winUrl` (portable =
   cùng thư mục tag, tên `Snippr-portable-win-x64.zip`). Không sửa
   `index.html`.
5. ⚠️ Đặt tag GitHub Release theo version Windows hoặc dùng tag chung rõ ràng —
   `winUrl` trỏ nhầm tag cũ là mọi client ăn 404.

Logic verify phía client (Update.cs): sha khớp **hoặc** chữ ký Authenticode
hợp lệ → chạy; sha lệch → từ chối; không chữ ký + không sha → từ chối.

## Cả hai

- Host được phép tải: `snippr.pages.dev`, `github.com`,
  `objects.githubusercontent.com` (sửa `AllowedHosts`/`allowedDownloadHost`
  nếu đổi nơi phát hành).
- Chạy test trước khi phát hành:
  - macOS: `Snippr --selftest`, `Snippr --test-scrollstitch`,
    `scripts/test-site-installer-transaction.sh` (bắt buộc trước khi deploy
    `site/install.sh`), và `scripts/test-site-versions-from-json.sh`
    (bắt buộc trước khi deploy `site/index.html`)
  - Windows: `dotnet build -c Release` (và test tay scroll capture)
