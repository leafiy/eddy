import CoreGraphics
import Foundation
import XCTest
@testable import eddy

final class AnimatedWebPTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eddy-webp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testFramesTimingLoopAndTransparencyRoundTrip() throws {
        let durations = [80, 140, 250]
        let frames = movingTransparentSquareFrames(width: 20, height: 12, count: 3)
        let data = try AnimatedWebPCoder.encode(
            frames: frames,
            durationsMilliseconds: durations,
            loopCount: 4,
            quality: 1.0
        )

        let decoded = try AnimatedWebPCoder.decode(data)

        XCTAssertEqual(decoded.frames.count, 3)
        XCTAssertEqual(decoded.durationsMilliseconds, durations)
        XCTAssertEqual(decoded.loopCount, 4)
        XCTAssertEqual(decoded.width, 20)
        XCTAssertEqual(decoded.height, 12)
        for (index, frame) in decoded.frames.enumerated() {
            XCTAssertEqual(alpha(frame, x: 0, y: 0), 0, "frame \(index) transparent corner")
        }
        // The old square position becomes transparent again after it moves.
        XCTAssertEqual(alpha(decoded.frames[1], x: 3, y: 6), 0)
        XCTAssertEqual(alpha(decoded.frames[1], x: 9, y: 6), 255)
    }

    func testIdenticalFramesAreNotMerged() throws {
        let frame = solidFrame(width: 10, height: 8, rgba: (30, 120, 220, 255))
        let durations = [50, 125, 300]
        let data = try AnimatedWebPCoder.encode(
            frames: [frame, frame, frame],
            durationsMilliseconds: durations,
            loopCount: 0,
            quality: 0.8
        )
        let url = tempDirectory.appendingPathComponent("identical.webp")
        try data.write(to: url)
        let recompressed = try AnimatedWebPCoder.recompress(
            fileURL: url,
            quality: 0.5,
            maxWidth: 0
        )

        let decoded = try AnimatedWebPCoder.decode(recompressed)

        XCTAssertEqual(decoded.frames.count, 3)
        XCTAssertEqual(decoded.durationsMilliseconds, durations)
        XCTAssertEqual(decoded.loopCount, 0)
    }

    func testCompressorResizesWholeAnimationAndPreservesFormat() throws {
        let url = tempDirectory.appendingPathComponent("resize.webp")
        let frames = noisyFrames(width: 40, height: 30, count: 4)
        let durations = [70, 90, 110, 130]
        try AnimatedWebPCoder.encode(
            frames: frames,
            durationsMilliseconds: durations,
            loopCount: 2,
            quality: 1.0
        ).write(to: url)

        let outcome = try Compressor.optimize(
            fileURL: url,
            quality: 0.45,
            maxWidth: 10,
            format: .png
        )

        XCTAssertTrue(outcome.replaced)
        XCTAssertEqual(outcome.outputURL, url)
        XCTAssertEqual(outcome.outputURL.pathExtension.lowercased(), "webp")
        let decoded = try AnimatedWebPCoder.decode(url)
        XCTAssertEqual(decoded.width, 10)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.frames.count, 4)
        XCTAssertEqual(decoded.durationsMilliseconds, durations)
        XCTAssertEqual(decoded.loopCount, 2)
    }

    func testCropAndRotatePreserveAnimation() throws {
        let url = tempDirectory.appendingPathComponent("edit.webp")
        let durations = [60, 120, 180]
        try AnimatedWebPCoder.encode(
            frames: movingTransparentSquareFrames(width: 20, height: 12, count: 3),
            durationsMilliseconds: durations,
            loopCount: 3,
            quality: 1.0
        ).write(to: url)

        let result = try Cropper.crop(
            fileURL: url,
            spec: CropSpec(
                // Source rotates from 20×12 to 12×20, then trims its width.
                rect: CGRect(x: 1, y: 0, width: 10, height: 20),
                background: nil,
                border: false,
                shadow: false,
                rotation: .right
            ),
            quality: 0.9
        )

        XCTAssertEqual(result.outputURL, url)
        XCTAssertTrue(Cropper.isAnimated(url))
        let decoded = try AnimatedWebPCoder.decode(url)
        XCTAssertEqual(decoded.width, 10)
        XCTAssertEqual(decoded.height, 20)
        XCTAssertEqual(decoded.frames.count, 3)
        XCTAssertEqual(decoded.durationsMilliseconds, durations)
        XCTAssertEqual(decoded.loopCount, 3)
    }

    func testLowerQualityIsNotLargerAndNeverUpscales() throws {
        let url = tempDirectory.appendingPathComponent("quality.webp")
        let frames = noisyFrames(width: 24, height: 18, count: 4)
        let durations = [100, 100, 100, 100]
        try AnimatedWebPCoder.encode(
            frames: frames,
            durationsMilliseconds: durations,
            loopCount: 0,
            quality: 1.0
        ).write(to: url)

        let low = try AnimatedWebPCoder.recompress(
            fileURL: url,
            quality: 0.3,
            maxWidth: 100
        )
        let high = try AnimatedWebPCoder.recompress(
            fileURL: url,
            quality: 0.9,
            maxWidth: 100
        )

        XCTAssertLessThanOrEqual(low.count, high.count)
        for data in [low, high] {
            let decoded = try AnimatedWebPCoder.decode(data)
            XCTAssertEqual(decoded.width, 24, "max width must never upscale")
            XCTAssertEqual(decoded.height, 18)
            XCTAssertEqual(decoded.frames.count, 4)
            XCTAssertEqual(decoded.durationsMilliseconds, durations)
        }
    }

    // MARK: - Samples

    private func solidFrame(
        width: Int,
        height: Int,
        rgba: (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage {
        makeImage(width: width, height: height) { _, _ in rgba }
    }

    private func movingTransparentSquareFrames(
        width: Int,
        height: Int,
        count: Int
    ) -> [CGImage] {
        (0..<count).map { frame in
            makeImage(width: width, height: height) { x, y in
                let startX = 2 + frame * 6
                if x >= startX, x < min(startX + 4, width), y >= 4, y < 9 {
                    return (230, 50, 30, 255)
                }
                return (0, 0, 0, 0)
            }
        }
    }

    private func noisyFrames(width: Int, height: Int, count: Int) -> [CGImage] {
        (0..<count).map { frame in
            makeImage(width: width, height: height) { x, y in
                let seed = UInt32((frame + 1) * 1_103 + x * 313 + y * 911)
                return (
                    UInt8(truncatingIfNeeded: seed &* 17),
                    UInt8(truncatingIfNeeded: seed &* 43),
                    UInt8(truncatingIfNeeded: seed &* 97),
                    255
                )
            }
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let (red, green, blue, alpha) = pixel(x, y)
                let a = UInt32(alpha)
                data[index] = UInt8(UInt32(red) * a / 255)
                data[index + 1] = UInt8(UInt32(green) * a / 255)
                data[index + 2] = UInt8(UInt32(blue) * a / 255)
                data[index + 3] = alpha
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return data.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let buffer = RGBABuffer(image: image)!
        return buffer.pixels[(y * buffer.width + x) * 4 + 3]
    }
}
