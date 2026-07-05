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

/// Fully self-contained pipeline — every engine is compiled into the app:
///   PNG   bundled libimagequant (pngquant's engine) + own indexed-PNG writer
///   JPEG  ImageIO progressive re-encode AND lossless metadata strip; smaller wins
///   WebP  bundled libwebp
///   AVIF  bundled libavif + libaom
///   GIF/BMP/TIFF/HEIC  ImageIO re-encode
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
        case "webp":               return try recompressWebP(fileURL, quality, tempDir)
        case "avif":               return try recompressAVIF(fileURL, quality, tempDir)
        default:                   return try imageIOReencode(fileURL, quality, tempDir)
        }
    }

    /// pngquant-style lossy quantization; keep-if-smaller upstream guards the
    /// rare case where an already tiny palette PNG doesn't benefit.
    private static func recompressPNG(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        let frame = try decodedFrame(fileURL)
        let encoded = try PNGCoder.quantizedPNG(from: frame, quality: quality)
        let output = tempDir.appendingPathComponent("out.png")
        try encoded.write(to: output)
        return output
    }

    /// Two candidates, smaller wins:
    /// 1. lossy: ImageIO progressive re-encode at the quality slider
    ///    (also bakes orientation and strips metadata)
    /// 2. lossless: byte-level metadata strip, image data untouched
    ///    (only when there is no orientation to bake)
    private static func recompressJPEG(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        var best: URL? = try? imageIOReencode(fileURL, quality, tempDir)

        if sourceOrientation(of: fileURL) == 1,
           let original = try? Data(contentsOf: fileURL),
           let strippedData = JPEGStripper.stripped(original) {
            let strippedURL = tempDir.appendingPathComponent("stripped.jpg")
            if (try? strippedData.write(to: strippedURL)) != nil {
                if let current = best {
                    if fileSize(strippedURL) < fileSize(current) { best = strippedURL }
                } else {
                    best = strippedURL
                }
            }
        }

        guard let best else { throw CompressionError.encodeFailed }
        return best
    }

    private static func recompressWebP(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        guard frameCount(of: fileURL) <= 1 else {
            throw CompressionError.encodingUnsupported("animated WebP is not supported")
        }
        let encoded = try WebPEncoder.encode(try decodedFrame(fileURL), quality: quality)
        let output = tempDir.appendingPathComponent("out.webp")
        try encoded.write(to: output)
        return output
    }

    private static func recompressAVIF(_ fileURL: URL, _ quality: Double, _ tempDir: URL) throws -> URL {
        let encoded = try AVIFEncoder.encode(try decodedFrame(fileURL), quality: quality)
        let output = tempDir.appendingPathComponent("out.avif")
        try encoded.write(to: output)
        return output
    }

    // MARK: - ImageIO encoder (JPEG lossy candidate, GIF/BMP/TIFF/HEIC)

    private static func imageIOReencode(
        _ fileURL: URL,
        _ quality: Double,
        _ tempDir: URL
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(
                  fileURL as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(source)
        else { throw CompressionError.unknownFormat }

        let ext = fileURL.pathExtension.lowercased()
        let output = tempDir.appendingPathComponent("imageio.\(ext)")
        let frameCount = max(CGImageSourceGetCount(source), 1)
        let type = UTType(typeID as String)
        let isJPEG = type?.conforms(to: .jpeg) == true
        let isLossy = isJPEG
            || type?.conforms(to: .heic) == true
            || type?.conforms(to: .heif) == true
        let isGIF = type?.conforms(to: .gif) == true

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, typeID, frameCount, nil)
        else { throw CompressionError.encodingUnsupported("no encoder available for .\(ext) on this macOS") }

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
            if isJPEG {
                // Progressive scan order is typically a few percent smaller.
                properties[kCGImagePropertyJFIFDictionary] =
                    [kCGImagePropertyJFIFIsProgressive: true]
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

    // MARK: - ImageIO decode helpers

    /// Frame 0 at full resolution with EXIF orientation baked into the pixels.
    private static func decodedFrame(_ fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let frame = renderedFrame(source: source, index: 0)
        else { throw CompressionError.unknownFormat }
        return frame
    }

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
