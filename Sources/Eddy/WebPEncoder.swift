import CoreGraphics
import Foundation
import libwebp

/// In-process WebP encoder backed by the bundled libwebp.
/// Uses the advanced API with method 6 (slowest/smallest, what `cwebp -m 6`
/// does) instead of the quick-path WebPEncodeRGBA default of method 4.
enum WebPEncoder {

    /// Encodes a CGImage as lossy WebP. `quality` is 0...1.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        guard let buffer = RGBABuffer(image: image) else { throw CompressionError.encodeFailed }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw CompressionError.encodeFailed }
        config.quality = Float(max(1, min(100, quality * 100)))
        config.method = 6
        guard WebPValidateConfig(&config) != 0 else { throw CompressionError.encodeFailed }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw CompressionError.encodeFailed }
        picture.width = Int32(buffer.width)
        picture.height = Int32(buffer.height)
        picture.use_argb = 1
        guard WebPPictureImportRGBA(&picture, buffer.pixels, Int32(buffer.bytesPerRow)) != 0 else {
            throw CompressionError.encodeFailed
        }
        defer { WebPPictureFree(&picture) }

        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        defer { writer.deallocate() }
        WebPMemoryWriterInit(writer)
        defer { WebPMemoryWriterClear(writer) }
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)

        guard WebPEncode(&config, &picture) != 0, let encoded = writer.pointee.mem else {
            throw CompressionError.encodeFailed
        }
        return Data(bytes: encoded, count: writer.pointee.size)
    }
}
