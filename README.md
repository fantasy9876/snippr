# Snippr ✂️

A fast, native screenshot tool for Apple Silicon and Intel Macs — capture, annotate, OCR and scrolling screenshots, all offline. Inspired by the excellent [Shottr](https://shottr.cc), rebuilt from scratch in Swift.

**[⬇ Download Snippr](https://snippr.pages.dev)** · macOS 14+ · Apple Silicon & Intel

![Editor](docs/editor.png)

## Features

- **Capture**: fullscreen `⇧⌘1`, area selection `⇧⌘2` (frozen-screen overlay with crosshair), active/any window with styled backgrounds (wallpaper / transparent / solid / trim shadow), delayed 3s, repeat last area
- **Scrolling capture**: pick an area, then scroll down the page yourself — Snippr watches that area and stitches each matching frame into one long shot, with a live preview of the growing page. No hotkey is assigned by default: start it from the menu bar item **Scrolling Capture**, or bind a shortcut in Preferences
- **OCR / QR** `^⌥⌘O`: select an area, text lands in your clipboard — English & Vietnamese, powered by Apple Vision, fully offline
- **Editor**: arrow, line, rect, oval, highlighter, pen, text, counter badges, pixelate, crop — with undo/redo, scroll-wheel zoom, `Esc` to copy & close
- **Pin** any shot as a floating always-on-top window; corner thumbnail previews
- **Everything local**: no accounts, no uploads, no analytics

## Install

1. Download the DMG, drag **Snippr** into **Applications**
2. First launch: the app is not notarized, so macOS will warn you —
   open **System Settings → Privacy & Security** and click **Open Anyway**
   (or run `xattr -cr /Applications/Snippr.app`)
3. Grant **Screen Recording** permission when prompted, then relaunch. That is the only
   permission Snippr needs — scrolling capture does not require Accessibility, because
   you do the scrolling yourself and Snippr never synthesizes input events

## Build from source

Requires Xcode 16+ on Apple Silicon:

```bash
./build.sh          # → build/Snippr.app
```

Plain SwiftPM + a bundling script — no Xcode project. Useful entry points:

| Path | What |
|---|---|
| `Sources/Snippr/AppDelegate.swift` | menu bar, capture flows, routing |
| `Sources/Snippr/CaptureEngine.swift` | ScreenCaptureKit wrapper |
| `Sources/Snippr/SelectionOverlay.swift` | area / window-pick overlay |
| `Sources/Snippr/ScrollingCapture.swift` | manual scroll session + stitcher |
| `Sources/Snippr/EditorWindow.swift` | annotation editor |
| `Sources/Snippr/SelfTest.swift` | `Snippr --selftest` headless tests |

Distribution builds use one pinned local signing identity so Screen Recording
permission survives updates. A first installation still requires the one-time
macOS permission prompt. Source builds made without that private release key
should use an ad-hoc/debug signature and will require their own permission grant.

## License

MIT — see [LICENSE](LICENSE).

Made with [Claude Code](https://claude.com/claude-code) 🤖
