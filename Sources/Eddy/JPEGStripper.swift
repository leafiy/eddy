import Foundation

/// Lossless JPEG metadata removal: drops EXIF/XMP/ICC/IPTC/comment segments
/// without touching the entropy-coded image data (jpegoptim's lossless mode).
/// Keeps JFIF APP0 and Adobe APP14 (required for correct CMYK/YCCK decoding).
enum JPEGStripper {

    /// Returns nil when the input isn't a structurally valid JPEG; the caller
    /// then keeps the original file.
    static func stripped(_ data: Data) -> Data? {
        // Work on a flat buffer; Data slicing keeps original indices, which is
        // error-prone here.
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var out = Data(capacity: bytes.count)
        out.append(contentsOf: [0xFF, 0xD8])
        var i = 2
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            var markerIndex = i + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { // fill bytes
                markerIndex += 1
            }
            guard markerIndex < bytes.count else { return nil }
            let marker = bytes[markerIndex]

            if marker == 0xDA { // SOS: entropy data follows; copy the rest verbatim
                out.append(contentsOf: bytes[i...])
                return out
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { // standalone markers
                out.append(contentsOf: bytes[i...markerIndex])
                i = markerIndex + 1
                continue
            }
            guard markerIndex + 2 < bytes.count else { return nil }
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            let segmentEnd = markerIndex + 1 + length
            guard length >= 2, segmentEnd <= bytes.count else { return nil }

            let drop = (0xE1...0xED).contains(marker) // APP1-APP13: EXIF, XMP, ICC, IPTC…
                || marker == 0xFE                     // comment
            if !drop {
                out.append(contentsOf: bytes[i..<segmentEnd])
            }
            i = segmentEnd
        }
        return nil
    }
}
