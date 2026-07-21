import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PNG encoding backed by Apple's ImageIO framework. This keeps the shipped
/// app free of GPL image-quantizer code while preserving alpha and profiles.
enum PNGCoder {
    /// `quality` is accepted for parity with the other encoders. PNG is
    /// lossless, so ImageIO may ignore it; maximum width remains the useful
    /// size-reduction control for PNG files.
    static func quantizedPNG(from image: CGImage, quality: Double) throws -> Data {
        _ = quality
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.encodeFailed
        }
        return data as Data
    }
}
