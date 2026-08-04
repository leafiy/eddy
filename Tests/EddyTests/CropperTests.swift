import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import eddy

final class CropperTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - Static crops

    /// Shrinking selection: pure trim, output is exactly the selected pixels.
    func testTrimCropKeepsSelectedQuadrant() throws {
        // 8×8: left half red, right half blue.
        let image = try XCTUnwrap(makeImage(width: 8, height: 8) { x, _ in
            x < 4 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        })
        let file = try writePNG(image, name: "trim.png")

        let result = try Cropper.crop(
            fileURL: file,
            spec: CropSpec(rect: CGRect(x: 4, y: 0, width: 4, height: 8), background: nil, border: false, shadow: false),
            quality: 1.0
        )

        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 8)
        let decoded = try XCTUnwrap(decodeRGBA(file))
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 8)
        for i in stride(from: 0, to: decoded.rgba.count, by: 4) {
            XCTAssertEqual(Array(decoded.rgba[i..<i + 4]), [0, 0, 255, 255], "every kept pixel is from the blue half")
        }
    }

    /// Growing selection: the overhang is painted with the Extension Background.
    func testExpandCropFillsExtensionBackground() throws {
        let image = try XCTUnwrap(makeImage(width: 4, height: 4) { _, _ in (255, 0, 0, 255) })
        let file = try writePNG(image, name: "expand.png")

        let result = try Cropper.crop(
            fileURL: file,
            spec: CropSpec(
                rect: CGRect(x: -2, y: -2, width: 8, height: 8),
                background: CGColor(gray: 1, alpha: 1),
                border: false,
                shadow: false
            ),
            quality: 1.0
        )

        XCTAssertEqual(result.width, 8)
        XCTAssertEqual(result.height, 8)
        let decoded = try XCTUnwrap(decodeRGBA(file))
        XCTAssertEqual(pixel(decoded, x: 0, y: 0), [255, 255, 255, 255], "corner is background")
        XCTAssertEqual(pixel(decoded, x: 7, y: 7), [255, 255, 255, 255], "corner is background")
        XCTAssertEqual(pixel(decoded, x: 4, y: 4), [255, 0, 0, 255], "center keeps the image")
    }

    /// Transparent Extension Background stays transparent in alpha-capable formats.
    func testExpandCropWithTransparentBackground() throws {
        let image = try XCTUnwrap(makeImage(width: 4, height: 4) { _, _ in (0, 255, 0, 255) })
        let file = try writePNG(image, name: "transparent.png")

        _ = try Cropper.crop(
            fileURL: file,
            spec: CropSpec(
                rect: CGRect(x: -2, y: -2, width: 8, height: 8),
                background: nil,
                border: false,
                shadow: false
            ),
            quality: 1.0
        )

        let decoded = try XCTUnwrap(decodeRGBA(file))
        XCTAssertEqual(pixel(decoded, x: 0, y: 0)[3], 0, "overhang is transparent")
        XCTAssertEqual(pixel(decoded, x: 4, y: 4), [0, 255, 0, 255], "image pixels stay opaque")
    }

    /// Crop saves in place: same path, no side files left behind.
    func testCropReplacesFileInPlace() throws {
        let image = try XCTUnwrap(makeImage(width: 4, height: 4) { _, _ in (1, 2, 3, 255) })
        let file = try writePNG(image, name: "inplace.png")

        _ = try Cropper.crop(
            fileURL: file,
            spec: CropSpec(rect: CGRect(x: 0, y: 0, width: 2, height: 2), background: nil, border: false, shadow: false),
            quality: 1.0
        )

        let siblings = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
        XCTAssertEqual(siblings.sorted(), ["inplace.png"], "no staging residue")
    }

    // MARK: - Animated Asset invariants

    /// Animated GIFs are cropped frame by frame: frame count, per-frame
    /// delays, and loop count survive; every frame gets the same canvas.
    func testAnimatedGIFCropPreservesFramesTimingAndLoop() throws {
        let delays = [0.2, 0.3, 0.4]
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)]
        let file = try writeAnimatedGIF(name: "anim.gif", size: 6, colors: colors, delays: delays, loopCount: 2)

        let result = try Cropper.crop(
            fileURL: file,
            spec: CropSpec(
                rect: CGRect(x: 1, y: 1, width: 4, height: 4),
                background: CGColor(gray: 1, alpha: 1),
                border: false,
                shadow: false
            ),
            quality: 0.8
        )
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3, "frame count is untouchable")

        let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let containerGIF = containerProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual((containerGIF?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 2)

        for (index, expected) in delays.enumerated() {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            XCTAssertEqual(try XCTUnwrap(delay), expected, accuracy: 0.011, "frame \(index) delay is preserved")

            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(frame.width, 4)
            XCTAssertEqual(frame.height, 4)
        }
    }

    // MARK: - Helpers

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let (r, g, b, a) = pixel(x, y)
                // Premultiply: CGContext with premultipliedLast expects it.
                let alpha = Int(a)
                data[i] = UInt8(Int(r) * alpha / 255)
                data[i + 1] = UInt8(Int(g) * alpha / 255)
                data[i + 2] = UInt8(Int(b) * alpha / 255)
                data[i + 3] = a
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    private func writePNG(_ image: CGImage, name: String) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func writeAnimatedGIF(
        name: String,
        size: Int,
        colors: [(UInt8, UInt8, UInt8, UInt8)],
        delays: [Double],
        loopCount: Int
    ) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, colors.count, nil))
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
        )
        for (color, delay) in zip(colors, delays) {
            let frame = try XCTUnwrap(makeImage(width: size, height: size) { _, _ in color })
            let properties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ]
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func decodeRGBA(_ url: URL) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let buffer = RGBABuffer(image: image)
        else { return nil }
        let rgba = Array(UnsafeBufferPointer(start: buffer.pixels, count: buffer.width * buffer.height * 4))
        return (buffer.width, buffer.height, rgba)
    }

    private func pixel(_ decoded: (width: Int, height: Int, rgba: [UInt8]), x: Int, y: Int) -> [UInt8] {
        let i = (y * decoded.width + x) * 4
        return Array(decoded.rgba[i..<i + 4])
    }
}
