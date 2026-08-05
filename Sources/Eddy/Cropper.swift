import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Quarter-turn rotation applied before crop coordinates are evaluated.
/// Keeping this in the edit spec lets still images and every animation frame
/// use exactly the same transform at save time.
enum ImageRotation: Int {
    case none = 0
    case right = 1
    case upsideDown = 2
    case left = 3

    func rotated(_ direction: ImageRotationDirection) -> ImageRotation {
        let delta = direction == .right ? 1 : 3
        return ImageRotation(rawValue: (rawValue + delta) % 4) ?? .none
    }
}

enum ImageRotationDirection {
    case left, right
}

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
    /// Decoration: fixed hairline border. After Vision background removal it
    /// follows the foreground alpha; otherwise it traces the image edge.
    var border: Bool
    /// Decoration: fixed soft drop shadow beneath the image.
    var shadow: Bool
    /// Rotation is applied to the source before `rect` is evaluated.
    var rotation: ImageRotation = .none
    /// A foreground-only rendering of the static source. When present it
    /// replaces the decoded frame and preserves its alpha through the rest
    /// of the crop/decorations pipeline.
    var foregroundImage: CGImage? = nil
}

/// Applies a CropSpec to a file and saves it back in place, in the original
/// format — the crop counterpart of Compressor.optimize()'s atomic replace.
/// Animated GIF and WebP files are edited frame by frame; frame count,
/// per-frame delays, loop count and transparency are preserved (Animated
/// Asset invariant).
enum Cropper {

    struct Result {
        let bytes: Int
        let width: Int
        let height: Int
        let outputURL: URL
    }

    /// A compact macOS-style surface shadow: short offset, restrained blur,
    /// and low-alpha neutral black. Values are expressed in decoration units
    /// so exported pixels and the scaled SwiftUI preview stay aligned.
    static let standardShadowBlur: CGFloat = 4
    static let standardShadowOffset: CGFloat = 2
    static let standardShadowOpacity: CGFloat = 0.18
    private static let decorationContext = CIContext(options: [.cacheIntermediates: false])

    /// Formats whose files can carry transparency after a crop save.
    /// JPEG and BMP get their Extension Background forced opaque in the UI.
    static func supportsAlpha(_ ext: String) -> Bool {
        ["png", "webp", "avif", "gif", "tif", "tiff", "heic", "heif"]
            .contains(ext.lowercased())
    }

    /// Full-size frame 0 with orientation baked in — what the crop window
    /// shows and what `crop` uses as its coordinate space.
    static func previewFrame(for fileURL: URL) -> CGImage? {
        if fileURL.pathExtension.lowercased() == "webp" {
            return AnimatedWebPCoder.firstFrame(fileURL)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return Compressor.renderedFrame(source: source, index: 0)
    }

    static func isAnimated(_ fileURL: URL) -> Bool {
        if fileURL.pathExtension.lowercased() == "webp" {
            return AnimatedWebPCoder.isAnimated(fileURL)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static func crop(fileURL: URL, spec: CropSpec, quality: Double) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CompressionError.unknownFormat }

        let ext = fileURL.pathExtension.lowercased()
        let frameCount = ext == "webp"
            ? AnimatedWebPCoder.frameCount(fileURL)
            : CGImageSourceGetCount(source)
        if frameCount > 1, spec.foregroundImage != nil {
            throw CompressionError.encodingUnsupported(
                L("Background removal is unavailable for animated images"))
        }
        // Removing a background from an opaque-only source must produce a
        // format that can actually retain the generated alpha channel.
        let outputExtension = spec.foregroundImage != nil && !supportsAlpha(ext) ? "png" : ext
        let data: Data
        if ext == "webp", frameCount > 1 {
            data = try AnimatedWebPCoder.edit(
                fileURL: fileURL,
                spec: spec,
                quality: quality
            )
        } else if ext == "gif", frameCount > 1 {
            data = try animatedGIFData(source: source, spec: spec)
        } else {
            guard let decoded = Compressor.renderedFrame(source: source, index: 0) else {
                throw CompressionError.unknownFormat
            }
            let sourceImage = spec.foregroundImage ?? decoded
            let rotated = try rotate(sourceImage, rotation: spec.rotation)
            data = try encode(
                try render(rotated, spec: spec),
                ext: outputExtension,
                quality: quality
            )
        }

        let outputURL = try write(
            data,
            replacing: fileURL,
            outputExtension: outputExtension
        )
        return Result(
            bytes: data.count,
            width: max(1, Int(spec.rect.width.rounded())),
            height: max(1, Int(spec.rect.height.rounded())),
            outputURL: outputURL
        )
    }

    // MARK: - Rendering

    /// Decoration metrics scale with the shorter image side so "subtle"
    /// reads the same at 400 px and at 4000 px.
    private static func decorationUnit(_ image: CGImage) -> CGFloat {
        max(1, CGFloat(min(image.width, image.height)) / 400)
    }

    /// Paints a compact outline around the foreground alpha without changing
    /// the canvas. Vision's foreground image is already the authoritative
    /// subject mask, so no second segmentation pass or visible mode is needed.
    static func addingSubjectBorder(to image: CGImage) throws -> CGImage {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let silhouette = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": zero,
            "inputGVector": zero,
            "inputBVector": zero,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.62, y: 0.62, z: 0.62, w: 0),
        ])
        let expanded = silhouette.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: decorationUnit(image),
        ]).cropped(to: extent)
        let decorated = source.composited(over: expanded).cropped(to: extent)
        guard let output = decorationContext.createCGImage(decorated, from: extent)
        else { throw CompressionError.encodeFailed }
        return output
    }

    static func render(_ image: CGImage, spec: CropSpec) throws -> CGImage {
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
        // Once Vision has produced a foreground-only image, border and shadow
        // must use that alpha silhouette rather than the old rectangular
        // canvas. The border becomes part of the silhouette before shadowing.
        let decoratedImage = spec.border && spec.foregroundImage != nil
            ? try addingSubjectBorder(to: image)
            : image
        if spec.shadow {
            context.saveGState()
            // Offset is in the context's bottom-up space, so negative y means
            // below the image.
            context.setShadow(
                offset: CGSize(width: 0, height: -standardShadowOffset * unit),
                blur: standardShadowBlur * unit,
                color: CGColor(gray: 0, alpha: standardShadowOpacity)
            )
            context.draw(decoratedImage, in: drawRect)
            context.restoreGState()
        } else {
            context.draw(decoratedImage, in: drawRect)
        }

        if spec.border, spec.foregroundImage == nil {
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
            let rotated = try rotate(frame, rotation: spec.rotation)
            let rendered = try render(rotated, spec: spec)
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

    // MARK: - Rotation

    /// Full-resolution quarter-turn used by both the editor preview and the
    /// save pipeline. Core Image handles the coordinate-system conversion;
    /// the result is normalized back to a zero-origin CGImage.
    static func rotate(_ image: CGImage, rotation: ImageRotation) throws -> CGImage {
        guard rotation != .none else { return image }
        let orientation: CGImagePropertyOrientation
        switch rotation {
        case .none:       orientation = .up
        case .right:      orientation = .right
        case .upsideDown: orientation = .down
        case .left:       orientation = .left
        }
        var transformed = CIImage(cgImage: image).oriented(orientation)
        let extent = transformed.extent.integral
        transformed = transformed.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        let outputRect = CGRect(origin: .zero, size: extent.size)
        guard let output = CIContext(options: [.cacheIntermediates: false])
            .createCGImage(transformed, from: outputRect)
        else { throw CompressionError.encodeFailed }
        return output
    }

    /// Carries a top-left-origin crop/padding rectangle through a quarter turn.
    /// Rectangles may extend beyond the image; the same affine formulas still
    /// preserve the user's selected canvas.
    static func rotate(
        _ rect: CGRect,
        in imageSize: CGSize,
        direction: ImageRotationDirection
    ) -> CGRect {
        switch direction {
        case .right:
            return CGRect(
                x: imageSize.height - rect.maxY,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        case .left:
            return CGRect(
                x: rect.minY,
                y: imageSize.width - rect.maxX,
                width: rect.height,
                height: rect.width
            )
        }
    }

    // MARK: - Atomic output

    private static func write(
        _ data: Data,
        replacing fileURL: URL,
        outputExtension: String
    ) throws -> URL {
        let fm = FileManager.default
        if fileURL.pathExtension.lowercased() == outputExtension {
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
            return fileURL
        }

        // Alpha introduced into JPEG/BMP needs a new PNG path. Follow the
        // compressor's conversion convention and never overwrite a sibling.
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let name = counter == 1
                ? "\(base).\(outputExtension)"
                : "\(base)-\(counter).\(outputExtension)"
            counter += 1
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            do {
                try fm.removeItem(at: fileURL)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            return destination
        }
    }
}
