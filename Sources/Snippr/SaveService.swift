import AppKit
import UniformTypeIdentifiers

enum ImageFileFormat {
    case png, jpeg
}

final class SaveService {
    static let shared = SaveService()

    /// Decide PNG vs JPEG for "Auto" mode: photos → JPEG, UI/flat graphics → PNG.
    static func decideFormat(for image: CGImage) -> ImageFileFormat {
        if Settings.shared.saveFormat == .png { return .png }
        if image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst {
            // has real alpha? keep PNG if any transparent pixel exists — cheap check on downsample
            if hasTransparency(image) { return .png }
        }
        return isPhotoLike(image) ? .jpeg : .png
    }

    private static func downsample(_ image: CGImage, to side: Int) -> [UInt8]? {
        let w = side, h = side
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func hasTransparency(_ image: CGImage) -> Bool {
        guard let buf = downsample(image, to: 32) else { return false }
        var i = 3
        while i < buf.count {
            if buf[i] < 250 { return true }
            i += 4
        }
        return false
    }

    private static func isPhotoLike(_ image: CGImage) -> Bool {
        guard let buf = downsample(image, to: 64) else { return false }
        var colors = Set<UInt16>()
        var i = 0
        while i < buf.count {
            let r = UInt16(buf[i] >> 4), g = UInt16(buf[i + 1] >> 4), b = UInt16(buf[i + 2] >> 4)
            colors.insert(r << 8 | g << 4 | b)
            i += 4
        }
        return colors.count > 1100
    }

    static func data(for image: CGImage, format: ImageFileFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    /// Save to the configured screenshots folder. Returns the file URL.
    @discardableResult
    func save(_ image: CapturedImage) -> URL? {
        var img = image
        if Settings.shared.downscaleRetina {
            img = img.downscaledTo1x()
        }
        let format = Self.decideFormat(for: img.cgImage)
        guard let data = Self.data(for: img.cgImage, format: format) else { return nil }

        let folder = Settings.shared.screenshotsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = format == .png ? "png" : "jpg"
        var url = folder.appendingPathComponent("Snippr \(df.string(from: Date())).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Snippr \(df.string(from: Date())) (\(counter)).\(ext)")
            counter += 1
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("Snippr: save failed: \(error)")
            return nil
        }
    }

    func copyToClipboard(_ image: CapturedImage) {
        var img = image
        if Settings.shared.downscaleRetina {
            img = img.downscaledTo1x()
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = Self.data(for: img.cgImage, format: .png) {
            pb.setData(png, forType: .png)
        }
        pb.writeObjects([img.nsImage])
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
