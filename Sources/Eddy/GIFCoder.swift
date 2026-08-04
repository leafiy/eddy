import CoreGraphics
import Foundation
import ImageIO

/// Pure-Swift GIF89a re-encoder. ImageIO only decodes (composited frames,
/// per-frame delays, loop count); everything after that is ours:
///   - global palette from a two-pass sampled histogram (median cut)
///   - Bayer ordered dithering — stable across frames, unlike error
///     diffusion, so animations don't shimmer and deltas stay small
///   - lossy snapping toward the previous frame's value at low quality
///   - inter-frame deltas with transparent-pixel reuse
///   - a from-scratch LZW bit-packer
/// The pipeline is streaming: two decode passes, at most three index
/// canvases resident, regardless of frame count. ImageIO's own GIF
/// *encoder* is deliberately unused — its output is reliably larger than
/// the input (see docs/adr/0002-in-house-gif-encoder.md).
///
/// Timing is copied through verbatim: raw per-frame centiseconds, no
/// clamping or normalizing, and the Netscape loop extension only when the
/// source had one.
enum GIFCoder {

    /// Re-encodes the GIF at `fileURL`. `quality` (0...1) drives palette
    /// size and lossy snapping; `maxWidth` > 0 downscales the canvas
    /// (aspect kept, never upscales).
    static func recompress(fileURL: URL, quality: Double, maxWidth: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CompressionError.unreadableFile }
        let frameCount = max(CGImageSourceGetCount(source), 1)
        let delays = (0..<frameCount).map { delayCentiseconds(source: source, index: $0) }
        let loopCount = containerLoopCount(source: source)

        // ---- Pass 1: canvas geometry + sampled global histogram ----
        var histogram = Histogram()
        var sawTransparency = false
        var canvasWidth = 0
        var canvasHeight = 0
        for index in 0..<frameCount {
            try autoreleasepool {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                      let buffer = RGBABuffer(image: frame)
                else { throw CompressionError.unreadableFile }
                if index == 0 {
                    canvasWidth = buffer.width
                    canvasHeight = buffer.height
                    // ~2M color samples across the whole animation keeps the
                    // first pass cheap on screen-recording monsters.
                    let totalPixels = canvasWidth * canvasHeight * frameCount
                    histogram.sampleStride = max(1, totalPixels / 2_097_152)
                }
                // ImageIO composites GIF frames onto the full canvas; a
                // mismatching frame means a file we don't understand.
                guard buffer.width == canvasWidth, buffer.height == canvasHeight else {
                    throw CompressionError.encodeFailed
                }
                if histogram.add(buffer, phase: index) { sawTransparency = true }
            }
        }
        guard canvasWidth > 0, canvasHeight > 0 else { throw CompressionError.unreadableFile }
        // GIF dimensions are 16-bit; a bigger canvas can't be represented.
        guard canvasWidth <= 65535, canvasHeight <= 65535 else { throw CompressionError.encodeFailed }

        // ---- Palette ----
        let budget = max(16, min(256, Int((quality * 256).rounded())))
        // Animations always reserve a transparent slot: deltas express
        // "unchanged" through it. Static images only when actually needed.
        let reserveTransparent = sawTransparency || frameCount > 1
        let colorBudget = reserveTransparent ? budget - 1 : budget
        var colors = histogram.entries()
        if colors.isEmpty {
            // Fully transparent canvas — keep one slot so the table is valid.
            colors = [WeightedRGB(r: 0, g: 0, b: 0, count: 1)]
        }
        // `direct`: the palette holds every histogram color unreduced —
        // pixels map by lookup, undithered. `exact` additionally means the
        // histogram saw every pixel (stride 1), i.e. truly lossless mapping;
        // only then is lossy snapping pointless. A sampled-but-small palette
        // (big flat-color GIF) stays direct: dithering it would only add
        // noise the source never had.
        let direct = !histogram.posterized && colors.count <= colorBudget
        let exact = histogram.isExact && colors.count <= colorBudget
        let palette = direct ? colors : medianCut(&colors, maxColors: colorBudget)
        let transparentIndex: UInt8? = reserveTransparent ? UInt8(palette.count) : nil
        let tableCount = palette.count + (reserveTransparent ? 1 : 0)
        var tableBits = 1
        while (1 << tableBits) < tableCount { tableBits += 1 }
        let minCodeSize = max(2, tableBits)

        var paletteRGB = [UInt8]()
        paletteRGB.reserveCapacity(tableCount * 3)
        for entry in palette {
            paletteRGB.append(entry.r)
            paletteRGB.append(entry.g)
            paletteRGB.append(entry.b)
        }
        if reserveTransparent { paletteRGB.append(contentsOf: [0, 0, 0]) }

        // ---- Target size (mirrors Compressor.resizedIfNeeded) ----
        var targetWidth = canvasWidth
        var targetHeight = canvasHeight
        if maxWidth > 0, canvasWidth > maxWidth {
            let scale = Double(maxWidth) / Double(canvasWidth)
            targetWidth = maxWidth
            targetHeight = max(1, Int((Double(canvasHeight) * scale).rounded()))
        }
        let total = targetWidth * targetHeight

        // ---- Pass 2: stream frames — snap, map, then emit with one frame
        // of lookahead. A frame's disposal depends on the NEXT frame: pixels
        // that turn transparent over an opaque screen can only be expressed
        // by disposing the previous frame to background (full-canvas write),
        // so frame N-1 is emitted once frame N's indices are known. At most
        // three index canvases are ever resident.
        var writer = GIFWriter(
            width: targetWidth,
            height: targetHeight,
            paletteRGB: paletteRGB,
            tableBits: tableBits,
            backgroundIndex: transparentIndex ?? 0)
        if frameCount > 1, let loopCount { writer.appendNetscapeLoop(loopCount) }

        var mapper = Mapper(palette: palette, direct: direct)
        // Snapping tolerance in 8-bit channel units; 0 at quality 1.0, and
        // pointless when the mapping is exact (indices are already stable).
        let tolerance: Int32 = exact ? 0 : Int32(((1.0 - quality) * 24.0).rounded())
        let paletteSIMD: [SIMD3<Int32>] = palette.map { SIMD3(Int32($0.r), Int32($0.g), Int32($0.b)) }

        /// Full-canvas literal frame; `disposal` 2 pre-clears the canvas for
        /// a successor that introduces new transparency.
        func emitFull(_ indices: [UInt8], delayCS: Int, disposal: UInt8) {
            if frameCount > 1 || transparentIndex != nil {
                writer.appendGraphicControl(
                    delayCS: delayCS, disposal: disposal, transparentIndex: transparentIndex)
            }
            writer.appendImage(
                x: 0, y: 0, width: targetWidth, height: targetHeight,
                indices: indices, minCodeSize: minCodeSize)
        }

        /// Delta frame against `base` (the screen content when this frame
        /// draws): unchanged pixels become transparent, only the changed
        /// bounding rect is encoded. `base == nil` means the screen is
        /// undefined (first frame) — full literal write.
        func emitDelta(_ indices: [UInt8], base: [UInt8]?, delayCS: Int) {
            guard let base, let t = transparentIndex else {
                emitFull(indices, delayCS: delayCS, disposal: frameCount > 1 ? 1 : 0)
                return
            }
            var minX = targetWidth, minY = targetHeight, maxX = -1, maxY = -1
            for y in 0..<targetHeight {
                let row = y * targetWidth
                for x in 0..<targetWidth where indices[row + x] != base[row + x] {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            writer.appendGraphicControl(delayCS: delayCS, disposal: 1, transparentIndex: t)
            if maxX < 0 {
                // Identical frame: a 1×1 transparent pixel carries the delay.
                writer.appendImage(x: 0, y: 0, width: 1, height: 1, indices: [t], minCodeSize: minCodeSize)
                return
            }
            let rectWidth = maxX - minX + 1
            let rectHeight = maxY - minY + 1
            var rect = [UInt8](repeating: 0, count: rectWidth * rectHeight)
            for y in 0..<rectHeight {
                let src = (minY + y) * targetWidth + minX
                let dst = y * rectWidth
                for x in 0..<rectWidth {
                    let changed = indices[src + x] != base[src + x]
                    rect[dst + x] = changed ? indices[src + x] : t
                }
            }
            writer.appendImage(
                x: minX, y: minY, width: rectWidth, height: rectHeight,
                indices: rect, minCodeSize: minCodeSize)
        }

        var pending: [UInt8]? = nil     // quantized frame awaiting emission
        var pendingBase: [UInt8]? = nil // screen content when `pending` draws
        var pendingDelay = 0

        for index in 0..<frameCount {
            try autoreleasepool {
                guard var frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw CompressionError.unreadableFile
                }
                frame = Compressor.resizedIfNeeded(frame, maxWidth: maxWidth)
                guard let buffer = RGBABuffer(image: frame),
                      buffer.width == targetWidth, buffer.height == targetHeight
                else { throw CompressionError.encodeFailed }

                let pixels = buffer.pixels
                var cur = [UInt8](repeating: 0, count: total)
                for y in 0..<targetHeight {
                    let row = y * targetWidth
                    for x in 0..<targetWidth {
                        let i = row + x
                        let p = i * 4
                        if pixels[p + 3] < 128, let t = transparentIndex {
                            cur[i] = t
                            continue
                        }
                        let r = Int32(pixels[p])
                        let g = Int32(pixels[p + 1])
                        let b = Int32(pixels[p + 2])
                        // Lossy snapping: close enough to the previous
                        // frame's color means keep it — longer transparent
                        // runs after the delta, longer LZW matches. A color
                        // approximation only; valid whatever disposal the
                        // previous frame ends up with.
                        if tolerance > 0, let pending, let t = transparentIndex, pending[i] != t {
                            let previous = paletteSIMD[Int(pending[i])]
                            if abs(previous.x - r) <= tolerance,
                               abs(previous.y - g) <= tolerance,
                               abs(previous.z - b) <= tolerance {
                                cur[i] = pending[i]
                                continue
                            }
                        }
                        cur[i] = mapper.index(r: r, g: g, b: b, x: x, y: y)
                    }
                }

                if let previous = pending {
                    // Decide the previous frame's fate now that this frame
                    // is known. New transparency over an opaque screen can't
                    // be drawn with disposal "keep": the previous frame goes
                    // out full-canvas and disposes to background instead.
                    var needsClear = false
                    if let t = transparentIndex {
                        for i in 0..<total where cur[i] == t && previous[i] != t {
                            needsClear = true
                            break
                        }
                    }
                    if needsClear, let t = transparentIndex {
                        emitFull(previous, delayCS: pendingDelay, disposal: 2)
                        pendingBase = [UInt8](repeating: t, count: total)
                    } else {
                        emitDelta(previous, base: pendingBase, delayCS: pendingDelay)
                        pendingBase = previous
                    }
                }
                pending = cur
                pendingDelay = delays[index]
            }
        }
        if let previous = pending {
            emitDelta(previous, base: pendingBase, delayCS: pendingDelay)
        }

        writer.finish()
        return writer.data
    }

    // MARK: - Timing (verbatim pass-through)

    /// Raw per-frame delay in centiseconds — GIF's native unit, so writing
    /// back what ImageIO read is lossless. No 0.1s flooring: the spec for
    /// this feature forbids normalizing timing.
    private static func delayCentiseconds(source: CGImageSource, index: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 10 }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let seconds = unclamped ?? clamped ?? 0.1
        return max(0, min(65535, Int((seconds * 100).rounded())))
    }

    /// Loop count when the source carries a Netscape extension (0 = forever);
    /// nil when it doesn't — then the output omits the extension too.
    private static func containerLoopCount(source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let value = (gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
        else { return nil }
        return value
    }

    // MARK: - Histogram (pass 1)

    struct WeightedRGB {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var count: Int
    }

    private struct Histogram {
        var sampleStride = 1
        private(set) var posterized = false
        private var counts: [UInt32: Int] = Dictionary(minimumCapacity: 4096)
        private static let capacity = 1 << 16

        /// True when every opaque pixel of every frame was recorded exactly —
        /// the precondition for the lossless direct-mapping fast path.
        var isExact: Bool { sampleStride == 1 && !posterized }

        /// Accumulates one frame. Every pixel's alpha is inspected (missing
        /// transparency would silently flatten it); colors are sampled every
        /// `sampleStride` pixels. Returns whether the frame had transparency.
        mutating func add(_ buffer: RGBABuffer, phase: Int) -> Bool {
            let pixels = buffer.pixels
            let total = buffer.width * buffer.height
            var sawTransparency = false
            var next = sampleStride > 1 ? phase % sampleStride : 0
            for i in 0..<total {
                let p = i * 4
                if pixels[p + 3] < 128 {
                    sawTransparency = true
                    if i == next { next += sampleStride }
                    continue
                }
                guard i == next else { continue }
                next += sampleStride
                var key = UInt32(pixels[p]) | UInt32(pixels[p + 1]) << 8 | UInt32(pixels[p + 2]) << 16
                if posterized { key = Self.posterize(key) }
                counts[key, default: 0] += 1
                if !posterized, counts.count > Self.capacity { rebucket() }
            }
            return sawTransparency
        }

        func entries() -> [WeightedRGB] {
            counts.map { key, count in
                WeightedRGB(
                    r: UInt8(truncatingIfNeeded: key),
                    g: UInt8(truncatingIfNeeded: key >> 8),
                    b: UInt8(truncatingIfNeeded: key >> 16),
                    count: count)
            }
        }

        /// 5 significant bits per channel, replicated so 0 and 255 stay exact
        /// (same escape hatch as the PNG quantizer's histogram).
        private static func posterizeChannel(_ value: UInt32) -> UInt32 {
            (value & 0xF8) | (value >> 5)
        }

        private static func posterize(_ key: UInt32) -> UInt32 {
            posterizeChannel(key & 0xFF)
                | posterizeChannel((key >> 8) & 0xFF) << 8
                | posterizeChannel((key >> 16) & 0xFF) << 16
        }

        /// Photographic overflow: collapse the exact histogram onto the
        /// posterized key space in place and keep going — no re-decode.
        private mutating func rebucket() {
            posterized = true
            var rebucketed: [UInt32: Int] = Dictionary(minimumCapacity: counts.count / 2)
            for (key, count) in counts {
                rebucketed[Self.posterize(key), default: 0] += count
            }
            counts = rebucketed
        }
    }

    // MARK: - Median cut (RGB flavor of the PNG quantizer)

    private struct Box {
        var start: Int
        var count: Int
        var population: Int
        /// 0=r 1=g 2=b of the widest channel, and its range.
        var widestChannel: Int
        var range: Int
    }

    private static func makeBox(_ colors: [WeightedRGB], start: Int, count: Int) -> Box {
        var minR = 255, minG = 255, minB = 255
        var maxR = 0, maxG = 0, maxB = 0
        var population = 0
        for i in start..<(start + count) {
            let c = colors[i]
            minR = min(minR, Int(c.r)); maxR = max(maxR, Int(c.r))
            minG = min(minG, Int(c.g)); maxG = max(maxG, Int(c.g))
            minB = min(minB, Int(c.b)); maxB = max(maxB, Int(c.b))
            population += c.count
        }
        var widest = 0
        var range = maxR - minR
        if maxG - minG > range { widest = 1; range = maxG - minG }
        if maxB - minB > range { widest = 2; range = maxB - minB }
        return Box(start: start, count: count, population: population, widestChannel: widest, range: range)
    }

    private static func channel(_ c: WeightedRGB, _ index: Int) -> Int {
        switch index {
        case 0: return Int(c.r)
        case 1: return Int(c.g)
        default: return Int(c.b)
        }
    }

    private static func medianCut(_ colors: inout [WeightedRGB], maxColors: Int) -> [WeightedRGB] {
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
            var sumR = 0, sumG = 0, sumB = 0
            var population = 0
            for i in box.start..<(box.start + box.count) {
                let c = colors[i]
                sumR += Int(c.r) * c.count
                sumG += Int(c.g) * c.count
                sumB += Int(c.b) * c.count
                population += c.count
            }
            let divisor = max(population, 1)
            return WeightedRGB(
                r: UInt8((sumR + divisor / 2) / divisor),
                g: UInt8((sumG + divisor / 2) / divisor),
                b: UInt8((sumB + divisor / 2) / divisor),
                count: population)
        }
    }

    // MARK: - Palette mapping (pass 2)

    /// Nearest-palette mapping with Bayer ordered dithering. The threshold
    /// offset depends only on pixel coordinates, so an unchanged source pixel
    /// always maps to the same index — no inter-frame shimmer, clean deltas.
    /// Nearest lookups are cached per post-dither color (flat regions
    /// collapse onto a handful of cache entries).
    private struct Mapper {
        private let palette: [SIMD3<Int32>]
        private let exactLookup: [UInt32: UInt8]
        private let spread: Double
        private var cache: [UInt32: UInt8]

        private static let bayer: [Int32] = [
             0, 32,  8, 40,  2, 34, 10, 42,
            48, 16, 56, 24, 50, 18, 58, 26,
            12, 44,  4, 36, 14, 46,  6, 38,
            60, 28, 52, 20, 62, 30, 54, 22,
             3, 35, 11, 43,  1, 33,  9, 41,
            51, 19, 59, 27, 49, 17, 57, 25,
            15, 47,  7, 39, 13, 45,  5, 37,
            63, 31, 55, 23, 61, 29, 53, 21,
        ]

        init(palette entries: [WeightedRGB], direct: Bool) {
            palette = entries.map { SIMD3(Int32($0.r), Int32($0.g), Int32($0.b)) }
            var lookup: [UInt32: UInt8] = [:]
            if direct {
                lookup.reserveCapacity(entries.count)
                for (i, entry) in entries.enumerated() {
                    lookup[UInt32(entry.r) | UInt32(entry.g) << 8 | UInt32(entry.b) << 16] = UInt8(i)
                }
            }
            exactLookup = lookup
            // Undithered when the palette is unreduced; otherwise scale the
            // dither amplitude down as the palette grows denser.
            spread = direct ? 0 : 60.0 / cbrt(Double(entries.count))
            cache = Dictionary(minimumCapacity: 1 << 12)
        }

        mutating func index(r: Int32, g: Int32, b: Int32, x: Int, y: Int) -> UInt8 {
            var rr = r, gg = g, bb = b
            if spread > 0 {
                let cell = Double(Self.bayer[((y & 7) << 3) | (x & 7)])
                let offset = Int32((((cell + 0.5) / 64.0 - 0.5) * spread).rounded())
                rr = min(255, max(0, r + offset))
                gg = min(255, max(0, g + offset))
                bb = min(255, max(0, b + offset))
            }
            let key = UInt32(rr) | UInt32(gg) << 8 | UInt32(bb) << 16
            if let hit = cache[key] { return hit }
            if let hit = exactLookup[key] {
                cache[key] = hit
                return hit
            }
            let target = SIMD3<Int32>(rr, gg, bb)
            var best = 0
            var bestDistance = Int32.max
            for (i, entry) in palette.enumerated() {
                let d = entry &- target
                let distance = d.x * d.x + d.y * d.y + d.z * d.z
                if distance < bestDistance {
                    bestDistance = distance
                    best = i
                }
            }
            let result = UInt8(best)
            // Photographic sources can produce millions of distinct
            // post-dither colors; keep the cache bounded (PNGCoder does the
            // same for its dithered remap).
            if cache.count >= 1 << 18 { cache.removeAll(keepingCapacity: true) }
            cache[key] = result
            return result
        }
    }

    // MARK: - LZW (GIF variant, giflib-compatible growth/clear rules)

    private static func lzwEncode(_ pixels: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clearCode = 1 << minCodeSize
        let endCode = clearCode + 1
        var out = [UInt8]()
        out.reserveCapacity(pixels.count / 2 + 16)
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var codeSize = minCodeSize + 1
        var nextCode = endCode + 1
        var table = [UInt32: Int](minimumCapacity: 1 << 12)

        func emit(_ code: Int) {
            bitBuffer |= UInt32(code) << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
            // Width grows once the next code to assign no longer fits —
            // checked after output, mirroring giflib's decoder expectations.
            if nextCode >= (1 << codeSize), codeSize < 12 {
                codeSize += 1
            }
        }

        emit(clearCode)
        guard let first = pixels.first else {
            emit(endCode)
            if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
            return out
        }
        var current = Int(first)
        for i in 1..<pixels.count {
            let pixel = Int(pixels[i])
            let key = UInt32(current) << 8 | UInt32(pixel)
            if let code = table[key] {
                current = code
            } else {
                emit(current)
                if nextCode >= 4095 {
                    emit(clearCode)
                    table.removeAll(keepingCapacity: true)
                    nextCode = endCode + 1
                    codeSize = minCodeSize + 1
                } else {
                    table[key] = nextCode
                    nextCode += 1
                }
                current = pixel
            }
        }
        emit(current)
        emit(endCode)
        if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
        return out
    }

    // MARK: - Container writer

    private struct GIFWriter {
        private(set) var data = Data()
        private let tableBits: Int

        init(width: Int, height: Int, paletteRGB: [UInt8], tableBits: Int, backgroundIndex: UInt8) {
            self.tableBits = tableBits
            data.reserveCapacity(1 << 16)
            data.append(contentsOf: Array("GIF89a".utf8))
            Self.appendUInt16(&data, width)
            Self.appendUInt16(&data, height)
            // Global color table, 8-bit color resolution, size 2^tableBits.
            data.append(UInt8(0xF0 | (tableBits - 1)))
            data.append(backgroundIndex)
            data.append(0) // square pixels
            data.append(contentsOf: paletteRGB)
            let padding = (1 << tableBits) * 3 - paletteRGB.count
            if padding > 0 { data.append(contentsOf: [UInt8](repeating: 0, count: padding)) }
        }

        mutating func appendNetscapeLoop(_ count: Int) {
            data.append(contentsOf: [0x21, 0xFF, 0x0B])
            data.append(contentsOf: Array("NETSCAPE2.0".utf8))
            data.append(contentsOf: [0x03, 0x01])
            Self.appendUInt16(&data, max(0, min(65535, count)))
            data.append(0x00)
        }

        mutating func appendGraphicControl(delayCS: Int, disposal: UInt8, transparentIndex: UInt8?) {
            data.append(contentsOf: [0x21, 0xF9, 0x04])
            data.append(disposal << 2 | (transparentIndex != nil ? 1 : 0))
            Self.appendUInt16(&data, delayCS)
            data.append(transparentIndex ?? 0)
            data.append(0x00)
        }

        mutating func appendImage(x: Int, y: Int, width: Int, height: Int, indices: [UInt8], minCodeSize: Int) {
            data.append(0x2C)
            Self.appendUInt16(&data, x)
            Self.appendUInt16(&data, y)
            Self.appendUInt16(&data, width)
            Self.appendUInt16(&data, height)
            data.append(0x00) // no local color table, not interlaced
            data.append(UInt8(minCodeSize))
            let encoded = GIFCoder.lzwEncode(indices, minCodeSize: minCodeSize)
            var i = 0
            while i < encoded.count {
                let n = min(255, encoded.count - i)
                data.append(UInt8(n))
                data.append(contentsOf: encoded[i..<(i + n)])
                i += n
            }
            data.append(0x00) // block terminator
        }

        mutating func finish() {
            data.append(0x3B)
        }

        private static func appendUInt16(_ data: inout Data, _ value: Int) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
    }
}
