import CoreGraphics
import Foundation
import libavif

/// In-process AVIF encoder backed by the bundled libavif + libaom.
enum AVIFEncoder {

    /// Encodes a CGImage as lossy AVIF. `quality` is 0...1.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        guard let buffer = RGBABuffer(image: image) else { throw CompressionError.encodeFailed }

        guard let avif = avifImageCreate(
            UInt32(buffer.width), UInt32(buffer.height), 8, AVIF_PIXEL_FORMAT_YUV420)
        else { throw CompressionError.encodeFailed }
        defer { avifImageDestroy(avif) }

        // CICP for sRGB content: BT.709 primaries, sRGB transfer, BT.601 matrix.
        avif.pointee.colorPrimaries = avifColorPrimaries(AVIF_COLOR_PRIMARIES_BT709.rawValue)
        avif.pointee.transferCharacteristics =
            avifTransferCharacteristics(AVIF_TRANSFER_CHARACTERISTICS_SRGB.rawValue)
        avif.pointee.matrixCoefficients =
            avifMatrixCoefficients(AVIF_MATRIX_COEFFICIENTS_BT601.rawValue)

        var rgb = avifRGBImage()
        avifRGBImageSetDefaults(&rgb, avif)
        rgb.format = AVIF_RGB_FORMAT_RGBA
        rgb.pixels = buffer.pixels
        rgb.rowBytes = UInt32(buffer.bytesPerRow)
        guard avifImageRGBToYUV(avif, &rgb) == AVIF_RESULT_OK else {
            throw CompressionError.encodeFailed
        }

        guard let encoder = avifEncoderCreate() else { throw CompressionError.encodeFailed }
        defer { avifEncoderDestroy(encoder) }
        let q = Int32(max(1, min(100, (quality * 100).rounded())))
        encoder.pointee.quality = q
        encoder.pointee.qualityAlpha = q
        encoder.pointee.speed = 6
        encoder.pointee.maxThreads = Int32(ProcessInfo.processInfo.activeProcessorCount)

        var output = avifRWData()
        guard avifEncoderWrite(encoder, avif, &output) == AVIF_RESULT_OK,
              let outputData = output.data
        else {
            avifRWDataFree(&output)
            throw CompressionError.encodeFailed
        }
        defer { avifRWDataFree(&output) }
        return Data(bytes: outputData, count: output.size)
    }
}
