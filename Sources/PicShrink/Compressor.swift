import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CompressionError: LocalizedError {
    case unreadableFile
    case unknownFormat
    case encodingUnsupported
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile:      return "cannot read file"
        case .unknownFormat:       return "not a recognized image"
        case .encodingUnsupported: return "this macOS cannot re-encode this format"
        case .encodeFailed:        return "re-encoding failed"
        }
    }
}

struct CompressionOutcome {
    let originalBytes: Int
    let finalBytes: Int
    /// false when the re-encoded file was not smaller and the original was kept.
    let replaced: Bool
}

enum Compressor {

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "bmp", "webp",
        "tif", "tiff", "heic", "heif",
    ]

    /// Re-encodes the image in place, keeping the same format and pixel size.
    /// - Bakes EXIF orientation into the pixels, then writes NO metadata at all
    ///   (EXIF, GPS, XMP, orientation are gone).
    /// - Applies lossy `quality` for JPEG / WebP / HEIC; PNG, BMP, GIF, TIFF are
    ///   re-encoded losslessly.
    /// - Overwrites the original file only when the result is smaller.
    static func optimize(fileURL: URL, quality: Double) throws -> CompressionOutcome {
        guard let originalData = try? Data(contentsOf: fileURL) else {
            throw CompressionError.unreadableFile
        }
        guard let source = CGImageSourceCreateWithData(
                  originalData as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(source)
        else {
            throw CompressionError.unknownFormat
        }

        let frameCount = max(CGImageSourceGetCount(source), 1)
        let type = UTType(typeID as String)
        let isLossy = type?.conforms(to: .jpeg) == true
            || type?.conforms(to: .webP) == true
            || type?.conforms(to: .heic) == true
            || type?.conforms(to: .heif) == true
        let isGIF = type?.conforms(to: .gif) == true

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, typeID, frameCount, nil)
        else {
            // e.g. WebP encoding is only available on macOS 14+.
            throw CompressionError.encodingUnsupported
        }

        // Preserve GIF loop count (the only container property worth keeping).
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

        let newData = output as Data
        guard !newData.isEmpty, newData.count < originalData.count else {
            // Re-encoding did not help; keep the original untouched.
            return CompressionOutcome(
                originalBytes: originalData.count,
                finalBytes: originalData.count,
                replaced: false
            )
        }

        // Atomic in-place replace: write next to the original, then swap.
        let tempURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".picshrink-\(UUID().uuidString).tmp")
        try newData.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)

        return CompressionOutcome(
            originalBytes: originalData.count,
            finalBytes: newData.count,
            replaced: true
        )
    }

    /// Full-resolution frame with EXIF orientation baked into the pixels.
    private static func renderedFrame(source: CGImageSource, index: Int) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation == 1 {
            // No rotation needed; decode as-is.
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
