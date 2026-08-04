import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import eddy

/// Acceptance suite for GIF support (docs/specs/gif-support.md), asserted
/// entirely at the highest seam — `Compressor.optimize` (file in, file out).
/// Invariants under any slider/width setting: frame count, per-frame delays,
/// loop count, transparency, decodability, keep-if-smaller. Sample matrix:
/// bloated typical animation (ImageIO-encoded, deliberately unoptimized),
/// transparent sticker, static single frame, and a hand-crafted stubborn
/// already-optimal file.
final class GIFCompressionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eddy-gif-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Conversion exemption (ticket 01)

    func testAnimatedAssetIsExemptFromConversion() throws {
        let url = tempDir.appendingPathComponent("animated.gif")
        try writeGIF(frames: movingSquareFrames(count: 4), delays: [0.1, 0.1, 0.1, 0.1], loopCount: 0, to: url)
        let originalInfo = try gifInfo(url)

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .png)

        XCTAssertEqual(outcome.outputURL.pathExtension.lowercased(), "gif",
                       "animated assets must never be flattened by a format conversion")
        XCTAssertEqual(outcome.outputURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let info = try gifInfo(outcome.outputURL)
        XCTAssertEqual(info.frameCount, originalInfo.frameCount)
    }

    func testStaticGIFStillConvertsToPNG() throws {
        let url = tempDir.appendingPathComponent("static.gif")
        try writeGIF(frames: movingSquareFrames(count: 1), delays: [0.1], loopCount: nil, to: url)

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .png)

        XCTAssertEqual(outcome.outputURL.pathExtension.lowercased(), "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "conversion replaces the original next to where it lived")
    }

    // MARK: - Timing, loop count, pixel fidelity

    func testTimingLoopAndPixelsSurviveRecompression() throws {
        let url = tempDir.appendingPathComponent("moving.gif")
        let delays = [0.1, 0.2, 0.3, 0.1, 0.2, 0.3, 0.1, 0.2]
        try writeGIF(frames: movingSquareFrames(count: 8), delays: delays, loopCount: 3, to: url)
        let inputFrames = try (0..<8).map { try frameRGBA(url, index: $0) }

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .keep)

        XCTAssertTrue(outcome.replaced, "an ImageIO-encoded original is bloated; the new encoder must beat it")
        let info = try gifInfo(url)
        XCTAssertEqual(info.frameCount, 8)
        XCTAssertEqual(info.loopCount, 3)
        for (index, delay) in delays.enumerated() {
            XCTAssertEqual(info.delays[index], delay, accuracy: 0.011, "frame \(index) delay drifted")
        }
        // Few flat colors → the exact-mapping path: composited pixels must
        // round-trip identically, frame by frame.
        for index in 0..<8 {
            XCTAssertEqual(try frameRGBA(url, index: index), inputFrames[index],
                           "frame \(index) pixels changed")
        }
    }

    func testIdenticalFramesKeepTheirDelays() throws {
        let url = tempDir.appendingPathComponent("still.gif")
        let frame = movingSquareFrames(count: 1)[0]
        try writeGIF(frames: [frame, frame, frame], delays: [0.1, 0.2, 0.3], loopCount: 0, to: url)

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .keep)

        XCTAssertTrue(outcome.replaced)
        let info = try gifInfo(url)
        XCTAssertEqual(info.frameCount, 3, "identical frames still carry their delays and must not be merged")
        XCTAssertEqual(info.delays[0], 0.1, accuracy: 0.011)
        XCTAssertEqual(info.delays[1], 0.2, accuracy: 0.011)
        XCTAssertEqual(info.delays[2], 0.3, accuracy: 0.011)
        XCTAssertEqual(info.loopCount, 0)
    }

    // MARK: - Compression effect (ticket 07 red line)

    func testCompressionBeatsBloatedOriginalByTwentyPercent() throws {
        let url = tempDir.appendingPathComponent("bloated.gif")
        try writeGIF(frames: movingSquareFrames(count: 8),
                     delays: Array(repeating: 0.1, count: 8), loopCount: 0, to: url)

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .keep)

        XCTAssertTrue(outcome.replaced)
        XCTAssertLessThanOrEqual(
            Double(outcome.finalBytes), Double(outcome.originalBytes) * 0.8,
            "static background + small moving region must shrink ≥ 20% at the default slider")
    }

    func testLowerQualityIsNeverBigger() throws {
        let lowURL = tempDir.appendingPathComponent("noisy-low.gif")
        let highURL = tempDir.appendingPathComponent("noisy-high.gif")
        let frames = noisyFrames(count: 4)
        let delays = Array(repeating: 0.1, count: 4)
        try writeGIF(frames: frames, delays: delays, loopCount: 0, to: lowURL)
        try writeGIF(frames: frames, delays: delays, loopCount: 0, to: highURL)

        let low = try Compressor.optimize(fileURL: lowURL, quality: 0.3, format: .keep)
        let high = try Compressor.optimize(fileURL: highURL, quality: 0.9, format: .keep)

        XCTAssertLessThanOrEqual(low.finalBytes, high.finalBytes,
                                 "the slider's two levers must not invert: lower quality ⇒ no bigger")
        for url in [lowURL, highURL] {
            let info = try gifInfo(url)
            XCTAssertEqual(info.frameCount, 4)
            for delay in info.delays { XCTAssertEqual(delay, 0.1, accuracy: 0.011) }
        }
    }

    // MARK: - Transparency and disposal

    func testTransparencySurvivesIncludingVanishingPixels() throws {
        let url = tempDir.appendingPathComponent("sticker.gif")
        let delays = [0.1, 0.1, 0.1, 0.1]
        try writeGIF(frames: stickerFrames(count: 4), delays: delays, loopCount: 0, to: url)
        let inputFrames = try (0..<4).map { try frameRGBA(url, index: $0) }

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .keep)

        XCTAssertTrue(outcome.replaced)
        let info = try gifInfo(url)
        XCTAssertEqual(info.frameCount, 4)
        for index in 0..<4 {
            let output = try frameRGBA(url, index: index)
            // Exact path (two colors): composited pixels must round-trip
            // identically — including pixels that TURN transparent when the
            // square moves away (the dispose-to-background case).
            XCTAssertEqual(output, inputFrames[index], "frame \(index) pixels changed")
            XCTAssertEqual(output[3], 0, "corner must stay transparent in frame \(index)")
        }
        // The moving square makes old positions transparent again — assert
        // the case explicitly so a delta/disposal regression can't hide.
        let frame1 = try frameRGBA(url, index: 1)
        let width = 64
        let oldCenter = ((24 + 8) * width + (4 + 8)) * 4     // square center in frame 0
        let newCenter = ((24 + 8) * width + (16 + 8)) * 4    // square center in frame 1
        XCTAssertEqual(frame1[oldCenter + 3], 0, "vacated square position must be transparent")
        XCTAssertEqual(frame1[newCenter + 3], 255, "current square position must be opaque")
    }

    // MARK: - Resize (ticket 06)

    func testResizeAppliesToWholeCanvas() throws {
        let url = tempDir.appendingPathComponent("resize.gif")
        let delays = [0.1, 0.2, 0.1, 0.2]
        try writeGIF(frames: movingSquareFrames(count: 4), delays: delays, loopCount: 0, to: url)

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, maxWidth: 80, format: .keep)

        XCTAssertTrue(outcome.replaced)
        let info = try gifInfo(url)
        XCTAssertEqual(info.width, 80)
        XCTAssertEqual(info.height, 60, "aspect ratio must be kept (160×120 → 80×60)")
        XCTAssertEqual(info.frameCount, 4)
        for (index, delay) in delays.enumerated() {
            XCTAssertEqual(info.delays[index], delay, accuracy: 0.011)
        }
        // Every frame decodes at the scaled canvas size — no mixed geometry.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        for index in 0..<4 {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(frame.width, 80, "frame \(index) width")
            XCTAssertEqual(frame.height, 60, "frame \(index) height")
        }
    }

    func testResizeNeverUpscales() throws {
        let url = tempDir.appendingPathComponent("noupscale.gif")
        try writeGIF(frames: movingSquareFrames(count: 4),
                     delays: Array(repeating: 0.1, count: 4), loopCount: 0, to: url)

        _ = try Compressor.optimize(fileURL: url, quality: 0.8, maxWidth: 400, format: .keep)

        let info = try gifInfo(url)
        XCTAssertEqual(info.width, 160, "maxWidth above the canvas width must not upscale")
        XCTAssertEqual(info.height, 120)
    }

    // MARK: - Stubborn already-optimal file (ticket 07)

    func testStubbornOptimizedGIFIsNeverHarmed() throws {
        let url = tempDir.appendingPathComponent("stubborn.gif")
        try Data(Self.stubbornGIF).write(to: url)

        let outcome = try Compressor.optimize(fileURL: url, quality: 0.8, format: .keep)

        XCTAssertLessThanOrEqual(outcome.finalBytes, outcome.originalBytes, "must never grow")
        if !outcome.replaced {
            XCTAssertEqual(try Data(contentsOf: url), Data(Self.stubbornGIF),
                           "an unbeaten original must stay byte-identical")
        }
        // Replaced or not, the surviving file must be a healthy animation.
        let info = try gifInfo(url)
        XCTAssertEqual(info.frameCount, 2)
        XCTAssertEqual(info.loopCount, 0)
        XCTAssertEqual(info.delays[0], 0.1, accuracy: 0.011)
        XCTAssertEqual(info.delays[1], 0.1, accuracy: 0.011)
    }

    /// Hand-crafted 87-byte 2×2 two-frame checkerboard flip — already near
    /// the format's floor, the "deeply optimized" stand-in. Byte-for-byte:
    /// header, 2-entry palette, infinite Netscape loop, two 0.1s frames.
    private static let stubbornGIF: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61,             // "GIF89a"
        0x02, 0x00, 0x02, 0x00,                         // canvas 2×2
        0xF0, 0x00, 0x00,                               // GCT, 2 entries; bg 0; square pixels
        0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF,             // black, white
        0x21, 0xFF, 0x0B,                               // application extension
        0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, // "NETSCAPE"
        0x32, 0x2E, 0x30,                               // "2.0"
        0x03, 0x01, 0x00, 0x00, 0x00,                   // loop forever
        0x21, 0xF9, 0x04, 0x04, 0x0A, 0x00, 0x00, 0x00, // GCE: keep, 10 cs
        0x2C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, // full 2×2
        0x02, 0x03, 0x44, 0x02, 0x05, 0x00,             // LZW: 0,1,1,0
        0x21, 0xF9, 0x04, 0x04, 0x0A, 0x00, 0x00, 0x00, // GCE: keep, 10 cs
        0x2C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, // full 2×2
        0x02, 0x03, 0x0C, 0x10, 0x05, 0x00,             // LZW: 1,0,0,1
        0x3B,                                           // trailer
    ]

    // MARK: - Sample builders

    /// 160×120, 12 flat background bands + a red 24×24 square stepping right.
    /// Few colors → exercises the exact-mapping (lossless) path; a static
    /// background with a small moving region is the delta encoder's home turf.
    private func movingSquareFrames(count: Int) -> [CGImage] {
        let width = 160, height = 120
        let bands: [[UInt8]] = [
            [40, 40, 40], [70, 60, 50], [100, 90, 80], [130, 120, 110],
            [160, 150, 140], [190, 180, 170], [220, 210, 200], [250, 240, 230],
            [50, 80, 110], [80, 110, 140], [110, 140, 170], [140, 170, 200],
        ]
        return (0..<count).map { frame in
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let band = bands[(x / 14) % bands.count]
                    let i = (y * width + x) * 4
                    rgba[i] = band[0]
                    rgba[i + 1] = band[1]
                    rgba[i + 2] = band[2]
                }
            }
            let squareX = 8 + frame * 15
            for y in 40..<64 {
                for x in squareX..<(squareX + 24) where x < width {
                    let i = (y * width + x) * 4
                    rgba[i] = 255; rgba[i + 1] = 0; rgba[i + 2] = 0
                }
            }
            return makeImage(width: width, height: height, rgba: rgba)!
        }
    }

    /// 64×64 transparent canvas, an opaque red 16×16 square stepping right —
    /// pixels turn transparent again when the square vacates a position.
    private func stickerFrames(count: Int) -> [CGImage] {
        let width = 64, height = 64
        return (0..<count).map { frame in
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let squareX = 4 + frame * 12
            for y in 24..<40 {
                for x in squareX..<(squareX + 16) where x < width {
                    let i = (y * width + x) * 4
                    rgba[i] = 255; rgba[i + 1] = 0; rgba[i + 2] = 0; rgba[i + 3] = 255
                }
            }
            return makeImage(width: width, height: height, rgba: rgba)!
        }
    }

    /// 128×96 gradient with deterministic per-frame noise — thousands of
    /// colors, forcing median cut + dithering; the inter-frame noise is what
    /// lossy snapping exists to absorb.
    private func noisyFrames(count: Int) -> [CGImage] {
        let width = 128, height = 96
        return (0..<count).map { frame in
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    var state = UInt32(truncatingIfNeeded: x &+ y &* 131 &+ frame &* 31337)
                    state = state &* 1_103_515_245 &+ 12345
                    let noise = Int((state >> 16) & 0x0F) - 8
                    let i = (y * width + x) * 4
                    rgba[i] = UInt8(max(0, min(255, x * 2 + noise)))
                    rgba[i + 1] = UInt8(max(0, min(255, y * 2 + noise)))
                    rgba[i + 2] = UInt8(max(0, min(255, (x + y) + noise)))
                }
            }
            return makeImage(width: width, height: height, rgba: rgba)!
        }
    }

    // MARK: - GIF I/O helpers

    private func makeImage(width: Int, height: Int, rgba: [UInt8]) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        rgba.withUnsafeBytes { source in
            context.data!.copyMemory(from: source.baseAddress!, byteCount: rgba.count)
        }
        return context.makeImage()
    }

    /// Deliberately encodes through ImageIO's GIF destination: full frames,
    /// no cross-frame optimization — a faithful stand-in for an unoptimized
    /// real-world GIF.
    private func writeGIF(frames: [CGImage], delays: [Double], loopCount: Int?, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil))
        if let loopCount {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]
            ] as CFDictionary)
        }
        for (frame, delay) in zip(frames, delays) {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private struct GIFInfo {
        var frameCount: Int
        var delays: [Double]
        var loopCount: Int?
        var width: Int
        var height: Int
    }

    private func gifInfo(_ url: URL) throws -> GIFInfo {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "output must stay decodable")
        let count = CGImageSourceGetCount(source)
        XCTAssertGreaterThan(count, 0, "output must stay decodable")
        var delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            delays.append(unclamped ?? clamped ?? -1)
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gifContainer = container?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loop = (gifContainer?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
        let frame0 = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (frame0?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (frame0?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return GIFInfo(frameCount: count, delays: delays, loopCount: loop, width: width, height: height)
    }

    /// Composited straight-RGBA pixels of one frame, as a viewer sees them.
    private func frameRGBA(_ url: URL, index: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
        let buffer = try XCTUnwrap(RGBABuffer(image: image))
        return Array(UnsafeBufferPointer(start: buffer.pixels, count: buffer.width * buffer.height * 4))
    }
}
