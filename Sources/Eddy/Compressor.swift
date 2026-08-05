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
        case .unreadableFile:                 return L("cannot read file")
        case .unknownFormat:                  return L("not a recognized image")
        case .encodingUnsupported(let hint):  return hint
        case .encodeFailed:                   return L("re-encoding failed")
        }
    }
}

struct CompressionOutcome {
    let originalBytes: Int
    let finalBytes: Int
    /// false when the re-encoded file was not smaller and the original was kept.
    let replaced: Bool
    /// Where the result lives — differs from the input only when a format
    /// conversion changed the file's extension.
    let outputURL: URL
}

/// Output format for processed files. `keep` re-encodes in the original
/// format; `png`/`jpeg` convert files of other formats, replacing the
/// original next to where it lived.
enum SaveFormat: String, CaseIterable, Identifiable, Codable {
    case keep
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return L("Keep original format")
        case .png:  return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    /// File extensions already in this format — no conversion needed.
    fileprivate var extensions: Set<String>? {
        switch self {
        case .keep: return nil
        case .png:  return ["png"]
        case .jpeg: return ["jpg", "jpeg", "jpe"]
        }
    }
}

/// Fully self-contained pipeline — every engine is compiled into the app:
///   PNG   built-in median-cut quantizer (pngquant-style palette PNG)
///   JPEG  ImageIO progressive re-encode AND lossless metadata strip; smaller wins
///   WebP  bundled libwebp + lossless RIFF metadata strip; smaller wins
///   AVIF  bundled libavif + libaom
///   GIF   built-in pure-Swift GIF89a encoder (global palette, frame deltas, LZW)
///   BMP/TIFF/HEIC  ImageIO re-encode
/// Every path strips EXIF/GPS/XMP/orientation metadata and only overwrites the
/// original when the result is smaller. `maxWidth` > 0 downscales to that
/// width (aspect ratio kept, never upscales); 0 keeps the original size.
enum Compressor {

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "bmp", "webp", "avif",
        "tif", "tiff", "heic", "heif",
    ]

    static func optimize(fileURL: URL, quality: Double, maxWidth: Int = 0, format: SaveFormat) throws -> CompressionOutcome {
        // Animated assets (frame count > 1) are conversion-exempt: flattening
        // them to frame 0 and deleting the original would silently destroy
        // the animation. They fall through to in-place recompression instead.
        if let targetExtensions = format.extensions,
           !targetExtensions.contains(fileURL.pathExtension.lowercased()),
           frameCount(of: fileURL) <= 1 {
            return try convert(fileURL: fileURL, to: format, quality: quality, maxWidth: maxWidth)
        }
        guard let originalSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              originalSize > 0
        else { throw CompressionError.unreadableFile }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("eddy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let candidate = try recompress(
            fileURL: fileURL, quality: quality, maxWidth: maxWidth, tempDir: tempDir)
        let newSize = fileSize(candidate)
        guard newSize > 0, newSize < originalSize else {
            return CompressionOutcome(originalBytes: originalSize, finalBytes: originalSize, replaced: false, outputURL: fileURL)
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
        return CompressionOutcome(originalBytes: originalSize, finalBytes: newSize, replaced: true, outputURL: fileURL)
    }

    // MARK: - Format conversion

    /// Converts to `format` next to the original and removes the original —
    /// the conversion counterpart of optimize()'s in-place replace. Unlike
    /// optimize(), sizes are not compared: an explicit format choice wins
    /// even when the result is larger (e.g. JPEG → PNG). A name collision
    /// gets a "-2" style suffix instead of clobbering an unrelated file.
    private static func convert(fileURL: URL, to format: SaveFormat, quality: Double, maxWidth: Int) throws -> CompressionOutcome {
        guard let originalSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              originalSize > 0
        else { throw CompressionError.unreadableFile }

        let frame = try decodedFrame(fileURL, maxWidth: maxWidth)
        let data: Data
        let ext: String
        switch format {
        case .keep:
            throw CompressionError.encodeFailed // unreachable: dispatch handles .keep
        case .png:
            data = try PNGCoder.quantizedPNG(from: frame, quality: quality)
            ext = "png"
        case .jpeg:
            data = try jpegData(from: frame, quality: quality)
            ext = "jpg"
        }

        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let name = counter == 1 ? "\(base).\(ext)" : "\(base)-\(counter).\(ext)"
            counter += 1
            let destination = directory.appendingPathComponent(name)
            do {
                // withoutOverwriting makes concurrent batch items racing for
                // the same name fail over to the next suffix, not clobber.
                try data.write(to: destination, options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            try fm.removeItem(at: fileURL)
            return CompressionOutcome(
                originalBytes: originalSize,
                finalBytes: data.count,
                replaced: true,
                outputURL: destination
            )
        }
    }

    /// JPEG frame encode; progressive like the JPEG re-encode path.
    /// Shared with Cropper, which saves crops back into JPEG files.
    static func jpegData(from image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CompressionError.encodingUnsupported(L("no JPEG encoder available on this macOS")) }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        ]
        CGImageDestinationAddImage(destination, flattenedOpaque(image), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CompressionError.encodeFailed }
        return data as Data
    }

    /// JPEG can't store alpha; transparent sources (typically PNGs) are
    /// flattened onto white instead of whatever the encoder would do.
    static func flattenedOpaque(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    // MARK: - Format dispatch

    private static func recompress(fileURL: URL, quality: Double, maxWidth: Int, tempDir: URL) throws -> URL {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": return try recompressJPEG(fileURL, quality, maxWidth, tempDir)
        case "png":                return try recompressPNG(fileURL, quality, maxWidth, tempDir)
        case "webp":               return try recompressWebP(fileURL, quality, maxWidth, tempDir)
        case "avif":               return try recompressAVIF(fileURL, quality, maxWidth, tempDir)
        case "gif":                return try recompressGIF(fileURL, quality, maxWidth, tempDir)
        default:                   return try imageIOReencode(fileURL, quality, maxWidth, tempDir)
        }
    }

    /// True when `maxWidth` would actually shrink this file — lossless
    /// candidates (which can't resize) are only valid when it wouldn't.
    private static func needsResize(_ fileURL: URL, _ maxWidth: Int) -> Bool {
        if fileURL.pathExtension.lowercased() == "webp",
           let size = AnimatedWebPCoder.canvasSize(fileURL) {
            return maxWidth > 0 && size.width > maxWidth
        }
        return maxWidth > 0 && effectivePixelWidth(of: fileURL) > maxWidth
    }

    /// pngquant-style lossy palette quantization; keep-if-smaller upstream
    /// guards the rare case where an already tiny palette PNG doesn't benefit.
    private static func recompressPNG(_ fileURL: URL, _ quality: Double, _ maxWidth: Int, _ tempDir: URL) throws -> URL {
        let frame = try decodedFrame(fileURL, maxWidth: maxWidth)
        let encoded = try PNGCoder.quantizedPNG(from: frame, quality: quality)
        let output = tempDir.appendingPathComponent("out.png")
        try encoded.write(to: output)
        return output
    }

    /// Two candidates, smaller wins:
    /// 1. lossy: ImageIO progressive re-encode at the quality slider
    ///    (also bakes orientation, strips metadata, applies resize)
    /// 2. lossless: byte-level metadata strip, image data untouched
    ///    (only when no orientation to bake and no resize requested)
    private static func recompressJPEG(_ fileURL: URL, _ quality: Double, _ maxWidth: Int, _ tempDir: URL) throws -> URL {
        var best: URL? = try? imageIOReencode(fileURL, quality, maxWidth, tempDir)

        if !needsResize(fileURL, maxWidth),
           sourceOrientation(of: fileURL) == 1,
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

    /// Two candidates, smaller wins:
    /// 1. lossless: RIFF-level EXIF/XMP/ICC strip, bitstream untouched
    /// 2. lossy: bundled libwebp re-encode at the quality slider. Animated
    ///    files are decoded and re-encoded frame by frame with timing, loops
    ///    and transparency preserved; resize applies to the whole canvas.
    /// Falls back to the untouched original ("0%") when neither is smaller —
    /// typical for files that were already produced by an optimizer.
    private static func recompressWebP(_ fileURL: URL, _ quality: Double, _ maxWidth: Int, _ tempDir: URL) throws -> URL {
        let original = try Data(contentsOf: fileURL)
        var best: (url: URL, size: Int)? = nil

        if !needsResize(fileURL, maxWidth),
           let strippedData = WebPStripper.stripped(original), strippedData.count < original.count {
            let url = tempDir.appendingPathComponent("stripped.webp")
            try strippedData.write(to: url)
            best = (url, strippedData.count)
        }

        let frames = frameCount(of: fileURL)
        let encoded: Data?
        if frames > 1 {
            encoded = try? AnimatedWebPCoder.recompress(
                fileURL: fileURL,
                quality: quality,
                maxWidth: maxWidth
            )
        } else if let frame = try? decodedFrame(fileURL, maxWidth: maxWidth) {
            encoded = try? WebPEncoder.encode(frame, quality: quality)
        } else {
            encoded = nil
        }
        if let encoded, best == nil || encoded.count < best!.size {
            let url = tempDir.appendingPathComponent("out.webp")
            try encoded.write(to: url)
            best = (url, encoded.count)
        }

        // No candidate improved on the input: hand the original back so the
        // caller reports "unchanged" instead of failing. optimize() never
        // replaces a file that isn't strictly smaller, so this is inert.
        return best?.url ?? fileURL
    }

    private static func recompressAVIF(_ fileURL: URL, _ quality: Double, _ maxWidth: Int, _ tempDir: URL) throws -> URL {
        let frame = try decodedFrame(fileURL, maxWidth: maxWidth)
        let encoded = try AVIFEncoder.encode(frame, quality: quality)
        let output = tempDir.appendingPathComponent("out.avif")
        try encoded.write(to: output)
        return output
    }

    /// Bundled pure-Swift GIF89a encoder — global palette, Bayer dithering,
    /// inter-frame deltas, lossy snapping. Timing (per-frame delays, loop
    /// count) is copied through verbatim; animation is never flattened.
    /// ImageIO's GIF encoder is deliberately not a candidate: its output is
    /// reliably larger than the input (see docs/adr/0002).
    private static func recompressGIF(_ fileURL: URL, _ quality: Double, _ maxWidth: Int, _ tempDir: URL) throws -> URL {
        let encoded = try GIFCoder.recompress(fileURL: fileURL, quality: quality, maxWidth: maxWidth)
        let output = tempDir.appendingPathComponent("out.gif")
        try encoded.write(to: output)
        return output
    }

    // MARK: - ImageIO encoder (JPEG lossy candidate, BMP/TIFF/HEIC)

    private static func imageIOReencode(
        _ fileURL: URL,
        _ quality: Double,
        _ maxWidth: Int,
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

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, typeID, frameCount, nil)
        else { throw CompressionError.encodingUnsupported(String(format: L("no encoder available for .%@ on this macOS"), ext)) }

        for index in 0..<frameCount {
            guard let rendered = renderedFrame(source: source, index: index) else {
                throw CompressionError.encodeFailed
            }
            let frame = resizedIfNeeded(rendered, maxWidth: maxWidth)
            var properties: [CFString: Any] = [:]
            if isLossy {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            if isJPEG {
                // Progressive scan order is typically a few percent smaller.
                properties[kCGImagePropertyJFIFDictionary] =
                    [kCGImagePropertyJFIFIsProgressive: true]
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

    /// Frame 0 with EXIF orientation baked into the pixels, downscaled to
    /// `maxWidth` when requested.
    private static func decodedFrame(_ fileURL: URL, maxWidth: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let frame = renderedFrame(source: source, index: 0)
        else { throw CompressionError.unknownFormat }
        return resizedIfNeeded(frame, maxWidth: maxWidth)
    }

    /// Width-based downscale keeping aspect ratio; never upscales.
    /// Shared with the GIF encoder, which scales every frame of the canvas.
    static func resizedIfNeeded(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard maxWidth > 0, image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let newHeight = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: maxWidth,
                  height: newHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: maxWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    /// Frame `index` decoded with EXIF orientation baked into the pixels.
    /// Shared with Cropper (frame-by-frame animated GIF cropping).
    static func renderedFrame(source: CGImageSource, index: Int) -> CGImage? {
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

    /// Per-frame GIF delay, defaulting to 0.1s like every browser does.
    /// Shared with Cropper, which must preserve animation timing.
    static func frameDelay(source: CGImageSource, index: Int) -> Double {
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

    /// Displayed pixel size (orientation-corrected), for the UI.
    static func pixelDimensions(of fileURL: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// Pixel width as displayed — orientations 5-8 rotate 90°, swapping sides.
    private static func effectivePixelWidth(of fileURL: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 0 }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? height : width
    }

    private static func frameCount(of fileURL: URL) -> Int {
        if fileURL.pathExtension.lowercased() == "webp" {
            return AnimatedWebPCoder.frameCount(fileURL)
        }
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
