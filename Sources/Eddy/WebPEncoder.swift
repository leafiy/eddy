import CoreGraphics
import Foundation
import libwebp

/// In-process WebP encoder backed by the bundled libwebp — no external
/// cwebp binary and no macOS 14 ImageIO encoder required.
enum WebPEncoder {

    /// Encodes a CGImage as lossy WebP. `quality` is 0...1.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0, // let CoreGraphics pick; read back below
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // R,G,B,A in memory
              )
        else { throw CompressionError.encodeFailed }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rawPixels = context.data else { throw CompressionError.encodeFailed }

        let bytesPerRow = context.bytesPerRow
        let pixels = rawPixels.assumingMemoryBound(to: UInt8.self)

        // CoreGraphics gives premultiplied alpha; WebPEncodeRGBA expects straight.
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let i = rowStart + x * 4
                let alpha = UInt32(pixels[i + 3])
                if alpha != 0 && alpha != 255 {
                    pixels[i]     = UInt8(min(255, UInt32(pixels[i])     * 255 / alpha))
                    pixels[i + 1] = UInt8(min(255, UInt32(pixels[i + 1]) * 255 / alpha))
                    pixels[i + 2] = UInt8(min(255, UInt32(pixels[i + 2]) * 255 / alpha))
                }
            }
        }

        var output: UnsafeMutablePointer<UInt8>? = nil
        let byteCount = WebPEncodeRGBA(
            pixels,
            Int32(width),
            Int32(height),
            Int32(bytesPerRow),
            Float(max(1, min(100, quality * 100))),
            &output
        )
        guard byteCount > 0, let output else { throw CompressionError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: byteCount)
    }
}
