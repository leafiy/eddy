import CoreGraphics
import Foundation

/// Straight-alpha, tightly packed RGBA8 pixels rendered from a CGImage.
/// Shared input format for the libimagequant / libwebp / libavif encoders.
/// The backing CGContext owns the memory; keep the buffer alive while using
/// `pixels`.
final class RGBABuffer {
    let width: Int
    let height: Int
    /// Always exactly `width * 4` — the context is created unpadded so the
    /// buffer can be handed to stride-less APIs (libimagequant) directly.
    let bytesPerRow: Int
    private let context: CGContext

    var pixels: UnsafeMutablePointer<UInt8> {
        // Safe: context was created with data: nil, so CoreGraphics allocated
        // and owns the backing store for the context's lifetime.
        context.data!.assumingMemoryBound(to: UInt8.self)
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // R,G,B,A in memory
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard context.data != nil else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = context.bytesPerRow
        self.context = context
        unpremultiply()
    }

    /// CoreGraphics renders premultiplied alpha; the encoders expect straight.
    private func unpremultiply() {
        let buffer = pixels
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let i = rowStart + x * 4
                let alpha = UInt32(buffer[i + 3])
                if alpha != 0 && alpha != 255 {
                    buffer[i]     = UInt8(min(255, UInt32(buffer[i])     * 255 / alpha))
                    buffer[i + 1] = UInt8(min(255, UInt32(buffer[i + 1]) * 255 / alpha))
                    buffer[i + 2] = UInt8(min(255, UInt32(buffer[i + 2]) * 255 / alpha))
                }
            }
        }
    }
}
