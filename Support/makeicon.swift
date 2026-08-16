// Generates and verifies every Snippr icon from Support/icon-1024.png.
//
// Usage from the repository root:
//   swift Support/makeicon.swift --generate
//   swift Support/makeicon.swift --check

// The approved master is intentionally pinned so a preview image or an old
// icon cannot silently become a release asset.

import AppKit
import CryptoKit
import Foundation

private let approvedMasterSHA256 = "c6e6e20df44db307d88b5037b911f4cd5a112daee173a767bc9966560635f106"
private let masterRelativePath = "Support/icon-1024.png"

private enum IconError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidMaster(String)
    case missingFile(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .invalidArgument(let value): return "invalid argument: \(value)"
        case .invalidMaster(let value): return "invalid master: \(value)"
        case .missingFile(let value): return "missing file: \(value)"
        case .mismatch(let value): return "asset mismatch: \(value)"
        }
    }
}

private struct GeneratedAsset {
    let relativePath: String
    let data: Data
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func loadImage(_ data: Data) throws -> CGImage {
    guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else {
        throw IconError.invalidMaster("not a readable PNG")
    }
    return image
}

private func validateMaster(_ image: CGImage, data: Data) throws {
    let digest = sha256Hex(data)
    guard digest == approvedMasterSHA256 else {
        throw IconError.invalidMaster("SHA-256 \(digest), expected \(approvedMasterSHA256)")
    }
    guard image.width == 1024, image.height == 1024 else {
        throw IconError.invalidMaster("expected 1024x1024, got \(image.width)x\(image.height)")
    }

    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.invalidMaster("cannot allocate alpha-check context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var transparentCount = 0
    var partialCount = 0
    for offset in stride(from: 3, to: pixels.count, by: 4) {
        switch pixels[offset] {
        case 0: transparentCount += 1
        case 255: break
        default: partialCount += 1
        }
    }
    guard transparentCount >= width * height / 4, partialCount >= 1_000 else {
        throw IconError.invalidMaster("expected a transparent surround and antialiased edges")
    }

    let cornerOffsets = [
        3,
        (width - 1) * 4 + 3,
        ((height - 1) * width) * 4 + 3,
        (width * height - 1) * 4 + 3,
    ]
    guard cornerOffsets.allSatisfy({ pixels[$0] == 0 }) else {
        throw IconError.invalidMaster("all four corners must be transparent")
    }
    let clearBorder = 32
    for y in 0..<height {
        for x in 0..<width where x < clearBorder || x >= width - clearBorder || y < clearBorder || y >= height - clearBorder {
            let alpha = pixels[(y * width + x) * 4 + 3]
            guard alpha == 0 else {
                throw IconError.invalidMaster("outer \(clearBorder)-pixel border must be fully transparent")
            }
        }
    }
}

private func pngData(from image: CGImage, size: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.invalidMaster("cannot allocate \(size)x\(size) render context")
    }
    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let rendered = context.makeImage() else {
        throw IconError.invalidMaster("cannot render \(size)x\(size) image")
    }
    let rep = NSBitmapImageRep(cgImage: rendered)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw IconError.invalidMaster("cannot encode \(size)x\(size) PNG")
    }
    return data
}

private func fourCC(_ value: String) -> UInt32 {
    value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func makeICNS(pngBySize: [Int: Data]) throws -> Data {
    let representations: [(String, Int)] = [
        ("icp4", 16),
        ("icp5", 32),
        ("icp6", 64),
        ("ic07", 128),
        ("ic08", 256),
        ("ic09", 512),
        ("ic10", 1024),
        ("ic11", 32),
        ("ic12", 64),
        ("ic13", 256),
        ("ic14", 512),
    ]
    var chunks = Data()
    for (type, size) in representations {
        guard let png = pngBySize[size] else {
            throw IconError.missingFile("generated \(size)x\(size) PNG")
        }
        chunks.appendUInt32BE(fourCC(type))
        chunks.appendUInt32BE(UInt32(png.count + 8))
        chunks.append(png)
    }
    var result = Data()
    result.appendUInt32BE(fourCC("icns"))
    result.appendUInt32BE(UInt32(chunks.count + 8))
    result.append(chunks)
    return result
}

private func validateICNSConsumer(_ data: Data) throws {
    guard let image = NSImage(data: data) else {
        throw IconError.invalidMaster("AppKit cannot decode generated ICNS")
    }
    let actual = image.representations.map { representation in
        "\(representation.pixelsWide)x\(Int(representation.size.width.rounded()))"
    }.sorted()
    let expected = [
        "16x16", "32x16", "32x32", "64x32", "64x64", "128x128",
        "256x128", "256x256", "512x256", "512x512", "1024x512",
    ].sorted()
    guard actual == expected else {
        throw IconError.invalidMaster("AppKit ICNS representations \(actual), expected \(expected)")
    }
}

private func makeICO(pngBySize: [Int: Data]) throws -> Data {
    let sizes = [16, 24, 32, 48, 64, 128, 256]
    var payloads: [Data] = []
    for size in sizes {
        guard let png = pngBySize[size] else {
            throw IconError.missingFile("generated \(size)x\(size) PNG")
        }
        payloads.append(png)
    }

    var result = Data()
    result.appendUInt16LE(0)
    result.appendUInt16LE(1)
    result.appendUInt16LE(UInt16(sizes.count))

    var offset = 6 + sizes.count * 16
    for (index, size) in sizes.enumerated() {
        result.append(UInt8(size == 256 ? 0 : size))
        result.append(UInt8(size == 256 ? 0 : size))
        result.append(0)
        result.append(0)
        result.appendUInt16LE(1)
        result.appendUInt16LE(32)
        result.appendUInt32LE(UInt32(payloads[index].count))
        result.appendUInt32LE(UInt32(offset))
        offset += payloads[index].count
    }
    for payload in payloads {
        result.append(payload)
    }
    return result
}

private func generatedAssets(masterData: Data, masterImage: CGImage) throws -> [GeneratedAsset] {
    let requiredSizes = [16, 24, 32, 48, 64, 128, 256, 512, 1024]
    var pngBySize: [Int: Data] = [:]
    for size in requiredSizes {
        pngBySize[size] = size == 1024 ? masterData : try pngData(from: masterImage, size: size)
    }

    let iconset: [(String, Int)] = [
        ("Support/AppIcon.iconset/icon_16x16.png", 16),
        ("Support/AppIcon.iconset/icon_16x16@2x.png", 32),
        ("Support/AppIcon.iconset/icon_32x32.png", 32),
        ("Support/AppIcon.iconset/icon_32x32@2x.png", 64),
        ("Support/AppIcon.iconset/icon_64x64.png", 64),
        ("Support/AppIcon.iconset/icon_64x64@2x.png", 128),
        ("Support/AppIcon.iconset/icon_128x128.png", 128),
        ("Support/AppIcon.iconset/icon_128x128@2x.png", 256),
        ("Support/AppIcon.iconset/icon_256x256.png", 256),
        ("Support/AppIcon.iconset/icon_256x256@2x.png", 512),
        ("Support/AppIcon.iconset/icon_512x512.png", 512),
        ("Support/AppIcon.iconset/icon_512x512@2x.png", 1024),
    ]

    var assets = try iconset.map { path, size -> GeneratedAsset in
        guard let data = pngBySize[size] else { throw IconError.missingFile("generated \(size)x\(size) PNG") }
        return GeneratedAsset(relativePath: path, data: data)
    }
    guard let png256 = pngBySize[256] else { throw IconError.missingFile("generated 256x256 PNG") }
    let icns = try makeICNS(pngBySize: pngBySize)
    try validateICNSConsumer(icns)
    assets.append(GeneratedAsset(relativePath: "Support/AppIcon.icns", data: icns))
    assets.append(GeneratedAsset(relativePath: "windows/snippr.ico", data: try makeICO(pngBySize: pngBySize)))
    assets.append(GeneratedAsset(relativePath: "site/icon.png", data: png256))
    assets.append(GeneratedAsset(relativePath: "docs/icon-256.png", data: png256))
    return assets
}

private func write(_ assets: [GeneratedAsset], under root: URL) throws {
    let fileManager = FileManager.default
    for asset in assets {
        let url = root.appendingPathComponent(asset.relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try asset.data.write(to: url, options: .atomic)
        print("wrote \(asset.relativePath)")
    }
}

private func check(_ assets: [GeneratedAsset], under root: URL) throws {
    for asset in assets {
        let url = root.appendingPathComponent(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IconError.missingFile(asset.relativePath)
        }
        let actual = try Data(contentsOf: url)
        guard actual == asset.data else {
            throw IconError.mismatch("\(asset.relativePath) (expected \(sha256Hex(asset.data)), got \(sha256Hex(actual)))")
        }
        print("PASS \(asset.relativePath)")
    }
}

do {
    let mode = CommandLine.arguments.dropFirst().first ?? "--check"
    guard mode == "--check" || mode == "--generate" else {
        throw IconError.invalidArgument(mode)
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let masterURL = root.appendingPathComponent(masterRelativePath)
    guard FileManager.default.fileExists(atPath: masterURL.path) else {
        throw IconError.missingFile(masterRelativePath)
    }
    let masterData = try Data(contentsOf: masterURL)
    let masterImage = try loadImage(masterData)
    try validateMaster(masterImage, data: masterData)
    let assets = try generatedAssets(masterData: masterData, masterImage: masterImage)

    if mode == "--generate" {
        try write(assets, under: root)
        print("GENERATED \(assets.count) icon assets from approved master \(approvedMasterSHA256)")
    } else {
        try check(assets, under: root)
        print("ALL ICON ASSETS PASSED")
    }
} catch {
    FileHandle.standardError.write(Data("FAIL icon-assets: \(error)\n".utf8))
    exit(1)
}
