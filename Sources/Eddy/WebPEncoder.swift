import CoreGraphics
import Foundation
import libwebp

/// In-process WebP encoder backed by the bundled libwebp.
enum WebPEncoder {

    /// Encodes a CGImage as lossy WebP. `quality` is 0...1.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        guard let buffer = RGBABuffer(image: image) else { throw CompressionError.encodeFailed }

        var output: UnsafeMutablePointer<UInt8>? = nil
        let byteCount = WebPEncodeRGBA(
            buffer.pixels,
            Int32(buffer.width),
            Int32(buffer.height),
            Int32(buffer.bytesPerRow),
            Float(max(1, min(100, quality * 100))),
            &output
        )
        guard byteCount > 0, let output else { throw CompressionError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: byteCount)
    }
}
