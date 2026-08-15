import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import os

enum CaptureError: Error {
    case noDisplay
    case noWindow
    case cancelled
    case permission
    case wrongRegion
}

/// One immutable, pixel-aligned selection shared by sourceRect capture and
/// full-display fallback. Quantizing both edges once avoids the scaled-display
/// trap where `Int(width * scale)` produced 800 pixels while `.integral` crop
/// expanded the same fractional selection to 801 pixels.
struct CanonicalCaptureRegion {
    let screenSize: CGSize
    let scale: CGFloat
    /// Display-local points, TOP-left origin (ScreenCaptureKit coordinates).
    let sourceRect: CGRect
    /// Native display pixels, TOP-left origin (CGImage coordinates).
    let pixelRect: CGRect

    init?(screenSize: CGSize, viewRect: CGRect, scale: CGFloat) {
        guard scale.isFinite, scale > 0,
              screenSize.width.isFinite, screenSize.height.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              [viewRect.minX, viewRect.minY, viewRect.maxX, viewRect.maxY]
                .allSatisfy(\.isFinite)
        else { return nil }

        let rawPixels = CGRect(
            x: viewRect.minX * scale,
            y: (screenSize.height - viewRect.maxY) * scale,
            width: viewRect.width * scale,
            height: viewRect.height * scale).standardized.integral
        let displayPixels = CGRect(
            x: 0, y: 0,
            width: screenSize.width * scale,
            height: screenSize.height * scale).integral
        let pixels = rawPixels.intersection(displayPixels)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }

        self.screenSize = screenSize
        self.scale = scale
        pixelRect = pixels
        sourceRect = CGRect(
            x: pixels.minX / scale,
            y: pixels.minY / scale,
            width: pixels.width / scale,
            height: pixels.height / scale)
    }

    var pixelWidth: Int { Int(pixelRect.width) }
    var pixelHeight: Int { Int(pixelRect.height) }

    /// Screen-local points, bottom-left origin (AppKit view coordinates).
    var viewRect: CGRect {
        CGRect(
            x: sourceRect.minX,
            y: screenSize.height - sourceRect.maxY,
            width: sourceRect.width,
            height: sourceRect.height)
    }
}

/// A captured bitmap plus its backing scale, so point sizes stay correct on Retina.
struct CapturedImage {
    let cgImage: CGImage
    let scale: CGFloat

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    var pointSize: CGSize {
        CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
    }

    var nsImage: NSImage {
        let img = NSImage(cgImage: cgImage, size: pointSize)
        return img
    }

    /// Crop using a rect in screen-local points with bottom-left origin (AppKit view coords).
    ///
    /// The crop is materialized into its own tightly-sized bitmap instead of
    /// using `CGImage.cropping`, which shares (and therefore retains) the whole
    /// parent buffer — a small area shot used to pin the entire frozen-display
    /// bitmap (~24–57 MB) in memory for as long as the crop lived.
    func cropping(toViewRect rect: CGRect) -> CapturedImage? {
        let px = CGRect(
            x: rect.minX * scale,
            y: (CGFloat(cgImage.height) / scale - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard let cropped = cgImage.cropping(to: px),
              let owned = cropped.materialized() else { return nil }
        return CapturedImage(cgImage: owned, scale: scale)
    }

    /// Exact fallback crop for a canonical scrolling region. No second
    /// `.integral` conversion is allowed here: `pixelRect` is already the
    /// single quantized geometry used to configure sourceRect output.
    func cropping(to region: CanonicalCaptureRegion) -> CapturedImage? {
        guard abs(scale - region.scale) < 0.01,
              CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
                .contains(region.pixelRect),
              let cropped = cgImage.cropping(to: region.pixelRect),
              cropped.width == region.pixelWidth,
              cropped.height == region.pixelHeight,
              let owned = cropped.materialized()
        else { return nil }
        return CapturedImage(cgImage: owned, scale: scale)
    }

    func downscaledTo1x() -> CapturedImage {
        guard scale > 1 else { return self }
        let w = Int(CGFloat(cgImage.width) / scale)
        let h = Int(CGFloat(cgImage.height) / scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return self }
        return CapturedImage(cgImage: out, scale: 1)
    }
}

/// Metadata returned with a ScreenCaptureKit sample-buffer screenshot. Unlike
/// pixel comparison with a later full-screen shot, `screenRect` describes the
/// exact compositor frame that supplied the pixels, so animated/scrolling
/// content cannot make coordinate validation fail spuriously.
struct ValidatedRectCapture {
    let image: CapturedImage
    let screenRect: CGRect?
    let requestedScreenRect: CGRect

    /// Fail closed when ScreenCaptureKit omits the same-frame metadata. The
    /// full-display crop backend is slower, but it is known to use the right
    /// coordinate space on the scaled-display configurations that motivated
    /// this check.
    var containsRequestedRegion: Bool {
        Self.matches(screenRect, requested: requestedScreenRect)
            && abs(CGFloat(image.cgImage.width) - requestedScreenRect.width * image.scale) <= 1
            && abs(CGFloat(image.cgImage.height) - requestedScreenRect.height * image.scale) <= 1
    }

    static func matches(
        _ reported: CGRect?, requested: CGRect, tolerance: CGFloat = 1.25
    ) -> Bool {
        guard let reported,
              reported.width > 0, reported.height > 0,
              requested.width > 0, requested.height > 0,
              [reported.minX, reported.minY, reported.width, reported.height,
               requested.minX, requested.minY, requested.width, requested.height]
                .allSatisfy(\.isFinite)
        else { return false }
        return abs(reported.minX - requested.minX) <= tolerance
            && abs(reported.minY - requested.minY) <= tolerance
            && abs(reported.width - requested.width) <= tolerance
            && abs(reported.height - requested.height) <= tolerance
    }

    static func requestedScreenRect(displayFrame: CGRect, sourceRect: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + sourceRect.minX,
            y: displayFrame.minY + sourceRect.minY,
            width: sourceRect.width,
            height: sourceRect.height)
    }
}

/// Info about an on-screen window, from CGWindowList (front-to-back order).
struct WindowInfo {
    let windowID: CGWindowID
    let frameCG: CGRect // CG global coords: top-left origin, y down
    let title: String
    let ownerName: String
    let pid: pid_t

    /// Convert to AppKit global coords (bottom-left origin of primary screen).
    var frameAppKit: CGRect {
        let primaryHeight = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
        return CGRect(
            x: frameCG.minX,
            y: primaryHeight - frameCG.maxY,
            width: frameCG.width,
            height: frameCG.height
        )
    }
}

@MainActor
final class CaptureEngine {
    static let shared = CaptureEngine()

    private let screenshotContext = CIContext(options: [.cacheIntermediates: false])

    /// Enumerating shareable content costs ~30 ms, so the display list is
    /// cached (displays rarely change) and refreshed on screen changes.
    private var cachedContent: SCShareableContent?
    private var cachedAt = Date.distantPast
    private var lastPrewarm = Date.distantPast

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Warm the display list *and* the ScreenCaptureKit pipeline in the
    /// background. Without this the first real capture pays ~75 ms of
    /// one-time SCK setup on top of the shot itself.
    func prewarm() {
        // menuWillOpen calls this on every status-menu open — a fresh SCK
        // enumeration + screenshot each time is wasted daemon work when the
        // pipeline was warmed seconds ago
        guard Date().timeIntervalSince(lastPrewarm) > 60 else { return }
        lastPrewarm = Date()
        Task { @MainActor in
            guard let content = try? await shareableContent(maxAge: 60),
                  let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 32
            config.height = 32
            config.showsCursor = false
            let t = Date()
            _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            Perf.log("prewarm capture", since: t)
        }
    }

    func invalidateContentCache() {
        cachedContent = nil
        lastPrewarm = .distantPast // display changed — allow an immediate re-warm
    }

    /// - Parameter maxAge: how stale a cached snapshot may be. Display capture
    ///   tolerates a long age; window capture/picking always refreshes.
    func shareableContent(maxAge: TimeInterval = 0) async throws -> SCShareableContent {
        if maxAge > 0, let c = cachedContent, Date().timeIntervalSince(cachedAt) < maxAge {
            return c
        }
        let t = Date()
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedContent = c
            cachedAt = Date()
            Perf.log("shareableContent", since: t)
            return c
        } catch {
            throw CaptureError.permission
        }
    }

    /// Screenshot of one full display, at native pixel resolution.
    /// `excludingOwnWindows` hides Snippr's overlays (scrolling border, HUDs)
    /// from the capture so they never leak into stitched output.
    func captureDisplay(
        screen: NSScreen, excludingOwnWindows: Bool = false,
        contentMaxAge: TimeInterval? = nil
    ) async throws -> CapturedImage {
        // window list only matters when excluding our own windows; scrolling
        // sessions pass a long contentMaxAge because their chrome is static
        let content = try await shareableContent(
            maxAge: contentMaxAge ?? (excludingOwnWindows ? 0.3 : 120))
        let id = Self.displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let scale = screen.backingScaleFactor
        let myPID = NSRunningApplication.current.processIdentifier
        let excluded = excludingOwnWindows
            ? content.windows.filter { $0.owningApplication?.processID == myPID }
            : []
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        let t = Date()
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        Perf.log("captureImage", since: t)
        return CapturedImage(cgImage: img, scale: scale)
    }

    /// Screenshot of a sub-rectangle of one display (rect in screen-local
    /// points, bottom-left origin), at native pixel resolution. Capturing only
    /// the region keeps scrolling-capture ticks proportional to the selection
    /// instead of rendering the whole display and cropping it.
    func captureRect(
        screen: NSScreen, rect: CGRect,
        excludingOwnWindows: Bool = false, contentMaxAge: TimeInterval? = nil
    ) async throws -> CapturedImage {
        guard let region = CanonicalCaptureRegion(
            screenSize: screen.frame.size, viewRect: rect,
            scale: screen.backingScaleFactor)
        else { throw CaptureError.cancelled }
        return try await captureRect(
            screen: screen, region: region,
            excludingOwnWindows: excludingOwnWindows,
            contentMaxAge: contentMaxAge)
    }

    func captureRect(
        screen: NSScreen, region: CanonicalCaptureRegion,
        excludingOwnWindows: Bool = false, contentMaxAge: TimeInterval? = nil
    ) async throws -> CapturedImage {
        let content = try await shareableContent(
            maxAge: contentMaxAge ?? (excludingOwnWindows ? 0.3 : 120))
        let id = Self.displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let scale = screen.backingScaleFactor
        let myPID = NSRunningApplication.current.processIdentifier
        let excluded = excludingOwnWindows
            ? content.windows.filter { $0.owningApplication?.processID == myPID }
            : []
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = region.pixelWidth
        config.height = region.pixelHeight
        config.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(cgImage: img, scale: scale)
    }

    /// Same capture as `captureRect`, plus same-frame ScreenCaptureKit metadata
    /// used by scrolling capture to reject a success response for the wrong
    /// display region on affected scaled-display/macOS combinations.
    func captureRectValidated(
        screen: NSScreen, rect: CGRect,
        excludingOwnWindows: Bool = false, contentMaxAge: TimeInterval? = nil
    ) async throws -> ValidatedRectCapture {
        guard let region = CanonicalCaptureRegion(
            screenSize: screen.frame.size, viewRect: rect,
            scale: screen.backingScaleFactor)
        else { throw CaptureError.cancelled }
        return try await captureRectValidated(
            screen: screen, region: region,
            excludingOwnWindows: excludingOwnWindows,
            contentMaxAge: contentMaxAge)
    }

    func captureRectValidated(
        screen: NSScreen, region: CanonicalCaptureRegion,
        excludingOwnWindows: Bool = false, contentMaxAge: TimeInterval? = nil
    ) async throws -> ValidatedRectCapture {
        let content = try await shareableContent(
            maxAge: contentMaxAge ?? (excludingOwnWindows ? 0.3 : 120))
        let id = Self.displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let scale = screen.backingScaleFactor
        let myPID = NSRunningApplication.current.processIdentifier
        let excluded = excludingOwnWindows
            ? content.windows.filter { $0.owningApplication?.processID == myPID }
            : []
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = region.pixelWidth
        config.height = region.pixelHeight
        config.showsCursor = false

        let sample = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter, configuration: config)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
              let image = screenshotContext.createCGImage(
                CIImage(cvPixelBuffer: pixelBuffer),
                from: CGRect(x: 0, y: 0,
                             width: CVPixelBufferGetWidth(pixelBuffer),
                             height: CVPixelBufferGetHeight(pixelBuffer)))
        else { throw CaptureError.cancelled }

        var screenRect: CGRect?
        if let raw = CMSampleBufferGetSampleAttachmentsArray(
               sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let first = raw.first {
            if let value = first[.screenRect] as? NSValue {
                screenRect = value.rectValue
            } else if let dict = first[.screenRect] as? NSDictionary {
                screenRect = CGRect(dictionaryRepresentation: dict)
            }
        }
        let requestedScreenRect = ValidatedRectCapture.requestedScreenRect(
            displayFrame: display.frame, sourceRect: config.sourceRect)
        return ValidatedRectCapture(
            image: CapturedImage(cgImage: image, scale: scale),
            screenRect: screenRect,
            requestedScreenRect: requestedScreenRect)
    }

    /// Validated fast-path used on every scrolling tick. Keeping both the
    /// startup frame and later frames on captureSampleBuffer also avoids mixing
    /// subtly different captureImage/CI rasterization paths in one stitcher.
    func captureVerifiedRect(
        screen: NSScreen, rect: CGRect,
        excludingOwnWindows: Bool = false, contentMaxAge: TimeInterval? = nil
    ) async throws -> CapturedImage {
        guard let region = CanonicalCaptureRegion(
            screenSize: screen.frame.size, viewRect: rect,
            scale: screen.backingScaleFactor)
        else { throw CaptureError.cancelled }
        return try await captureVerifiedRect(
            screen: screen, region: region,
            excludingOwnWindows: excludingOwnWindows,
            contentMaxAge: contentMaxAge)
    }

    func captureVerifiedRect(
        screen: NSScreen, region: CanonicalCaptureRegion,
        excludingOwnWindows: Bool = false, contentMaxAge: TimeInterval? = nil
    ) async throws -> CapturedImage {
        let capture = try await captureRectValidated(
            screen: screen, region: region,
            excludingOwnWindows: excludingOwnWindows,
            contentMaxAge: contentMaxAge)
        guard capture.containsRequestedRegion else { throw CaptureError.wrongRegion }
        return capture.image
    }

    static func sourceRect(screen: NSScreen, rect: CGRect) -> CGRect {
        CanonicalCaptureRegion(
            screenSize: screen.frame.size, viewRect: rect,
            scale: screen.backingScaleFactor)?.sourceRect ?? .zero
    }

    /// Screenshot of a single window (no shadow), at native pixel resolution.
    func captureWindow(windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await shareableContent()
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noWindow
        }
        let screen = Self.screenContaining(cgRect: scWindow.frame) ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(cgImage: img, scale: scale)
    }

    /// On-screen windows, front-to-back, excluding our own and non-normal layers.
    static func onScreenWindows() -> [WindowInfo] {
        let myPID = NSRunningApplication.current.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var result: [WindowInfo] = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            let frame = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            guard frame.width >= 60, frame.height >= 40 else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.05 else { continue }
            result.append(WindowInfo(
                windowID: windowID,
                frameCG: frame,
                title: entry[kCGWindowName as String] as? String ?? "",
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                pid: pid
            ))
        }
        return result
    }

    static func frontmostWindow() -> WindowInfo? {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = onScreenWindows()
        if let frontPID, let w = windows.first(where: { $0.pid == frontPID }) { return w }
        return windows.first
    }

    static func screenContaining(cgRect: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
        let appkitRect = CGRect(
            x: cgRect.minX, y: primaryHeight - cgRect.maxY,
            width: cgRect.width, height: cgRect.height
        )
        return NSScreen.screens.max(by: {
            $0.frame.intersection(appkitRect).area < $1.frame.intersection(appkitRect).area
        })
    }

    // MARK: - Window shot composition (background styles)

    /// Compose a window capture with the user's chosen background, Shottr-style.
    nonisolated static func composeWindowShot(_ shot: CapturedImage, style: WindowBGStyle, screen: NSScreen?) -> CapturedImage {
        guard style != .trimShadow else { return shot }

        let scale = shot.scale
        let padPt: CGFloat = 48
        let pad = padPt * scale
        let w = CGFloat(shot.cgImage.width) + pad * 2
        let h = CGFloat(shot.cgImage.height) + pad * 2

        guard let ctx = CGContext(
            data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return shot }

        let full = CGRect(x: 0, y: 0, width: w, height: h)

        switch style {
        case .wallpaper:
            var painted = false
            if let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let wallpaper = NSImage(contentsOf: url),
               let wcg = wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // scale to fill
                let ratio = max(w / CGFloat(wcg.width), h / CGFloat(wcg.height))
                let dw = CGFloat(wcg.width) * ratio
                let dh = CGFloat(wcg.height) * ratio
                ctx.draw(wcg, in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
                painted = true
            }
            if !painted {
                ctx.setFillColor(NSColor.systemIndigo.cgColor)
                ctx.fill(full)
            }
        case .solid:
            ctx.setFillColor(Settings.shared.windowBGColor.cgColor)
            ctx.fill(full)
        case .transparent, .trimShadow:
            break // transparent canvas
        }

        // window with soft drop shadow
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -8 * scale),
            blur: 24 * scale,
            color: NSColor.black.withAlphaComponent(0.45).cgColor
        )
        ctx.draw(shot.cgImage, in: CGRect(
            x: pad, y: pad,
            width: CGFloat(shot.cgImage.width), height: CGFloat(shot.cgImage.height)
        ))
        ctx.restoreGState()

        guard let out = ctx.makeImage() else { return shot }
        return CapturedImage(cgImage: out, scale: scale)
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// Test spy: the live-preview refresh path must never copy pixel buffers.
/// Self-tests snapshot these counters around preview calls. Lock-protected:
/// `materialized()` also runs off the main actor in production, and an
/// unsynchronized read-modify-write would be a data race (the lock costs
/// nothing next to the pixel copy it counts).
enum MaterializeSpy {
    private static let state = OSAllocatedUnfairLock(initialState: 0)
    static var count: Int { state.withLock { $0 } }
    static func increment() { state.withLock { $0 += 1 } }
}

/// Test spy counting SOURCE-width canvas allocations (the separator raster).
/// After the per-session cache is warm, a preview refresh must not create
/// another one.
enum SourceCanvasSpy {
    private static let state = OSAllocatedUnfairLock(initialState: 0)
    static var count: Int { state.withLock { $0 } }
    static func increment() { state.withLock { $0 += 1 } }
}

/// Test spy counting full-strip composes GLOBALLY (across all stitcher
/// instances, unlike the per-instance counter that moves away with a
/// completed segment). A promotion must compose exactly the OLD segment —
/// never the pending/new one.
enum FullComposeSpy {
    private static let state = OSAllocatedUnfairLock(initialState: 0)
    static var count: Int { state.withLock { $0 } }
    static func increment() { state.withLock { $0 += 1 } }
}

extension CGImage {
    /// Redraws this image into its own exactly-sized buffer. Crops made with
    /// `CGImage.cropping(to:)` share the parent's backing store; copying breaks
    /// that tie so the (potentially huge) parent can be released.
    ///
    /// The copy keeps the source's RGB color space — forcing sRGB here would
    /// clamp Display P3 screenshots and visibly desaturate area shots.
    func materialized() -> CGImage? {
        MaterializeSpy.increment()
        let space = (colorSpace?.model == .rgb ? colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// Opens System Settings at the Screen Recording privacy pane.
func openScreenRecordingSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    NSWorkspace.shared.open(url)
}

func openAccessibilitySettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
}
