import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One crop request: a single selection rectangle in image pixel
/// coordinates (top-left origin) that may shrink inside the image
/// (trimming) and/or extend beyond it (padding), per edge.
struct CropSpec {
    /// Selection in image pixel coordinates; origin may be negative and
    /// maxX/maxY may exceed the image bounds.
    var rect: CGRect
    /// Extension Background — fill for canvas beyond the original pixels.
    /// nil paints nothing (transparent); only offered for alpha-capable formats.
    var background: CGColor?
    /// Decoration: fixed hairline border traced on the image edge.
    var border: Bool
    /// Decoration: fixed soft drop shadow beneath the image.
    var shadow: Bool
}

/// Applies a CropSpec to a file and saves it back in place, in the original
/// format — the crop counterpart of Compressor.optimize()'s atomic replace.
/// Animated GIFs are cropped frame by frame; frame count, per-frame delays,
/// and loop count are preserved (Animated Asset invariant). GIF re-encoding
/// currently goes through ImageIO — bulkier output, correct timing; swap to
/// the in-house GIF engine once docs/specs/gif-support.md lands (ADR-0001).
enum Cropper {

    struct Result {
        let bytes: Int
        let width: Int
        let height: Int
    }

    /// Formats whose files can carry transparency after a crop save.
    /// JPEG and BMP get their Extension Background forced opaque in the UI.
    static func supportsAlpha(_ ext: String) -> Bool {
        ["png", "webp", "avif", "gif", "tif", "tiff", "heic", "heif"]
            .contains(ext.lowercased())
    }

    /// Full-size frame 0 with orientation baked in — what the crop window
    /// shows and what `crop` uses as its coordinate space.
    static func previewFrame(for fileURL: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return Compressor.renderedFrame(source: source, index: 0)
    }

    static func isAnimated(_ fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static func crop(fileURL: URL, spec: CropSpec, quality: Double) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CompressionError.unknownFormat }

        let ext = fileURL.pathExtension.lowercased()
        let data: Data
        if ext == "gif", CGImageSourceGetCount(source) > 1 {
            data = try animatedGIFData(source: source, spec: spec)
        } else {
            guard let frame = Compressor.renderedFrame(source: source, index: 0) else {
                throw CompressionError.unknownFormat
            }
            data = try encode(try render(frame, spec: spec), ext: ext, quality: quality)
        }

        // Stage next to the original so the final swap is atomic on the same
        // volume — the same pattern Compressor.optimize uses.
        let fm = FileManager.default
        let staging = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".eddy-\(UUID().uuidString).tmp")
        try data.write(to: staging)
        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return Result(
            bytes: data.count,
            width: max(1, Int(spec.rect.width.rounded())),
            height: max(1, Int(spec.rect.height.rounded()))
        )
    }

    // MARK: - Rendering

    /// Decoration metrics scale with the shorter image side so "subtle"
    /// reads the same at 400 px and at 4000 px.
    private static func decorationUnit(_ image: CGImage) -> CGFloat {
        max(1, CGFloat(min(image.width, image.height)) / 400)
    }

    private static func render(_ image: CGImage, spec: CropSpec) throws -> CGImage {
        let outWidth = max(1, Int(spec.rect.width.rounded()))
        let outHeight = max(1, Int(spec.rect.height.rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: outWidth,
                  height: outHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: outWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw CompressionError.encodeFailed }

        if let background = spec.background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        }

        // Selection coords are top-left-origin; CGContext is bottom-up.
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let drawRect = CGRect(
            x: -spec.rect.minX,
            y: CGFloat(outHeight) + spec.rect.minY - imageHeight,
            width: imageWidth,
            height: imageHeight
        )

        let unit = decorationUnit(image)
        if spec.shadow {
            context.saveGState()
            // Offset is in the context's bottom-up space: negative y = below.
            context.setShadow(
                offset: CGSize(width: 0, height: -3 * unit),
                blur: 10 * unit,
                color: CGColor(gray: 0, alpha: 0.3)
            )
            context.draw(image, in: drawRect)
            context.restoreGState()
        } else {
            context.draw(image, in: drawRect)
        }

        if spec.border {
            context.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
            context.setLineWidth(unit)
            // Inset so the stroke sits on the image, not on the background.
            context.stroke(drawRect.insetBy(dx: unit / 2, dy: unit / 2))
        }

        guard let output = context.makeImage() else { throw CompressionError.encodeFailed }
        return output
    }

    // MARK: - Encoding (original format in, same format out)

    private static func encode(_ image: CGImage, ext: String, quality: Double) throws -> Data {
        switch ext {
        case "png":
            return try PNGCoder.quantizedPNG(from: image, quality: quality)
        case "jpg", "jpeg", "jpe":
            return try Compressor.jpegData(from: image, quality: quality)
        case "webp":
            return try WebPEncoder.encode(image, quality: quality)
        case "avif":
            return try AVIFEncoder.encode(image, quality: quality)
        case "gif":
            return try imageIOData(image, type: .gif, quality: nil, ext: ext)
        case "bmp":
            // ImageIO's BMP writer handles alpha unreliably; flatten first.
            return try imageIOData(Compressor.flattenedOpaque(image), type: .bmp, quality: nil, ext: ext)
        case "tif", "tiff":
            return try imageIOData(image, type: .tiff, quality: nil, ext: ext)
        case "heic":
            return try imageIOData(image, type: .heic, quality: quality, ext: ext)
        case "heif":
            return try imageIOData(image, type: .heif, quality: quality, ext: ext)
        default:
            throw CompressionError.encodingUnsupported(
                String(format: L("no encoder available for .%@ on this macOS"), ext))
        }
    }

    private static func imageIOData(
        _ image: CGImage,
        type: UTType,
        quality: Double?,
        ext: String
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)
        else {
            throw CompressionError.encodingUnsupported(
                String(format: L("no encoder available for .%@ on this macOS"), ext))
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CompressionError.encodeFailed }
        return data as Data
    }

    /// Every frame cropped through the same spec; loop count and per-frame
    /// delays pass through untouched.
    private static func animatedGIFData(source: CGImageSource, spec: CropSpec) throws -> Data {
        let frameCount = CGImageSourceGetCount(source)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frameCount, nil)
        else {
            throw CompressionError.encodingUnsupported(
                String(format: L("no encoder available for .%@ on this macOS"), "gif"))
        }

        if let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gifProps = containerProps[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loopCount = gifProps[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
            )
        }

        for index in 0..<frameCount {
            guard let frame = Compressor.renderedFrame(source: source, index: index) else {
                throw CompressionError.encodeFailed
            }
            let rendered = try render(frame, spec: spec)
            let delay = Compressor.frameDelay(source: source, index: index)
            let properties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ]
            CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { throw CompressionError.encodeFailed }
        return data as Data
    }
}
