import Compression
import CoreGraphics
import Foundation

/// PNG pipeline: a built-in median-cut quantizer reduces the image to a
/// <=256-color palette (Floyd–Steinberg dithered), then the indexed PNG is
/// written directly — no metadata chunks at all. Pure Swift on top of the
/// system Compression framework; no third-party encoder code.
enum PNGCoder {

    /// `quality` 0...1 caps the palette size (256 entries at 1.0). Like
    /// pngquant's permissive mode the quantization always succeeds; the
    /// keep-if-smaller check upstream discards results that didn't help.
    /// Images that already fit the palette are converted losslessly and
    /// undithered.
    static func quantizedPNG(from image: CGImage, quality: Double) throws -> Data {
        guard let buffer = RGBABuffer(image: image) else { throw CompressionError.encodeFailed }
        let maxColors = max(16, min(256, Int((quality * 256).rounded())))
        let quantized = quantize(buffer, maxColors: maxColors)
        return try encodeIndexedPNG(
            width: buffer.width,
            height: buffer.height,
            indices: quantized.indices,
            paletteRGB: quantized.paletteRGB,
            paletteAlpha: quantized.paletteAlpha
        )
    }

    // MARK: - Median-cut quantization

    private struct WeightedColor {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
        var count: Int
    }

    private static func quantize(
        _ buffer: RGBABuffer, maxColors: Int
    ) -> (indices: [UInt8], paletteRGB: [UInt8], paletteAlpha: [UInt8]) {
        let (histogramColors, posterized) = histogram(buffer)
        var colors = histogramColors
        // Exact only when the histogram kept raw colors — a posterized
        // histogram's entries no longer match the source pixels.
        let exact = !posterized && colors.count <= maxColors

        // Move translucent entries to the front so the tRNS chunk can be
        // truncated after the last non-opaque palette slot.
        var palette = exact ? colors : medianCut(&colors, maxColors: maxColors)
        palette.sort { ($0.a, $0.count) < ($1.a, $1.count) }

        var paletteRGB = [UInt8]()
        var paletteAlpha = [UInt8]()
        paletteRGB.reserveCapacity(palette.count * 3)
        paletteAlpha.reserveCapacity(palette.count)
        for entry in palette {
            paletteRGB.append(entry.r)
            paletteRGB.append(entry.g)
            paletteRGB.append(entry.b)
            paletteAlpha.append(entry.a)
        }

        // When every source color got its own palette slot the mapping is
        // exact — remap directly, no dithering noise.
        let indices = exact
            ? remapExact(buffer, palette: palette)
            : remapDithered(buffer, paletteRGB: paletteRGB, paletteAlpha: paletteAlpha)
        return (indices, paletteRGB, paletteAlpha)
    }

    /// Unique RGBA colors with populations. Fully transparent pixels collapse
    /// onto one entry (RGB zeroed). Falls back to 5-bit posterized channels
    /// when the exact histogram would exceed a bounded size, so photographic
    /// PNGs stay tractable.
    private static func histogram(_ buffer: RGBABuffer) -> (colors: [WeightedColor], posterized: Bool) {
        let pixels = buffer.pixels
        let total = buffer.width * buffer.height
        let cap = 1 << 16
        var counts: [UInt32: Int] = [:]
        counts.reserveCapacity(4096)

        var posterized = false
        for posterize in [false, true] {
            posterized = posterize
            counts.removeAll(keepingCapacity: true)
            var overflowed = false
            for i in 0..<total {
                let p = i * 4
                let a = pixels[p + 3]
                var key: UInt32
                if a == 0 {
                    key = 0
                } else if posterize {
                    // Keep 5 significant bits per channel, replicated so 255
                    // and 0 stay exact.
                    let r = pixels[p] & 0xF8 | pixels[p] >> 5
                    let g = pixels[p + 1] & 0xF8 | pixels[p + 1] >> 5
                    let b = pixels[p + 2] & 0xF8 | pixels[p + 2] >> 5
                    let pa = a & 0xF8 | a >> 5
                    key = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(pa) << 24
                } else {
                    key = UInt32(pixels[p]) | UInt32(pixels[p + 1]) << 8
                        | UInt32(pixels[p + 2]) << 16 | UInt32(a) << 24
                }
                counts[key, default: 0] += 1
                // The posterized key space is itself bounded (32 levels per
                // channel), so only the raw pass needs the escape hatch.
                if !posterize && counts.count > cap {
                    overflowed = true
                    break
                }
            }
            if !overflowed { break }
        }

        let colors = counts.map { key, count in
            WeightedColor(
                r: UInt8(truncatingIfNeeded: key),
                g: UInt8(truncatingIfNeeded: key >> 8),
                b: UInt8(truncatingIfNeeded: key >> 16),
                a: UInt8(truncatingIfNeeded: key >> 24),
                count: count
            )
        }
        return (colors, posterized)
    }

    private struct Box {
        var start: Int
        var count: Int
        var population: Int
        /// 0=r 1=g 2=b 3=a of the widest channel, and its range.
        var widestChannel: Int
        var range: Int
    }

    private static func makeBox(_ colors: [WeightedColor], start: Int, count: Int) -> Box {
        var minR = 255, minG = 255, minB = 255, minA = 255
        var maxR = 0, maxG = 0, maxB = 0, maxA = 0
        var population = 0
        for i in start..<(start + count) {
            let c = colors[i]
            minR = min(minR, Int(c.r)); maxR = max(maxR, Int(c.r))
            minG = min(minG, Int(c.g)); maxG = max(maxG, Int(c.g))
            minB = min(minB, Int(c.b)); maxB = max(maxB, Int(c.b))
            minA = min(minA, Int(c.a)); maxA = max(maxA, Int(c.a))
            population += c.count
        }
        var widest = 0
        var range = maxR - minR
        if maxG - minG > range { widest = 1; range = maxG - minG }
        if maxB - minB > range { widest = 2; range = maxB - minB }
        if maxA - minA > range { widest = 3; range = maxA - minA }
        return Box(start: start, count: count, population: population, widestChannel: widest, range: range)
    }

    private static func channel(_ c: WeightedColor, _ index: Int) -> Int {
        switch index {
        case 0: return Int(c.r)
        case 1: return Int(c.g)
        case 2: return Int(c.b)
        default: return Int(c.a)
        }
    }

    private static func medianCut(_ colors: inout [WeightedColor], maxColors: Int) -> [WeightedColor] {
        var boxes = [makeBox(colors, start: 0, count: colors.count)]
        while boxes.count < maxColors {
            // Split the box that hurts most: population-weighted color range.
            var bestIndex = -1
            var bestPriority = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let priority = box.population * (box.range + 1)
                if priority > bestPriority {
                    bestPriority = priority
                    bestIndex = i
                }
            }
            if bestIndex < 0 { break }

            let box = boxes[bestIndex]
            let ch = box.widestChannel
            colors[box.start..<(box.start + box.count)]
                .sort { channel($0, ch) < channel($1, ch) }

            // Weighted median, clamped so both halves stay non-empty.
            var accumulated = 0
            var splitOffset = 1
            for offset in 0..<box.count {
                accumulated += colors[box.start + offset].count
                if accumulated * 2 >= box.population {
                    splitOffset = offset + 1
                    break
                }
            }
            splitOffset = min(max(splitOffset, 1), box.count - 1)

            boxes[bestIndex] = makeBox(colors, start: box.start, count: splitOffset)
            boxes.append(makeBox(colors, start: box.start + splitOffset, count: box.count - splitOffset))
        }

        return boxes.map { box in
            var sums = [Int](repeating: 0, count: 4)
            var population = 0
            for i in box.start..<(box.start + box.count) {
                let c = colors[i]
                sums[0] += Int(c.r) * c.count
                sums[1] += Int(c.g) * c.count
                sums[2] += Int(c.b) * c.count
                sums[3] += Int(c.a) * c.count
                population += c.count
            }
            let divisor = max(population, 1)
            return WeightedColor(
                r: UInt8((sums[0] + divisor / 2) / divisor),
                g: UInt8((sums[1] + divisor / 2) / divisor),
                b: UInt8((sums[2] + divisor / 2) / divisor),
                a: UInt8((sums[3] + divisor / 2) / divisor),
                count: population
            )
        }
    }

    // MARK: - Remapping

    /// Every source color exists in the palette: direct lookup, lossless.
    private static func remapExact(_ buffer: RGBABuffer, palette: [WeightedColor]) -> [UInt8] {
        var lookup: [UInt32: UInt8] = [:]
        lookup.reserveCapacity(palette.count)
        for (i, entry) in palette.enumerated() {
            let key = UInt32(entry.r) | UInt32(entry.g) << 8
                | UInt32(entry.b) << 16 | UInt32(entry.a) << 24
            lookup[key] = UInt8(i)
        }
        let pixels = buffer.pixels
        let total = buffer.width * buffer.height
        var indices = [UInt8](repeating: 0, count: total)
        for i in 0..<total {
            let p = i * 4
            let a = pixels[p + 3]
            let key = a == 0
                ? 0
                : UInt32(pixels[p]) | UInt32(pixels[p + 1]) << 8
                    | UInt32(pixels[p + 2]) << 16 | UInt32(a) << 24
            indices[i] = lookup[key] ?? 0
        }
        return indices
    }

    /// Floyd–Steinberg error diffusion against the reduced palette. Nearest
    /// lookups are cached per exact post-dither color, which collapses the
    /// palette search for flat regions (the common screenshot case).
    private static func remapDithered(
        _ buffer: RGBABuffer, paletteRGB: [UInt8], paletteAlpha: [UInt8]
    ) -> [UInt8] {
        let width = buffer.width
        let height = buffer.height
        let paletteCount = paletteAlpha.count
        // SoA -> SIMD palette for the nearest search; alpha error weighted
        // double so translucency mismatches cost more than hue shifts.
        // Built with an explicit loop: the closure form sends the type
        // checker into SIMD-initializer overload resolution that times out.
        var palette = [SIMD4<Int32>]()
        palette.reserveCapacity(paletteCount)
        for i in 0..<paletteCount {
            let r = Int32(paletteRGB[i * 3])
            let g = Int32(paletteRGB[i * 3 + 1])
            let b = Int32(paletteRGB[i * 3 + 2])
            let a = Int32(paletteAlpha[i])
            palette.append(SIMD4<Int32>(r, g, b, a))
        }
        let pixels = buffer.pixels
        var indices = [UInt8](repeating: 0, count: width * height)
        // One error slot per channel with a one-pixel guard on both sides.
        var currentError = [Float](repeating: 0, count: (width + 2) * 4)
        var nextError = [Float](repeating: 0, count: (width + 2) * 4)
        var cache: [UInt32: UInt8] = [:]
        cache.reserveCapacity(1 << 14)

        func clampToByte(_ value: Float) -> Int32 {
            Int32(min(max(value, 0), 255) + 0.5)
        }

        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                let e = (x + 1) * 4
                let sourceAlpha = pixels[p + 3]
                // Fully transparent pixels snap to the shared transparent
                // entry — mirrors the histogram, keeps halos out.
                let r = sourceAlpha == 0 ? 0 : clampToByte(Float(pixels[p]) + currentError[e])
                let g = sourceAlpha == 0 ? 0 : clampToByte(Float(pixels[p + 1]) + currentError[e + 1])
                let b = sourceAlpha == 0 ? 0 : clampToByte(Float(pixels[p + 2]) + currentError[e + 2])
                let a = sourceAlpha == 0 ? 0 : clampToByte(Float(sourceAlpha) + currentError[e + 3])

                let key = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
                let index: UInt8
                if let hit = cache[key] {
                    index = hit
                } else {
                    let target = SIMD4<Int32>(r, g, b, a)
                    var best = 0
                    var bestDistance = Int32.max
                    for i in 0..<paletteCount {
                        let d = target &- palette[i]
                        let dd = d &* d
                        let distance = dd.x + dd.y + dd.z + 2 * dd.w
                        if distance < bestDistance {
                            bestDistance = distance
                            best = i
                        }
                    }
                    index = UInt8(best)
                    // Photographic sources can produce millions of distinct
                    // post-dither colors; keep the cache bounded.
                    if cache.count >= 1 << 18 { cache.removeAll(keepingCapacity: true) }
                    cache[key] = index
                }
                indices[y * width + x] = index

                if sourceAlpha == 0 { continue }
                let chosen = palette[Int(index)]
                let errorR = Float(r - chosen.x)
                let errorG = Float(g - chosen.y)
                let errorB = Float(b - chosen.z)
                let errorA = Float(a - chosen.w)
                diffuse(errorR, at: e, into: &currentError, and: &nextError)
                diffuse(errorG, at: e + 1, into: &currentError, and: &nextError)
                diffuse(errorB, at: e + 2, into: &currentError, and: &nextError)
                diffuse(errorA, at: e + 3, into: &currentError, and: &nextError)
            }
            swap(&currentError, &nextError)
            for i in nextError.indices { nextError[i] = 0 }
        }
        return indices
    }

    /// Floyd–Steinberg coefficients: 7/16 right, 3/16 below-left, 5/16
    /// below, 1/16 below-right. `slot` is the channel's index in the
    /// guarded error rows.
    @inline(__always)
    private static func diffuse(
        _ error: Float, at slot: Int, into currentError: inout [Float], and nextError: inout [Float]
    ) {
        currentError[slot + 4] += error * 7 / 16
        nextError[slot - 4] += error * 3 / 16
        nextError[slot] += error * 5 / 16
        nextError[slot + 4] += error * 1 / 16
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
