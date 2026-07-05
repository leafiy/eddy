// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "eddy",
    platforms: [.macOS(.v13)],
    dependencies: [
        // libwebp compiled from source — in-process WebP encoding.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
        // libavif + libaom compiled from source — in-process AVIF encoding.
        .package(url: "https://github.com/SDWebImage/libavif-Xcode.git", from: "1.0.0"),
    ],
    targets: [
        // pngquant's quantization engine, vendored (GPLv3; see COPYRIGHT).
        .target(
            name: "libimagequant",
            path: "Vendor/libimagequant",
            exclude: ["COPYRIGHT"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "eddy",
            dependencies: [
                "libimagequant",
                .product(name: "libwebp", package: "libwebp-Xcode"),
                .product(name: "libavif", package: "libavif-Xcode"),
            ],
            path: "Sources/Eddy"
        )
    ]
)
