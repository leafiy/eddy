import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CompressionError: LocalizedError {
    case unreadableFile
    case unknownFormat
    case encodingUnsupported(String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile:                 return "cannot read file"
        case .unknownFormat:                  return "not a recognized image"
        case .encodingUnsupported(let hint):  return hint
        case .encodeFailed:                   return "re-encoding failed"
        }
    }
}

struct CompressionOutcome {
    let originalBytes: Int
    let finalBytes: Int
    /// false when the re-encoded file was not smaller and the original was kept.
    let replaced: Bool
}

/// Per-format pipeline, same engines ImageOptim uses:
///   PNG   pngquant (lossy quantization, quality slider) + oxipng/optipng (lossless)
///   JPEG  jpegoptim (--max quality, strips all metadata, progressive)
///   GIF   gifsicle -O3 (animations preserved)
///   WebP  bundled libwebp (in-process, no external binary needed)
///   AVIF  avifenc (via ImageIO decode)
///   BMP/TIFF/HEIC and any missing tool: ImageIO re-encode fallback.
/// Every path strips EXIF/GPS/XMP/orientation metadata, never resizes pixels,
/// and only overwrites the original when the result is smaller.
enum Compressor {

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "bmp", "webp", "avif",
        "tif", "tiff", "heic", "heif",
    ]

    static func optimize(fileURL: URL, quality: Double) throws -> CompressionOutcome {
        guard let originalSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              originalSize > 0
        else { throw CompressionError.unreadableFile }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("eddy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let candidate = try recompress(fileURL: fileURL, quality: quality, tempDir: tempDir)
        let newSize = fileSize(candidate)
        guard newSize > 0, newSize < originalSize else {
            return CompressionOutcome(originalBytes: originalSize, finalBytes: originalSize, replaced: false)
        }

        // Stage next to the original so the final swap is atomic on the same volume.
        let staging = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".eddy-\(UUID().uuidString).tmp")
        try fm.moveItem(at: candidate, to: staging)
        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return CompressionOutcome(originalBytes: originalSize, finalBytes: newSize, replaced: true)
    }

    // MARK: - Format dispatch

    private static func recompress(fileURL: URL, quality: Double, tempDir: URL) throws -> URL {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": return try recompressJPEG(fileURL, quality, tempDir)
        case "png":                return try recompressPNG(fileURL, quality, tempDir)
        case "gif":                return try recompressGIF(fileURL, tempDir)
        case "webp":               return try recompressWebP(fileURL, quality, tempDir)
        case "avif":               return try recompressAVIF(fileURL, quality, tempDir)
        default:                   return try imageIOReencode(fileURL, quality, tempDir)
        }
    }

    private static func recompressJPEG(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        guard let jpegoptim = Tools.jpegoptim else {
            return try imageIOReencode(fileURL, quality, tempDir)
        }
        let work = tempDir.appendingPathComponent("work.jpg")
        if sourceOrientation(of: fileURL) != 1 {
            // Bake the rotation into pixels first; ImageIO also strips metadata here.
            _ = try imageIOReencode(fileURL, quality, tempDir, to: work)
        } else {
            try FileManager.default.copyItem(at: fileURL, to: work)
        }
        // Re-encodes only when the estimated quality exceeds --max; always strips
        // EXIF/IPTC/XMP/ICC; progressive scan order like ImageOptim.
        try Tools.run(jpegoptim, [
            "--max=\(percent(quality))",
            "--strip-all",
            "--all-progressive",
            "--quiet",
            work.path,
        ])
        return work
    }

    private static func recompressPNG(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        let fm = FileManager.default
        var current = tempDir.appendingPathComponent("work.png")
        try fm.copyItem(at: fileURL, to: current)
        var usedExternalTool = false

        if let pngquant = Tools.pngquant {
            let quantized = tempDir.appendingPathComponent("quant.png")
            let qMax = percent(quality)
            let qMin = max(0, qMax - 25)
            // 98 = result would be larger, 99 = can't reach requested quality;
            // both mean "keep the un-quantized file", not failure.
            let status = try Tools.run(pngquant, [
                "--force", "--skip-if-larger", "--strip", "--speed", "1",
                "--quality", "\(qMin)-\(qMax)",
                "--output", quantized.path,
                "--", current.path,
            ], allowedExitCodes: [0, 98, 99])
            if status == 0 { current = quantized }
            usedExternalTool = true
        }

        if let oxipng = Tools.oxipng {
            try Tools.run(oxipng, ["-o", "3", "--strip", "all", "--quiet", current.path])
            usedExternalTool = true
        } else if let optipng = Tools.optipng {
            try Tools.run(optipng, ["-o2", "-strip", "all", "-quiet", current.path])
            usedExternalTool = true
        }

        return usedExternalTool ? current : try imageIOReencode(fileURL, quality, tempDir)
    }

    private static func recompressGIF(_ fileURL: URL, _ tempDir: URL) throws -> URL {
        guard let gifsicle = Tools.gifsicle else {
            return try imageIOReencode(fileURL, 1.0, tempDir)
        }
        let work = tempDir.appendingPathComponent("work.gif")
        try FileManager.default.copyItem(at: fileURL, to: work)
        try Tools.run(gifsicle, ["-O3", "--no-comments", "--no-names", "-b", work.path])
        return work
    }

    private static func recompressWebP(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        guard frameCount(of: fileURL) <= 1 else {
            throw CompressionError.encodingUnsupported("animated WebP is not supported")
        }
        // Decode with orientation baked in, encode with the bundled libwebp;
        // no metadata is carried over.
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let frame = renderedFrame(source: source, index: 0)
        else { throw CompressionError.unknownFormat }
        let encoded = try WebPEncoder.encode(frame, quality: quality)
        let output = tempDir.appendingPathComponent("out.webp")
        try encoded.write(to: output)
        return output
    }

    private static func recompressAVIF(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        guard let avifenc = Tools.avifenc else {
            throw CompressionError.encodingUnsupported("AVIF needs avifenc — run: brew install libavif")
        }
        let decoded = try imageIODecodeToPNG(fileURL, tempDir)
        let output = tempDir.appendingPathComponent("out.avif")
        try Tools.run(avifenc, [
            "-s", "6", "-q", "\(percent(quality))",
            "--ignore-exif", "--ignore-xmp",
            decoded.path, output.path,
        ])
        return output
    }

    // MARK: - ImageIO fallback encoder

    private static func imageIOReencode(
        _ fileURL: URL,
        _ quality: Double,
        _ tempDir: URL,
        to explicitOutput: URL? = nil
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(
                  fileURL as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(source)
        else { throw CompressionError.unknownFormat }

        let ext = fileURL.pathExtension.lowercased()
        let output = explicitOutput ?? tempDir.appendingPathComponent("imageio.\(ext)")
        let frameCount = max(CGImageSourceGetCount(source), 1)
        let type = UTType(typeID as String)
        let isLossy = type?.conforms(to: .jpeg) == true
            || type?.conforms(to: .webP) == true
            || type?.conforms(to: .heic) == true
            || type?.conforms(to: .heif) == true
        let isGIF = type?.conforms(to: .gif) == true

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, typeID, frameCount, nil)
        else { throw CompressionError.encodingUnsupported(encoderHint(for: ext)) }

        if isGIF,
           let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gifProps = containerProps[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loopCount = gifProps[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
            )
        }

        for index in 0..<frameCount {
            guard let frame = renderedFrame(source: source, index: index) else {
                throw CompressionError.encodeFailed
            }
            var properties: [CFString: Any] = [:]
            if isLossy {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            if isGIF {
                let delay = frameDelay(source: source, index: index)
                properties[kCGImagePropertyGIFDictionary] = [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            }
            // Only the properties above are written; all source metadata is dropped.
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.encodeFailed
        }
        return output
    }

    private static func encoderHint(for ext: String) -> String {
        switch ext {
        case "avif": return "AVIF encoder missing — run: brew install libavif"
        default:     return "no encoder available for .\(ext) on this macOS"
        }
    }

    /// Decodes frame 0 to a temp PNG with orientation baked in and zero metadata.
    /// Used as the hand-off format for avifenc.
    private static func imageIODecodeToPNG(_ fileURL: URL, _ tempDir: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let frame = renderedFrame(source: source, index: 0)
        else { throw CompressionError.unknownFormat }
        let output = tempDir.appendingPathComponent("decoded.png")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CompressionError.encodeFailed }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.encodeFailed
        }
        return output
    }

    // MARK: - ImageIO helpers

    /// Full-resolution frame with EXIF orientation baked into the pixels.
    private static func renderedFrame(source: CGImageSource, index: Int) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation == 1 {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,        // applies orientation
            kCGImageSourceThumbnailMaxPixelSize: max(width, height), // full size, never upscaled
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let delay = unclamped ?? clamped ?? 0.1
        return delay > 0 ? delay : 0.1
    }

    private static func sourceOrientation(of fileURL: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 1 }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    private static func frameCount(of fileURL: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return 1 }
        return max(CGImageSourceGetCount(source), 1)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func percent(_ quality: Double) -> Int {
        max(1, min(100, Int((quality * 100).rounded())))
    }

    /// Small preview for the list row.
    static func thumbnail(for fileURL: URL, maxPixelSize: Int = 96) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
