# Đơn xin SignPath Foundation — nội dung đã điền

Form: https://signpath.org/apply (form nhúng HubSpot + reCAPTCHA)

## Đã điền sẵn trong browser

| Trường | Giá trị |
|---|---|
| Project Name | `Snippr` |
| Repository URL | `https://github.com/fantasy9876/snippr` |
| Homepage URL | `https://snippr.pages.dev` |
| Download URL | `https://snippr.pages.dev` |
| Tagline | Free, open-source screenshot tool for Windows and macOS with annotation, scrolling capture, OCR and translation. |
| Description | (đoạn văn bên dưới) |
| Reputation | (đoạn văn bên dưới) |
| First / Last Name | Manh / Hoang (browser tự điền — kiểm tra lại) |
| Email | browser tự điền `ben@expeditee.com` — **đổi nếu muốn dùng email khác** |

## Còn lại (cần bạn chọn/bấm)

1. **Maintainer Type** → chọn `Individual`
2. **Build System** → chọn `GitHub Actions`
3. **Primary Discovery Channel** → chọn `Google search` (hoặc `ChatGPT / AI assistant` nếu có)
4. Tick ô đồng ý **SignPath Foundation Code of Conduct**
5. reCAPTCHA + bấm **Submit**

> Bước 4–5 là chấp nhận điều khoản pháp lý và CAPTCHA nên cần chính bạn thực hiện.

## Text để dán lại nếu form bị mất

**Tagline**

```
Free, open-source screenshot tool for Windows and macOS with annotation, scrolling capture, OCR and translation.
```

**Description**

```
Snippr is a free, MIT-licensed screenshot tool for Windows and macOS. It captures full screens, regions, windows and long scrolling pages, and includes an annotation editor (arrows, shapes, text, counters, pixelation), offline text recognition (OCR), translation, pinned screenshots and customizable hotkeys. All screenshots stay on the user's machine. Windows binaries (NSIS installer and portable exe) are built automatically by GitHub Actions from the public repository; code signing would remove the SmartScreen warning our users currently have to click through.
```

**Reputation**

```
Snippr is a young project developed fully in the open: complete source, CI pipelines and release history are public at https://github.com/fantasy9876/snippr (MIT license, releases at https://github.com/fantasy9876/snippr/releases, homepage https://snippr.pages.dev with real UI screenshots). It currently serves a small but growing user base distributed through the homepage, and every release is reproducibly built on GitHub Actions windows-latest runners directly from the repository. We are being transparent: it does not have wide adoption yet — signed binaries would help it grow safely instead of teaching users to bypass SmartScreen.
```

## Điều kiện đã chuẩn bị trước

- ✅ **Attribution bắt buộc**: trang chủ đã có dòng "Free code signing for Windows provided by SignPath.io — certificate by SignPath Foundation" ở footer (SignPath yêu cầu trang download phải nhắc tới họ) — đã deploy, đang live.
- ✅ Repo public, license MIT, có `LICENSE` ở gốc.
- ✅ Build tự động bằng GitHub Actions từ chính repo (yêu cầu của SignPath: build phải reproducible trên CI công khai).
- ✅ Workflow đã sẵn chỗ để cắm bước ký — khi được duyệt chỉ cần đổi sang
  `signpath/github-action-submit-signing-request` và thêm secrets.

## Sau khi được duyệt (1–3 tuần)

Nhắn Claude: sẽ chuyển workflow sang SignPath, thêm `SIGNPATH_API_TOKEN` +
organization/project/signing-policy slug, rồi chạy lại CI để ra bản cài đã ký.
