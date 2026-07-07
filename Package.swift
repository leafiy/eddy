// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "eddy",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libwebp compiled from source — in-process WebP encoding.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
        // libavif + libaom compiled from source — in-process AVIF encoding.
        .package(url: "https://github.com/SDWebImage/libavif-Xcode.git", from: "1.0.0"),
        // Shared Leafiy design system, vendored in-repo (canonical source:
        // the leafiy-ui repository; re-sync with its scripts/sync-into-apps.sh).
        .package(path: "Vendor/leafiy-ui"),
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
                .product(name: "LeafiyUI", package: "leafiy-ui"),
            ],
            path: "Sources/Eddy"
        )
    ]
)
