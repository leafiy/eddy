import Foundation

/// Lossless WebP metadata removal: drops EXIF / XMP / ICC RIFF chunks without
/// touching the VP8/VP8L bitstream, and clears the matching VP8X feature
/// flags. Works for animated files too (ANIM/ANMF chunks are kept verbatim).
enum WebPStripper {

    /// Returns nil when the input isn't a valid WebP or has no metadata to drop.
    static func stripped(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0...3].elementsEqual("RIFF".utf8),
              bytes[8...11].elementsEqual("WEBP".utf8)
        else { return nil }

        var chunks: [(fourcc: ArraySlice<UInt8>, payload: ArraySlice<UInt8>)] = []
        var droppedAny = false
        var i = 12
        while i + 8 <= bytes.count {
            let fourcc = bytes[i..<(i + 4)]
            let size = Int(bytes[i + 4])
                | Int(bytes[i + 5]) << 8
                | Int(bytes[i + 6]) << 16
                | Int(bytes[i + 7]) << 24
            let payloadEnd = i + 8 + size
            guard size >= 0, payloadEnd <= bytes.count else { return nil }
            if fourcc.elementsEqual("EXIF".utf8)
                || fourcc.elementsEqual("XMP ".utf8)
                || fourcc.elementsEqual("ICCP".utf8) {
                droppedAny = true
            } else {
                chunks.append((fourcc, bytes[(i + 8)..<payloadEnd]))
            }
            i = payloadEnd + (size & 1) // chunks are padded to even length
        }
        guard droppedAny, !chunks.isEmpty else { return nil }

        var body = Data()
        for (fourcc, payload) in chunks {
            body.append(contentsOf: fourcc)
            var sizeLE = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &sizeLE) { body.append(contentsOf: $0) }
            if fourcc.elementsEqual("VP8X".utf8), let flags = payload.first {
                // Clear ICC (0x20), EXIF (0x08), XMP (0x04) feature bits.
                body.append(flags & 0xD3)
                body.append(contentsOf: payload.dropFirst())
            } else {
                body.append(contentsOf: payload)
            }
            if payload.count & 1 == 1 { body.append(0) }
        }

        var out = Data("RIFF".utf8)
        var riffSize = UInt32(4 + body.count).littleEndian
        withUnsafeBytes(of: &riffSize) { out.append(contentsOf: $0) }
        out.append(contentsOf: "WEBP".utf8)
        out.append(body)
        return out
    }
}
