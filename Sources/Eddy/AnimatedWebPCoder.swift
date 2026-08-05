import CoreGraphics
import Foundation
import libwebp

/// Animated WebP codec backed by libwebp's demux and mux APIs.
///
/// Decoding returns fully composited RGBA canvases. Application transcodes use
/// WebPAnimEncoder's delta optimization when it preserves every timing/loop
/// invariant, then fall back to full-canvas no-blend frames when necessary.
/// The outer compressor still keeps the original unless the new file is
/// smaller.
enum AnimatedWebPCoder {
    struct Animation {
        let frames: [CGImage]
        let durationsMilliseconds: [Int]
        let loopCount: Int
        let backgroundColor: UInt32

        var width: Int { frames.first?.width ?? 0 }
        var height: Int { frames.first?.height ?? 0 }
    }

    private struct Metadata: Equatable {
        let durationsMilliseconds: [Int]
        let loopCount: Int
        let backgroundColor: UInt32
    }

    static func isAnimated(_ fileURL: URL) -> Bool {
        frameCount(fileURL) > 1
    }

    static func frameCount(_ fileURL: URL) -> Int {
        guard let data = try? Data(contentsOf: fileURL) else { return 1 }
        return frameCount(data)
    }

    static func canvasSize(_ fileURL: URL) -> (width: Int, height: Int)? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return withWebPData(data) { webPData in
            guard let demuxer = WebPDemux(&webPData) else { return nil }
            defer { WebPDemuxDelete(demuxer) }
            let width = Int(WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH))
            let height = Int(WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT))
            return width > 0 && height > 0 ? (width, height) : nil
        }
    }

    static func frameCount(_ data: Data) -> Int {
        withWebPData(data) { webPData in
            guard let demuxer = WebPDemux(&webPData) else { return 1 }
            defer { WebPDemuxDelete(demuxer) }
            return max(1, Int(WebPDemuxGetI(demuxer, WEBP_FF_FRAME_COUNT)))
        }
    }

    /// Fully composited first canvas for editor/thumbnail use without
    /// materializing the remaining animation frames.
    static func firstFrame(_ fileURL: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return withWebPData(data) { webPData in
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else { return nil }
            options.color_mode = MODE_RGBA
            options.use_threads = 1
            guard let decoder = WebPAnimDecoderNew(&webPData, &options) else { return nil }
            defer { WebPAnimDecoderDelete(decoder) }
            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else { return nil }
            var pixels: UnsafeMutablePointer<UInt8>?
            var timestamp: Int32 = 0
            guard WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) != 0,
                  let pixels
            else { return nil }
            return makeImage(
                straightRGBA: pixels,
                width: Int(info.canvas_width),
                height: Int(info.canvas_height)
            )
        }
    }

    static func decode(_ fileURL: URL) throws -> Animation {
        try decode(Data(contentsOf: fileURL))
    }

    static func decode(_ data: Data) throws -> Animation {
        try withWebPData(data) { webPData in
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else {
                throw CompressionError.encodeFailed
            }
            options.color_mode = MODE_RGBA
            options.use_threads = 1

            guard let decoder = WebPAnimDecoderNew(&webPData, &options) else {
                throw CompressionError.unknownFormat
            }
            defer { WebPAnimDecoderDelete(decoder) }

            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else {
                throw CompressionError.unknownFormat
            }
            let width = Int(info.canvas_width)
            let height = Int(info.canvas_height)
            guard width > 0, height > 0 else { throw CompressionError.unknownFormat }

            var frames: [CGImage] = []
            var durations: [Int] = []
            frames.reserveCapacity(Int(info.frame_count))
            durations.reserveCapacity(Int(info.frame_count))
            var previousTimestamp: Int32 = 0

            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var pixels: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) != 0,
                      let pixels,
                      let image = makeImage(
                          straightRGBA: pixels,
                          width: width,
                          height: height
                      )
                else { throw CompressionError.encodeFailed }

                frames.append(image)
                durations.append(max(0, Int(timestamp - previousTimestamp)))
                previousTimestamp = timestamp
            }

            guard frames.count == Int(info.frame_count),
                  frames.count == durations.count,
                  !frames.isEmpty
            else { throw CompressionError.encodeFailed }

            return Animation(
                frames: frames,
                durationsMilliseconds: durations,
                loopCount: Int(info.loop_count),
                backgroundColor: info.bgcolor
            )
        }
    }

    static func recompress(
        fileURL: URL,
        quality: Double,
        maxWidth: Int
    ) throws -> Data {
        try transcode(Data(contentsOf: fileURL), quality: quality) { frame in
            Compressor.resizedIfNeeded(frame, maxWidth: maxWidth)
        }
    }

    static func edit(
        fileURL: URL,
        spec: CropSpec,
        quality: Double
    ) throws -> Data {
        try transcode(Data(contentsOf: fileURL), quality: quality) { frame in
            let rotated = try Cropper.rotate(frame, rotation: spec.rotation)
            return try Cropper.render(rotated, spec: spec)
        }
    }

    static func encode(
        frames: [CGImage],
        durationsMilliseconds: [Int],
        loopCount: Int,
        backgroundColor: UInt32 = 0,
        quality: Double
    ) throws -> Data {
        guard let first = frames.first,
              frames.count == durationsMilliseconds.count,
              frames.allSatisfy({ $0.width == first.width && $0.height == first.height })
        else { throw CompressionError.encodeFailed }

        guard let mux = WebPMuxNew() else { throw CompressionError.encodeFailed }
        defer { WebPMuxDelete(mux) }

        guard WebPMuxSetCanvasSize(mux, Int32(first.width), Int32(first.height)) == WEBP_MUX_OK
        else { throw CompressionError.encodeFailed }

        var animationParameters = WebPMuxAnimParams(
            bgcolor: backgroundColor,
            loop_count: Int32(max(0, loopCount))
        )
        guard WebPMuxSetAnimationParams(mux, &animationParameters) == WEBP_MUX_OK
        else { throw CompressionError.encodeFailed }

        for (frame, duration) in zip(frames, durationsMilliseconds) {
            let encodedFrame = try WebPEncoder.encode(frame, quality: quality)
            let pushed = withWebPData(encodedFrame) { frameData -> Bool in
                var frameInfo = WebPMuxFrameInfo()
                frameInfo.bitstream = frameData
                frameInfo.x_offset = 0
                frameInfo.y_offset = 0
                // WebP stores duration in 24 bits.
                frameInfo.duration = Int32(min(max(0, duration), 0x00FF_FFFF))
                frameInfo.id = WEBP_CHUNK_ANMF
                frameInfo.dispose_method = WEBP_MUX_DISPOSE_NONE
                frameInfo.blend_method = WEBP_MUX_NO_BLEND
                return WebPMuxPushFrame(mux, &frameInfo, 1) == WEBP_MUX_OK
            }
            guard pushed else { throw CompressionError.encodeFailed }
        }

        var assembled = WebPData()
        WebPDataInit(&assembled)
        defer { WebPDataClear(&assembled) }
        guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK,
              let bytes = assembled.bytes,
              assembled.size > 0
        else { throw CompressionError.encodeFailed }
        return Data(bytes: bytes, count: assembled.size)
    }

    /// Prefer libwebp's animation optimizer, which finds inter-frame deltas.
    /// It is allowed to merge identical frames, though, so accept its output
    /// only when the complete GIF-style metadata invariant still matches;
    /// otherwise fall back to the exact full-frame muxer.
    private static func transcode(
        _ data: Data,
        quality: Double,
        transform: (CGImage) throws -> CGImage
    ) throws -> Data {
        let sourceMetadata = try metadata(data)
        if let optimized = try? transcodeOptimized(
            data,
            quality: quality,
            transform: transform
        ), let optimizedMetadata = try? metadata(optimized),
           optimizedMetadata == sourceMetadata {
            return optimized
        }
        return try transcodeExact(data, quality: quality, transform: transform)
    }

    /// One-frame-at-a-time exact fallback. Unlike `decode`, this never retains
    /// the full uncompressed animation in memory; large animations cost about
    /// one source canvas, one transformed canvas and the muxed output instead
    /// of `frameCount × canvasBytes`.
    private static func transcodeExact(
        _ data: Data,
        quality: Double,
        transform: (CGImage) throws -> CGImage
    ) throws -> Data {
        try withWebPData(data) { webPData in
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else {
                throw CompressionError.encodeFailed
            }
            options.color_mode = MODE_RGBA
            options.use_threads = 1
            guard let decoder = WebPAnimDecoderNew(&webPData, &options) else {
                throw CompressionError.unknownFormat
            }
            defer { WebPAnimDecoderDelete(decoder) }

            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else {
                throw CompressionError.unknownFormat
            }
            let sourceWidth = Int(info.canvas_width)
            let sourceHeight = Int(info.canvas_height)
            guard sourceWidth > 0, sourceHeight > 0 else {
                throw CompressionError.unknownFormat
            }

            var mux: OpaquePointer?
            defer { if let mux { WebPMuxDelete(mux) } }
            var previousTimestamp: Int32 = 0
            var encodedFrameCount = 0

            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var pixels: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) != 0,
                      let pixels,
                      let sourceFrame = makeImage(
                          straightRGBA: pixels,
                          width: sourceWidth,
                          height: sourceHeight
                      )
                else { throw CompressionError.encodeFailed }

                let frame = try transform(sourceFrame)
                if mux == nil {
                    mux = WebPMuxNew()
                    guard let mux,
                          WebPMuxSetCanvasSize(
                              mux,
                              Int32(frame.width),
                              Int32(frame.height)
                          ) == WEBP_MUX_OK
                    else { throw CompressionError.encodeFailed }
                    var animationParameters = WebPMuxAnimParams(
                        bgcolor: info.bgcolor,
                        loop_count: Int32(info.loop_count)
                    )
                    guard WebPMuxSetAnimationParams(mux, &animationParameters) == WEBP_MUX_OK
                    else { throw CompressionError.encodeFailed }
                }

                guard let mux else { throw CompressionError.encodeFailed }
                let duration = max(0, Int(timestamp - previousTimestamp))
                previousTimestamp = timestamp
                let encodedFrame = try WebPEncoder.encode(frame, quality: quality)
                let pushed = withWebPData(encodedFrame) { frameData -> Bool in
                    var frameInfo = WebPMuxFrameInfo()
                    frameInfo.bitstream = frameData
                    frameInfo.x_offset = 0
                    frameInfo.y_offset = 0
                    frameInfo.duration = Int32(min(duration, 0x00FF_FFFF))
                    frameInfo.id = WEBP_CHUNK_ANMF
                    frameInfo.dispose_method = WEBP_MUX_DISPOSE_NONE
                    frameInfo.blend_method = WEBP_MUX_NO_BLEND
                    return WebPMuxPushFrame(mux, &frameInfo, 1) == WEBP_MUX_OK
                }
                guard pushed else { throw CompressionError.encodeFailed }
                encodedFrameCount += 1
            }

            guard let mux, encodedFrameCount == Int(info.frame_count) else {
                throw CompressionError.encodeFailed
            }
            var assembled = WebPData()
            WebPDataInit(&assembled)
            defer { WebPDataClear(&assembled) }
            guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK,
                  let bytes = assembled.bytes,
                  assembled.size > 0
            else { throw CompressionError.encodeFailed }
            return Data(bytes: bytes, count: assembled.size)
        }
    }

    private static func transcodeOptimized(
        _ data: Data,
        quality: Double,
        transform: (CGImage) throws -> CGImage
    ) throws -> Data {
        try withWebPData(data) { webPData in
            var decoderOptions = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&decoderOptions) != 0 else {
                throw CompressionError.encodeFailed
            }
            decoderOptions.color_mode = MODE_RGBA
            decoderOptions.use_threads = 1
            guard let decoder = WebPAnimDecoderNew(&webPData, &decoderOptions) else {
                throw CompressionError.unknownFormat
            }
            defer { WebPAnimDecoderDelete(decoder) }

            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else {
                throw CompressionError.unknownFormat
            }
            let sourceWidth = Int(info.canvas_width)
            let sourceHeight = Int(info.canvas_height)
            guard sourceWidth > 0, sourceHeight > 0 else {
                throw CompressionError.unknownFormat
            }

            var encoder: OpaquePointer?
            defer { if let encoder { WebPAnimEncoderDelete(encoder) } }
            var previousTimestamp: Int32 = 0

            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var pixels: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) != 0,
                      let pixels,
                      let sourceFrame = makeImage(
                          straightRGBA: pixels,
                          width: sourceWidth,
                          height: sourceHeight
                      )
                else { throw CompressionError.encodeFailed }
                let frame = try transform(sourceFrame)

                if encoder == nil {
                    var options = WebPAnimEncoderOptions()
                    guard WebPAnimEncoderOptionsInit(&options) != 0 else {
                        throw CompressionError.encodeFailed
                    }
                    options.anim_params.bgcolor = info.bgcolor
                    options.anim_params.loop_count = Int32(info.loop_count)
                    options.minimize_size = 1
                    options.allow_mixed = 1
                    encoder = WebPAnimEncoderNew(
                        Int32(frame.width),
                        Int32(frame.height),
                        &options
                    )
                    guard encoder != nil else { throw CompressionError.encodeFailed }
                }

                guard let encoder,
                      let rgba = RGBABuffer(image: frame)
                else { throw CompressionError.encodeFailed }
                var config = WebPConfig()
                guard WebPConfigInit(&config) != 0 else {
                    throw CompressionError.encodeFailed
                }
                config.quality = Float(max(1, min(100, quality * 100)))
                config.method = 6
                config.thread_level = 1
                guard WebPValidateConfig(&config) != 0 else {
                    throw CompressionError.encodeFailed
                }

                var picture = WebPPicture()
                guard WebPPictureInit(&picture) != 0 else {
                    throw CompressionError.encodeFailed
                }
                picture.width = Int32(rgba.width)
                picture.height = Int32(rgba.height)
                picture.use_argb = 1
                guard WebPPictureImportRGBA(
                    &picture,
                    rgba.pixels,
                    Int32(rgba.bytesPerRow)
                ) != 0 else {
                    WebPPictureFree(&picture)
                    throw CompressionError.encodeFailed
                }
                let added = WebPAnimEncoderAdd(
                    encoder,
                    &picture,
                    previousTimestamp,
                    &config
                ) != 0
                WebPPictureFree(&picture)
                guard added else { throw CompressionError.encodeFailed }
                previousTimestamp = timestamp
            }

            guard let encoder,
                  WebPAnimEncoderAdd(encoder, nil, previousTimestamp, nil) != 0
            else { throw CompressionError.encodeFailed }
            var assembled = WebPData()
            WebPDataInit(&assembled)
            defer { WebPDataClear(&assembled) }
            guard WebPAnimEncoderAssemble(encoder, &assembled) != 0,
                  let bytes = assembled.bytes,
                  assembled.size > 0
            else { throw CompressionError.encodeFailed }
            return Data(bytes: bytes, count: assembled.size)
        }
    }

    private static func metadata(_ data: Data) throws -> Metadata {
        try withWebPData(data) { webPData in
            guard let demuxer = WebPDemux(&webPData) else {
                throw CompressionError.unknownFormat
            }
            defer { WebPDemuxDelete(demuxer) }

            let frameCount = Int(WebPDemuxGetI(demuxer, WEBP_FF_FRAME_COUNT))
            guard frameCount > 0 else { throw CompressionError.unknownFormat }
            var iterator = WebPIterator()
            guard WebPDemuxGetFrame(demuxer, 1, &iterator) != 0 else {
                throw CompressionError.unknownFormat
            }
            defer { WebPDemuxReleaseIterator(&iterator) }
            var durations: [Int] = []
            durations.reserveCapacity(frameCount)
            repeat {
                durations.append(Int(iterator.duration))
            } while WebPDemuxNextFrame(&iterator) != 0
            guard durations.count == frameCount else { throw CompressionError.encodeFailed }

            return Metadata(
                durationsMilliseconds: durations,
                loopCount: Int(WebPDemuxGetI(demuxer, WEBP_FF_LOOP_COUNT)),
                backgroundColor: WebPDemuxGetI(demuxer, WEBP_FF_BACKGROUND_COLOR)
            )
        }
    }

    private static func withWebPData<T>(
        _ data: Data,
        _ body: (inout WebPData) throws -> T
    ) rethrows -> T {
        try data.withUnsafeBytes { rawBuffer in
            var webPData = WebPData(
                bytes: rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                size: rawBuffer.count
            )
            return try body(&webPData)
        }
    }

    private static func makeImage(
        straightRGBA pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int
    ) -> CGImage? {
        let bytesPerRow = width * 4
        let data = Data(bytes: pixels, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
