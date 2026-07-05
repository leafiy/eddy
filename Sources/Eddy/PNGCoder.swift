import Compression
import CoreGraphics
import Foundation
import libimagequant

/// PNG pipeline: libimagequant (pngquant's engine) quantizes to a <=256-color
/// palette, then the indexed PNG is written directly — no metadata chunks at
/// all. Byte layout and the quantizer call sequence are covered by the
/// project's reference tests.
enum PNGCoder {

    /// `quality` 0...1 caps the quantization quality (window 0...q, so the
    /// quantizer always succeeds — pngquant's permissive mode).
    static func quantizedPNG(from image: CGImage, quality: Double) throws -> Data {
        guard let buffer = RGBABuffer(image: image) else { throw CompressionError.encodeFailed }
        guard let attr = liq_attr_create() else { throw CompressionError.encodeFailed }
        defer { liq_attr_destroy(attr) }

        let qMax = Int32(max(1, min(100, (quality * 100).rounded())))
        liq_set_quality(attr, 0, qMax)

        guard let liqImage = liq_image_create_rgba(
            attr, buffer.pixels, Int32(buffer.width), Int32(buffer.height), 0)
        else { throw CompressionError.encodeFailed }
        defer { liq_image_destroy(liqImage) }

        var result: OpaquePointer? = nil
        guard liq_image_quantize(liqImage, attr, &result) == LIQ_OK, let result else {
            throw CompressionError.encodeFailed
        }
        defer { liq_result_destroy(result) }
        liq_set_dithering_level(result, 1.0)

        var indices = [UInt8](repeating: 0, count: buffer.width * buffer.height)
        let remapStatus = indices.withUnsafeMutableBytes { raw in
            liq_write_remapped_image(result, liqImage, raw.baseAddress, raw.count)
        }
        guard remapStatus == LIQ_OK, let palettePointer = liq_get_palette(result) else {
            throw CompressionError.encodeFailed
        }

        let palette = palettePointer.pointee
        let count = Int(palette.count)
        var paletteRGB = [UInt8]()
        var paletteAlpha = [UInt8]()
        paletteRGB.reserveCapacity(count * 3)
        paletteAlpha.reserveCapacity(count)
        withUnsafeBytes(of: palette.entries) { raw in
            let entries = raw.bindMemory(to: liq_color.self)
            for i in 0..<count {
                paletteRGB.append(entries[i].r)
                paletteRGB.append(entries[i].g)
                paletteRGB.append(entries[i].b)
                paletteAlpha.append(entries[i].a)
            }
        }

        return try encodeIndexedPNG(
            width: buffer.width,
            height: buffer.height,
            indices: indices,
            paletteRGB: paletteRGB,
            paletteAlpha: paletteAlpha
        )
    }

    // MARK: - Indexed PNG writer

    private static func encodeIndexedPNG(
        width: Int,
        height: Int,
        indices: [UInt8],
        paletteRGB: [UInt8],
        paletteAlpha: [UInt8]
    ) throws -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(width))
        ihdr.appendBigEndian(UInt32(height))
        ihdr.append(contentsOf: [8, 3, 0, 0, 0]) // 8-bit, palette, deflate, adaptive, no interlace
        png.append(chunk("IHDR", ihdr))

        png.append(chunk("PLTE", Data(paletteRGB)))

        // tRNS may be truncated after the last non-opaque entry; omit if opaque.
        if let lastTransparent = paletteAlpha.lastIndex(where: { $0 != 255 }) {
            png.append(chunk("tRNS", Data(paletteAlpha[...lastTransparent])))
        }

        // Scanlines, each prefixed with filter byte 0 (filtering hurts indexed data).
        var scanlines = Data(capacity: height * (width + 1))
        for y in 0..<height {
            scanlines.append(0)
            scanlines.append(contentsOf: indices[(y * width)..<((y + 1) * width)])
        }
        png.append(chunk("IDAT", try zlibCompress(scanlines)))
        png.append(chunk("IEND", Data()))
        return png
    }

    /// Apple Compression emits RAW deflate; wrap it with the zlib header and
    /// adler32 trailer PNG requires.
    private static func zlibCompress(_ input: Data) throws -> Data {
        let capacity = input.count + input.count / 2 + 256
        var output = Data([0x78, 0xDA])
        let deflated: Data = try input.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw CompressionError.encodeFailed
            }
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let written = compression_encode_buffer(
                destination, capacity, source, input.count, nil, COMPRESSION_ZLIB)
            guard written > 0 else { throw CompressionError.encodeFailed }
            return Data(bytes: destination, count: written)
        }
        output.append(deflated)
        output.appendBigEndian(adler32(input))
        return output
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let end = min(i + 5552, bytes.count) // largest run before UInt32 overflow
                while i < end {
                    a &+= UInt32(bytes[i])
                    b &+= a
                    i += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func chunk(_ tag: String, _ payload: Data) -> Data {
        var body = Data(tag.utf8)
        body.append(payload)
        var out = Data()
        out.appendBigEndian(UInt32(payload.count))
        out.append(body)
        out.appendBigEndian(crc32(body))
        return out
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
