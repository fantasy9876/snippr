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

    private static let fileNameFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return df
    }()

    static func suggestedFileName(ext: String) -> String {
        "Snippr \(fileNameFormatter.string(from: Date())).\(ext)"
    }

    /// Saves still in flight — the app must not terminate under them, or the
    /// user's screenshot silently vanishes (or lands truncated) mid-write.
    @MainActor private(set) static var inFlightSaves = 0

    /// For background writes that don't go through save() (the editor's
    /// Save-As panel) so they too block termination until finished.
    @MainActor static func beginBackgroundWrite() { inFlightSaves += 1 }
    @MainActor static func endBackgroundWrite() {
        inFlightSaves -= 1
        if inFlightSaves == 0, let drained = onSavesDrained {
            onSavesDrained = nil
            drained()
        }
    }
    /// One-shot hook fired when the last in-flight save lands; used by
    /// applicationShouldTerminate to delay quitting until writes finish.
    @MainActor static var onSavesDrained: (() -> Void)?

    /// Name-pick + write are serialized so two saves in the same second can't
    /// race the exists-check and overwrite each other's file.
    private static let ioQueue = DispatchQueue(label: "com.manhhoang.snippr.save-io", qos: .userInitiated)

    /// Save to the configured screenshots folder. Encoding + file I/O run off
    /// the main thread (a 5K PNG encode is 1–2.5 s — it used to beachball the
    /// UI on every save); `completion` is called on the main actor with the
    /// file URL, or nil on failure.
    @MainActor
    func save(_ image: CapturedImage, completion: @escaping @MainActor (URL?) -> Void = { _ in }) {
        let downscale = Settings.shared.downscaleRetina
        let folder = Settings.shared.screenshotsFolder
        Self.inFlightSaves += 1
        Task.detached(priority: .userInitiated) {
            var img = image
            if downscale { img = img.downscaledTo1x() }
            let format = Self.decideFormat(for: img.cgImage)
            var url: URL?
            if let data = Self.data(for: img.cgImage, format: format) {
                Self.ioQueue.sync {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let ext = format == .png ? "png" : "jpg"
                    let base = Self.suggestedFileName(ext: ext)
                    var candidate = folder.appendingPathComponent(base)
                    var counter = 2
                    while FileManager.default.fileExists(atPath: candidate.path) {
                        let stem = (base as NSString).deletingPathExtension
                        candidate = folder.appendingPathComponent("\(stem) (\(counter)).\(ext)")
                        counter += 1
                    }
                    do {
                        try data.write(to: candidate)
                        url = candidate
                    } catch {
                        NSLog("Snippr: save failed: \(error)")
                    }
                }
            }
            let saved = url
            await MainActor.run {
                Self.inFlightSaves -= 1
                completion(saved)
                if Self.inFlightSaves == 0, let drained = Self.onSavesDrained {
                    Self.onSavesDrained = nil
                    drained()
                }
            }
        }
    }

    /// Provides PNG/TIFF lazily: the pasteboard is claimed instantly and the
    /// expensive encode runs only when a paste actually requests the data.
    /// ONE pasteboard item carries both representations — the old code wrote
    /// two items (setData + writeObjects), which pasted the screenshot twice
    /// in multi-item-aware apps like Notes.
    private final class ImagePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
        private let image: CapturedImage
        private let downscale: Bool

        init(image: CapturedImage, downscale: Bool) {
            self.image = image
            self.downscale = downscale
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            var img = image
            if downscale { img = img.downscaledTo1x() }
            let rep = NSBitmapImageRep(cgImage: img.cgImage)
            let data: Data?
            switch type {
            case .png: data = rep.representation(using: .png, properties: [:])
            case .tiff: data = rep.representation(using: .tiff, properties: [:])
            default: data = nil
            }
            if let data {
                item.setData(data, forType: type)
            }
        }
    }

    func copyToClipboard(_ image: CapturedImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        let provider = ImagePasteboardProvider(
            image: image, downscale: Settings.shared.downscaleRetina)
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pb.writeObjects([item])
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
