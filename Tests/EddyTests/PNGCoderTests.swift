import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import eddy

final class PNGCoderTests: XCTestCase {

    /// Images that already fit the palette must survive a byte-exact
    /// round trip (the lossless screenshot fast path).
    func testFewColorImageRoundTripsLosslessly() throws {
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colors: [[UInt8]] = [
            [255, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 128, 255],
            [0, 0, 0, 0], // fully transparent
        ]
        for i in 0..<(width * height) {
            let color = colors[i % colors.count]
            pixels.replaceSubrange(i * 4..<(i * 4 + 4), with: color)
        }
        let image = try XCTUnwrap(makeImage(width: width, height: height, rgba: pixels))

        let png = try PNGCoder.quantizedPNG(from: image, quality: 1.0)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(png[png.startIndex + 25], 3, "expected indexed-color PNG (color type 3)")

        let decoded = try XCTUnwrap(decodeRGBA(png))
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.rgba, pixels)
    }

    /// A many-color gradient must still quantize into a valid indexed PNG
    /// with at most 256 palette entries and matching dimensions.
    func testManyColorImageQuantizesToIndexedPNG() throws {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 4)
                pixels[i + 1] = UInt8(y * 4)
                pixels[i + 2] = UInt8((x * y) % 256)
                pixels[i + 3] = 255
            }
        }
        let image = try XCTUnwrap(makeImage(width: width, height: height, rgba: pixels))

        let png = try PNGCoder.quantizedPNG(from: image, quality: 0.8)
        XCTAssertEqual(png[png.startIndex + 25], 3, "expected indexed-color PNG (color type 3)")

        let decoded = try XCTUnwrap(decodeRGBA(png))
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        // Every pixel opaque in, every pixel opaque out.
        for i in stride(from: 3, to: decoded.rgba.count, by: 4) {
            XCTAssertEqual(decoded.rgba[i], 255)
        }
    }

    // MARK: - Helpers

    private func makeImage(width: Int, height: Int, rgba: [UInt8]) -> CGImage? {
        var data = rgba
        // Premultiply: CGContext with premultipliedLast expects it.
        for i in stride(from: 0, to: data.count, by: 4) {
            let alpha = Int(data[i + 3])
            if alpha < 255 {
                data[i] = UInt8(Int(data[i]) * alpha / 255)
                data[i + 1] = UInt8(Int(data[i + 1]) * alpha / 255)
                data[i + 2] = UInt8(Int(data[i + 2]) * alpha / 255)
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

    private func decodeRGBA(_ png: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let buffer = RGBABuffer(image: image)
        else { return nil }
        let rgba = Array(UnsafeBufferPointer(start: buffer.pixels, count: buffer.width * buffer.height * 4))
        return (buffer.width, buffer.height, rgba)
    }
}
