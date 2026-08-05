# Hướng dẫn xin chữ ký số cho Snippr (Windows)

Mục tiêu: file `SnipprSetup-*.exe` được ký số → SmartScreen không còn chặn
"Unknown publisher", teammates cài không gặp trở ngại.

**Pipeline đã sẵn sàng**: workflow CI (`.github/workflows/windows-installer.yml`)
đã có sẵn bước ký bằng Azure Trusted Signing — đang tắt. Chỉ cần thêm 6 secrets
vào GitHub là từ đó mọi bản build tự động được ký, không phải sửa gì thêm.

---

## So sánh 3 lựa chọn

| | 🅰 Azure Trusted Signing (khuyên dùng) | 🅱 SignPath OSS (miễn phí) | 🅲 Certum Open Source |
|---|---|---|---|
| Giá | ~$9.99/tháng (~2.9tr đ/năm) | **0đ** (cho dự án mã nguồn mở) | ~€69/năm + €35 USB token |
| Xác minh | CCCD/hộ chiếu cá nhân, vài ngày | Đơn xin duyệt dự án OSS, 1–3 tuần | CCCD/hộ chiếu, vài ngày |
| Ký trong CI | ✅ Chính chủ Microsoft, dễ nhất | ✅ Có integration GitHub | ⚠️ Khó — token USB cắm máy local |
| SmartScreen | Hết cảnh báo gần như ngay | Hết sau khi tích lũy reputation | Hết sau khi tích lũy reputation |

Khuyến nghị: **làm 🅰 ngay** nếu chấp nhận phí; **nộp đơn 🅱 song song** (Snippr
là MIT trên GitHub public — đủ điều kiện), nếu được duyệt thì hủy 🅰 để về 0đ.

---

## 🅰 Các bước Azure Trusted Signing (~30 phút thao tác + vài ngày chờ xác minh)

> Toàn bộ các bước này cần bạn tự làm vì liên quan thanh toán + giấy tờ tùy thân.

1. **Tạo tài khoản Azure**: https://azure.microsoft.com/free — cần thẻ tín dụng.
   Tạo 1 Subscription (Pay-As-You-Go).
2. **Tạo Trusted Signing account**: Azure Portal → search "Trusted Signing
   Accounts" → Create. Region chọn `East US` hoặc `West US 2`. SKU: Basic
   ($9.99/tháng). Ghi lại **account name** và **endpoint URI** (dạng
   `https://eus.codesigning.azure.net`).
3. **Xác minh danh tính (Identity Validation)**: trong resource vừa tạo →
   Identity validations → New → **Individual**. Điền tên đúng theo hộ chiếu/CCCD,
   làm theo hướng dẫn xác minh (Microsoft Entra Verified ID, chụp giấy tờ).
   Chờ duyệt: thường 1–3 ngày.
4. **Tạo Certificate Profile**: sau khi identity được duyệt → Certificate
   profiles → Create → loại **Public Trust**, chọn identity vừa xác minh.
   Ghi lại **profile name**.
5. **Tạo credentials cho CI**: Azure Portal → Microsoft Entra ID → App
   registrations → New registration (tên `snippr-ci`). Vào app → Certificates &
   secrets → New client secret (ghi lại **Value** ngay — chỉ hiện 1 lần).
   Ghi lại thêm **Application (client) ID** và **Directory (tenant) ID**.
6. **Gán quyền ký**: quay lại Trusted Signing account → Access control (IAM) →
   Add role assignment → role **Trusted Signing Certificate Profile Signer** →
   gán cho app `snippr-ci`.
7. **Thêm 6 secrets vào GitHub** (bạn tự thêm — không gửi giá trị cho ai khác):
   repo `fantasy9876/snippr` → Settings → Secrets and variables → Actions →
   New repository secret, đúng các tên sau:

   | Tên secret | Giá trị |
   |---|---|
   | `AZURE_TENANT_ID` | Directory (tenant) ID ở bước 5 |
   | `AZURE_CLIENT_ID` | Application (client) ID ở bước 5 |
   | `AZURE_CLIENT_SECRET` | Client secret Value ở bước 5 |
   | `TRUSTED_SIGNING_ENDPOINT` | Endpoint URI ở bước 2 |
   | `TRUSTED_SIGNING_ACCOUNT` | Tên Trusted Signing account ở bước 2 |
   | `TRUSTED_SIGNING_PROFILE` | Tên certificate profile ở bước 4 |

8. **Xong** — chạy lại workflow (hoặc nhờ Claude chạy):
   `gh workflow run windows-installer.yml -f tag=v1.1.2`
   Workflow tự phát hiện secrets và ký cả `Snippr.exe` lẫn `SnipprSetup-*.exe`
   (kèm timestamp — chữ ký sống mãi kể cả khi cert hết hạn).

## 🅱 SignPath Foundation — miễn phí cho mã nguồn mở

1. Nộp đơn tại https://signpath.org (Open Source program), khai:
   repo `https://github.com/fantasy9876/snippr`, license MIT, mô tả app.
2. Chờ duyệt (1–3 tuần). Được duyệt sẽ có organization + project trên
   signpath.io, ký qua GitHub Actions bằng `signpath/github-action-submit-signing-request`.
3. Khi có tài khoản, nhắn Claude — mình chuyển workflow sang SignPath trong một buổi.

## 🅲 Certum Open Source (nếu thích sở hữu cert vật lý)

1. Mua "Open Source Code Signing" tại certum.eu + đầu đọc thẻ/token.
2. Xác minh giấy tờ, nhận cert vào token.
3. Nhược điểm lớn: phải ký trên máy có cắm token (`signtool sign /n "..."`),
   không tự động trong CI được — mỗi release phải tự tay ký trên máy Windows.

---

### Ghi chú

- Trong lúc chưa có chữ ký, teammates vẫn cài được (More info → Run anyway) —
  chữ ký chỉ là bỏ bước phiền đó.
- Bên macOS tương đương là Apple Developer Program ($99/năm) để notarize DMG —
  hết luôn cảnh báo "malware" và lệnh curl không còn cần thiết. Làm sau nếu muốn.
